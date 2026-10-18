--[[
Copyright (C) 2020-2022 Ren Tatsumoto and contributors

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.

Requirements:
* mpv >= 0.32.0
* AnkiConnect
* curl
* xclip (when running X11)
* wl-copy (when running Wayland)

Usage:
1. Change `config` according to your needs
* Core settings: ~/.config/mpv/script-opts/mpv-anki-clips-core.conf
* Base profile: ~/.config/mpv/script-opts/mpv-anki-clips-base.conf
* Missing config files are created automatically.

2. Open a video

3. Use key bindings to manipulate the script
* Open MPV Anki Clips menu - `a`
* Create a note from the current subtitle line - `Ctrl + n`
* Switch export field set - `alt+f`

For the complete usage guide, see the MPV Anki Clips README.
]]

local mp = require('mp')
local OSD = require('osd_styler')
local cfg_mgr = require('cfg_mgr')
local encoder = require('encoder.encoder')
local this = require('helpers')
local logger = require('utils.logger')
local clip_logger = require('utils.clip_logger')
local utils = require('mp.utils')
local Menu = require('menu')
local ankiconnect = require('ankiconnect')
local switch = require('utils.switch')
local dec_counter = require('utils.dec_counter')
local play_control = require('utils.play_control')
local secondary_sid = require('subtitles.secondary_sid')
local platform = require('platform.init')
local forvo = require('utils.forvo')
local subs_observer = require('subtitles.observer')
local codec_support = require('encoder.codec_support')
local queue_client = require('utils.queue_client')

local menu, quick_menu, quick_menu_card
local is_encoding = false
local active_field_set = 1
-- Snapshot of the last export action (excludes video/audio encoding settings)
local last_export_snapshot = nil
local export_queue = {}
local current_export_job = nil
local next_export_job_id = 1
local handle_global_queue_lease_loss
local quick_creation_opts = {
    _n_lines = nil,
    _n_cards = 1,
    set_cards = function(self, n)
        self._n_cards = math.max(0, n)
    end,
    set_lines = function(self, n)
        self._n_lines = math.max(0, n)
    end,
    get_cards = function(self)
        return self._n_cards
    end,
    get_lines = function(self)
        return self._n_lines
    end,
    increment_cards = function(self)
        self:set_cards(self._n_cards + 1)
    end,
    decrement_cards = function(self)
        self:set_cards(self._n_cards - 1)
    end,
    clear_options = function(self)
        self._n_lines = nil
        self._n_cards = 1
    end,
    reset_all = function(self)
        self:clear_options()
        subs_observer.clear()
        subs_observer.clear_all_dialogs()
    end
}

local subtitles_export_disabled = false
-- Forward declarations for helpers referenced before their definitions.
local config
local get_anki_media_dir_path
local get_test_encode_output_dir
local video_padding
local tag_format
local substitute_fmt
local construct_note_fields
local change_fields
local bytes_to_mib
local seconds_to_mmss
local probe_duration_seconds
local process_export_queue
local poll_global_queue_job

local function get_preview_char_limit()
    local n = tonumber(config and config.preview_text_char_limit) or 40
    n = math.floor(n)
    if n < 1 then n = 1 end
    return n
end

local function get_captured_primarysub_preview_char_limit()
    local cfg = config or {}
    local n = tonumber(cfg.captured_primarysub_preview_char_limit) or 85
    n = math.floor(n)
    if n < 1 then n = 1 end
    return n
end

local function get_captured_secondarysub_preview_char_limit()
    local cfg = config or {}
    local n = tonumber(cfg.captured_secondarysub_preview_char_limit) or 40
    n = math.floor(n)
    if n < 1 then n = 1 end
    return n
end

local function utf8_safe_prefix(text, max_chars)
    if not text or text == "" then
        return ""
    end
    max_chars = tonumber(max_chars) or 0
    if max_chars <= 0 then
        return ""
    end

    local i = 1
    local char_count = 0
    local last_valid_end = 0
    local len = #text

    while i <= len and char_count < max_chars do
        local b = text:byte(i)
        local step = 1

        if b < 0x80 then
            step = 1
        elseif b >= 0xC2 and b <= 0xDF then
            if i + 1 > len then break end
            local b2 = text:byte(i + 1)
            if not (b2 >= 0x80 and b2 <= 0xBF) then break end
            step = 2
        elseif b >= 0xE0 and b <= 0xEF then
            if i + 2 > len then break end
            local b2, b3 = text:byte(i + 1), text:byte(i + 2)
            if not (b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF) then break end
            step = 3
        elseif b >= 0xF0 and b <= 0xF4 then
            if i + 3 > len then break end
            local b2, b3, b4 = text:byte(i + 1), text:byte(i + 2), text:byte(i + 3)
            if not (b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF) then break end
            step = 4
        else
            break
        end

        last_valid_end = i + step - 1
        i = i + step
        char_count = char_count + 1
    end

    if last_valid_end <= 0 then
        return ""
    end
    return text:sub(1, last_valid_end)
end

local function cap_preview_text_utf8(value, max_len)
    local s = tostring(value or "")
    max_len = tonumber(max_len) or get_preview_char_limit()
    if max_len <= 3 then
        return utf8_safe_prefix(s, max_len)
    end
    local prefix = utf8_safe_prefix(s, max_len)
    if prefix ~= s then
        return utf8_safe_prefix(s, max_len - 3) .. "..."
    end
    return prefix
end

local function should_cap_video_custom_args_preview()
    local v = config and config.cap_video_custom_args_preview
    if v == true then
        return true
    end
    if type(v) == "string" then
        local s = v:lower()
        return s == "yes" or s == "true" or s == "1" or s == "on"
    end
    return false
end

local function is_enabled_like(value)
    if value == true then
        return true
    end
    if type(value) == 'string' then
        local normalized = value:lower()
        return normalized == 'yes' or normalized == 'true' or normalized == 'enabled' or normalized == 'on'
    end
    return false
end

local function should_highlight_exported_notes(export_config)
    local cfg = export_config or config
    if not cfg or cfg.highlight_exported_notes_in_browser == nil then
        return true
    end
    return is_enabled_like(cfg.highlight_exported_notes_in_browser)
end

local function truncate_note_label(label)
    if type(label) ~= 'string' then
        return nil
    end
    return cap_preview_text_utf8(label, get_preview_char_limit())
end

local function compact_preview_text(value, max_len)
    local s = tostring(value or "")
    s = s:gsub("\r\n", " "):gsub("\n", " "):gsub("\r", " ")
    s = s:gsub("%s+", " ")
    s = s:match("^%s*(.-)%s*$") or ""
    if s == "" then
        return ""
    end

    max_len = tonumber(max_len) or get_preview_char_limit()
    return cap_preview_text_utf8(s, max_len)
end

local function sanitize_osd_inline_text(value)
    local s = tostring(value or "")
    s = s:gsub("\r\n", " "):gsub("\n", " "):gsub("\r", " ")
    s = s:gsub('[%[%]{}]', '')
    return s
end

local function clone_active_fields(active_fields)
    return {
        sentence_field = active_fields.sentence_field,
        secondary_field = active_fields.secondary_field,
        video_field = active_fields.video_field,
        miscinfo_field = active_fields.miscinfo_field,
    }
end

local function clone_captured_info(captured)
    if not captured then
        return nil
    end
    return {
        filename = captured.filename,
        episode = captured.episode,
        raw_filename = captured.raw_filename,
        media_path = captured.media_path,
        media_dir = captured.media_dir,
        media_title = captured.media_title,
        time_pos = captured.time_pos,
    }
end

local function clone_export_sub(sub)
    return {
        start = sub['start'],
        finish = sub['end'],
        text_raw = sub['text'],
        secondary_raw = sub['secondary'],
    }
end

local function clone_note_ids(note_ids)
    local copy = {}
    for i, note_id in ipairs(note_ids or {}) do
        copy[i] = note_id
    end
    return copy
end

local function runtime_sub_from_snapshot(snapshot_sub)
    return {
        start = snapshot_sub and snapshot_sub.start or mp.get_property_number('time-pos'),
        ["end"] = snapshot_sub and snapshot_sub.finish or mp.get_property_number('time-pos'),
        text = snapshot_sub and snapshot_sub.text_raw or '',
        secondary = snapshot_sub and snapshot_sub.secondary_raw or '',
    }
end

local function snapshot_sub_duration_seconds(snapshot_sub)
    if not snapshot_sub then
        return nil
    end

    local start_time = tonumber(snapshot_sub.start)
    local end_time = tonumber(snapshot_sub.finish)
    if not start_time or not end_time or end_time < start_time then
        return nil
    end
    return end_time - start_time
end

local function remember_last_export(snapshot)
    last_export_snapshot = this.deepcopy(snapshot)

    local details = { "kind=" .. tostring(snapshot.kind) }
    if snapshot.note_ids then
        table.insert(details, "notes=" .. tostring(#snapshot.note_ids))
    end
    mp.msg.info("Stored snapshot for repeat export: " .. table.concat(details, ", "))
end

local function menu_update_if_active()
    if menu and menu.active then
        menu:update()
    end
end

local function note_sort_field_details_from_info(note_info)
    if not note_info or not note_info.modelName or not note_info.fields then
        return nil, nil
    end

    local sort_field = ankiconnect.get_sort_field(note_info.modelName)
    if sort_field and note_info.fields[sort_field] and note_info.fields[sort_field].value then
        return sort_field, note_info.fields[sort_field].value
    end

    return sort_field, nil
end

local function note_display_name_from_info(note_info)
    local _, sort_field_value = note_sort_field_details_from_info(note_info)
    if sort_field_value then
        return truncate_note_label(sort_field_value)
    end
    return nil
end

local function get_note_display_name(note_id)
    local ret = ankiconnect.execute {
        action = "notesInfo",
        version = 6,
        params = {
            notes = { note_id }
        }
    }

    local note_info, error = ankiconnect.parse_result(ret)
    if error or not note_info or not note_info[1] then
        return nil
    end

    return note_display_name_from_info(note_info[1])
end

local function get_note_sort_field_details(note_id)
    if not note_id then
        return nil, nil
    end

    local ret = ankiconnect.execute {
        action = "notesInfo",
        version = 6,
        params = {
            notes = { note_id }
        }
    }

    local note_info, error = ankiconnect.parse_result(ret)
    if error or not note_info or not note_info[1] then
        return nil, nil
    end
    return note_sort_field_details_from_info(note_info[1])
end

local function note_fields_from_info(note_info)
    if not note_info or not note_info.fields then
        return nil
    end

    local fields = {}
    for key, value in pairs(note_info.fields) do
        fields[key] = value and value.value or nil
    end
    return fields
end

local function get_note_preview_state(note_id)
    if not note_id then
        return {
            label = "(doesn't exist)",
            tone = 'inactive',
            fields = nil,
            error = "(doesn't exist)",
        }
    end

    local ret = ankiconnect.execute {
        action = "notesInfo",
        version = 6,
        params = {
            notes = { note_id }
        }
    }

    local note_info, error = ankiconnect.parse_result(ret)
    if error then
        return {
            label = "(failed to load note)",
            tone = 'inactive',
            fields = nil,
            error = "(failed to load note)",
        }
    end

    if not note_info or not note_info[1] then
        return {
            label = "(doesn't exist)",
            tone = 'inactive',
            fields = nil,
            error = "(doesn't exist)",
        }
    end

    return {
        label = note_display_name_from_info(note_info[1]) or ("#" .. tostring(note_id)),
        tone = 'browser_note',
        fields = note_fields_from_info(note_info[1]),
        error = nil,
    }
end

local function refresh_anki_target_info_once(delay_seconds)
    if not (menu and menu.active and menu.show_anki_target_info) then
        return
    end

    local delay = tonumber(delay_seconds) or 0
    if delay <= 0 then
        menu:refresh_anki_target_info()
        menu:update()
        return
    end

    mp.add_timeout(delay, function()
        if menu and menu.active and menu.show_anki_target_info then
            menu:refresh_anki_target_info()
            menu:update()
        end
    end)
end

local function refresh_anki_preview()
    if not menu then
        return
    end

    if not menu.show_anki_target_info then
        menu.show_anki_target_info = true
    end

    if not menu.active then
        menu:open()
    end

    menu:refresh_anki_target_info()
    if menu.active then
        menu:update()
    end
    this.notify("Anki preview refreshed.", "info", 2)
end

local function get_note_target_summary(note_ids)
    if this.is_empty(note_ids) then
        return nil
    end

    local first_label = get_note_display_name(note_ids[1])
    local first = first_label or ("#" .. tostring(note_ids[1]))
    if #note_ids == 1 then
        return first
    end
    return string.format("%s (+%d)", first, #note_ids - 1)
end

local function capture_export_context(export_config)
    local cfg = export_config or config
    local raw_filename = mp.get_property("filename") or ''
    local media_path = mp.get_property("path") or ''
    local media_dir = ''
    if not this.is_empty(media_path) then
        local dir, _ = utils.split_path(media_path)
        media_dir = dir or ''
    end
    local filename, episode = tag_format(raw_filename, cfg)
    return {
        filename = filename,
        episode = episode,
        raw_filename = raw_filename,
        media_path = media_path,
        media_dir = media_dir,
        media_title = mp.get_property("media-title") or '',
        time_pos = mp.get_property_number('time-pos') or 0,
    }
end

local function capture_media_snapshot()
    local source_path = mp.get_property("path") or ''
    local working_directory = mp.get_property("working-directory") or ''
    if source_path ~= '' and not source_path:match('^[/\\]') and not source_path:match('^[a-zA-Z]:') and working_directory ~= '' then
        source_path = utils.join_path(working_directory, source_path)
    end

    local track_list = {}
    local track_count = mp.get_property_number("track-list/count") or 0
    for i = 0, track_count - 1 do
        table.insert(track_list, {
            type = mp.get_property("track-list/" .. i .. "/type"),
            lang = mp.get_property("track-list/" .. i .. "/lang") or "und",
            ff_index = mp.get_property_number("track-list/" .. i .. "/ff-index"),
            external = mp.get_property_bool("track-list/" .. i .. "/external"),
            external_filename = mp.get_property("track-list/" .. i .. "/external-filename"),
            id = mp.get_property_number("track-list/" .. i .. "/id"),
            codec = mp.get_property("track-list/" .. i .. "/codec"),
        })
    end

    return {
        source_path = source_path,
        working_directory = working_directory,
        current_sub_id = mp.get_property("current-tracks/sub/id"),
        current_audio_id = mp.get_property("current-tracks/audio/id"),
        has_video_track = this.has_video_track and this.has_video_track() or nil,
        has_audio_track = this.has_audio_track and this.has_audio_track() or nil,
        track_list = track_list,
    }
end

local function make_export_snapshot_config(active_fields)
    local snapshot_config = this.deepcopy(config)
    if active_fields and active_fields.video_field then
        snapshot_config.video_field = active_fields.video_field
    end
    return snapshot_config
end

local function note_field_has_content(value)
    if this.is_empty(value) then
        return false
    end
    if type(value) == 'string' then
        return this.remove_leading_trailing_spaces(value) ~= ''
    end
    return true
end

local function collect_target_field_names(active_fields, subtitles_disabled, export_config)
    local cfg = export_config or config
    local fields = {}
    local seen = {}

    local function add_field(field_name)
        if not this.is_empty(field_name) and not seen[field_name] then
            seen[field_name] = true
            table.insert(fields, field_name)
        end
    end

    if not subtitles_disabled then
        add_field(active_fields.sentence_field)
        add_field(active_fields.secondary_field)
    end
    add_field(active_fields.video_field)
    if cfg.miscinfo_enable == true then
        add_field(active_fields.miscinfo_field)
    end

    return fields
end

local function get_field_population_state(note_ids, active_fields, subtitles_disabled, export_config)
    local fields_to_check = collect_target_field_names(active_fields, subtitles_disabled, export_config)
    local populated_fields = {}

    if not this.is_empty(note_ids) then
        for _, note_id in ipairs(note_ids) do
            local stored_fields = ankiconnect.get_note_fields(note_id)
            if not stored_fields then
                mp.msg.warn("Queue metadata: couldn't inspect note #" .. tostring(note_id) .. "; assuming all target fields populated")
                for _, field_name in ipairs(fields_to_check) do
                    populated_fields[field_name] = true
                end
            else
                for _, field_name in ipairs(fields_to_check) do
                    if note_field_has_content(stored_fields[field_name]) then
                        populated_fields[field_name] = true
                    end
                end
            end
        end
    end

    local populated_count = 0
    for _, field_name in ipairs(fields_to_check) do
        if populated_fields[field_name] then
            populated_count = populated_count + 1
        end
    end

    return string.format('%d/%d fields populated', populated_count, #fields_to_check)
end

local function get_text_source_kind(subtitles_disabled, had_subtitle_text, used_clipboard)
    if subtitles_disabled then
        return 'disabled'
    end
    if used_clipboard then
        return 'clipboard'
    end
    if had_subtitle_text then
        return 'subtitles'
    end
    return 'empty'
end

local function get_text_source_label(text_source_kind)
    return text_source_kind == 'clipboard' and 'w/ clipboard'
        or text_source_kind == 'subtitles' and 'w/ subtitles'
        or text_source_kind == 'disabled' and 'w/o sub'
        or text_source_kind == 'empty' and 'w/o sub (empty)'
        or nil
end

local function get_queue_field_state_label(field_population_state)
    local populated_count = tostring(field_population_state):match('^(%d+)/%d+ fields populated$')
    if populated_count and tonumber(populated_count) == 0 then
        return 'new'
    end
    if populated_count and tonumber(populated_count) > 0 then
        return 'overwrite'
    end
    return field_population_state
end

local function get_queue_field_state_tone(field_population_state)
    local populated_count, total_count = tostring(field_population_state):match('^(%d+)/(%d+) fields populated$')
    if populated_count and total_count and tonumber(populated_count) == 0 then
        return 'active'
    end
    if populated_count and total_count and tonumber(populated_count) > 0 then
        return 'anki_field_preview'
    end
    return 'queue_field_state'
end

local function get_queue_mode_tone(update_mode)
    if update_mode == 'replace' then
        return 'queue_mode_replace'
    end
    if update_mode == 'add' then
        return 'active'
    end
    return 'queue_mode_indicator'
end

local function get_queue_source_tone(text_source_kind)
    if text_source_kind == 'subtitles' then
        return 'active'
    end
    if text_source_kind == 'clipboard' then
        return 'profile'
    end
    if text_source_kind == 'disabled' or text_source_kind == 'empty' then
        return 'inactive'
    end
    return 'queue_source_indicator'
end

local function describe_export_job(job)
    if not job then
        return 'idle'
    end

    local kind = job.kind
    local label = kind == 'anki_add' and 'Add note'
        or kind == 'update_notes' and 'Update note'
        or kind == 'test_encode' and 'Test encode'
        or 'Export'

    local description = label
    if job.target_summary and job.target_summary ~= '' then
        description = string.format("%s: %s", label, job.target_summary)
    end
    return description
end

local function report_clip_output(job, runtime_sub, filename)
    local output_path = utils.join_path(job.output_dir, filename)
    local finfo = utils.file_info(output_path)
    local report_prefix = job.report_prefix or describe_export_job(job)

    if finfo and finfo.size then
        local mib = bytes_to_mib(finfo.size)
        local intended = (runtime_sub['end'] or 0) - (runtime_sub['start'] or 0)
        local dur = probe_duration_seconds(output_path, intended)
        mp.msg.info(string.format("%s clip size: %.2f MiB (%d bytes) at %s", report_prefix, mib, finfo.size, output_path))
        mp.msg.info(string.format("%s clip length: %s (%.2fs)", report_prefix, seconds_to_mmss(dur), dur))
        this.notify("Clip saved: " .. tostring(filename), "info", 3)
        this.notify(string.format("Filesize: %.2f MiB", mib), "info", 3)
        this.notify(string.format("Duration: %s", seconds_to_mmss(dur)), "info", 3)
        return
    end

    mp.msg.info(string.format("%s clip saved at %s (size unknown)", report_prefix, output_path))
    this.notify("Clip saved: " .. tostring(filename), "info", 3)
    mp.add_timeout(0.2, function()
        local retry_info = utils.file_info(output_path)
        if retry_info and retry_info.size then
            local retry_mib = bytes_to_mib(retry_info.size)
            local intended = (runtime_sub['end'] or 0) - (runtime_sub['start'] or 0)
            local dur = probe_duration_seconds(output_path, intended)
            mp.msg.info(string.format("%s clip size (retry): %.2f MiB (%d bytes) at %s", report_prefix, retry_mib, retry_info.size, output_path))
            this.notify(string.format("Filesize: %.2f MiB", retry_mib), "info", 3)
            this.notify(string.format("Duration: %s", seconds_to_mmss(dur)), "info", 3)
        end
    end)
end

local function log_completed_job_record(job, runtime_sub, filename, note_fields, extra)
    local output_path = utils.join_path(job.output_dir, filename)
    local log_extra = this.deepcopy(extra or {})
    local note_ids = log_extra.note_ids or job.note_ids or {}
    if note_ids[1] and not log_extra.note_sort_field_name then
        log_extra.note_sort_field_name, log_extra.note_sort_field_value = get_note_sort_field_details(note_ids[1])
    end
    log_extra.encode = encoder.get_last_encode_details and encoder.get_last_encode_details() or nil
    log_extra.result = log_extra.result or {}
    log_extra.result.final_output_duration_seconds = encoder.get_last_encode_duration and encoder.get_last_encode_duration() or nil
    local ok, err = clip_logger.log_completed_job(job, runtime_sub, output_path, note_fields, log_extra)
    if not ok then
        mp.msg.warn("Clip logging failed: " .. tostring(err))
        this.notify("Clip log write failed.", "warn", 3)
    end
end

local function capture_existing_output_snapshot(output_dir, filename)
    if this.is_empty(output_dir) or this.is_empty(filename) then
        return {
            replaced_existing_output = false,
            previous_output_size_bytes = nil,
        }
    end

    local output_path = utils.join_path(output_dir, filename)
    local file_info = utils.file_info(output_path)
    local size_bytes = file_info and file_info.size or nil

    return {
        replaced_existing_output = size_bytes ~= nil,
        previous_output_size_bytes = size_bytes,
    }
end

local function with_forvo_export_config(export_config, fn)
    if not export_config then
        return fn()
    end

    forvo.init(export_config, platform)
    local ok, result = pcall(fn)
    forvo.init(config, platform)
    if not ok then
        error(result)
    end
    return result
end

local function stop_global_queue_heartbeat(job)
    if job and job.global_queue_heartbeat_timer then
        job.global_queue_heartbeat_timer:kill()
        job.global_queue_heartbeat_timer = nil
    end
    if job then
        job.global_queue_heartbeat_in_flight = false
    end
end

local function start_global_queue_heartbeat(job)
    stop_global_queue_heartbeat(job)
    local interval = tonumber(config.queue_server_heartbeat_interval) or 10
    job.global_queue_heartbeat_timer = mp.add_periodic_timer(interval, function()
        if current_export_job ~= job or not job.global_queue_granted or job.global_queue_released then
            stop_global_queue_heartbeat(job)
            return
        end
        if job.global_queue_heartbeat_in_flight then return end
        job.global_queue_heartbeat_in_flight = true
        queue_client.heartbeat(job.global_queue_id, job.global_queue_lease_id, function(response, err, code)
            job.global_queue_heartbeat_in_flight = false
            if current_export_job ~= job or job.global_queue_released then return end
            if response and response.state == 'granted' then
                job.global_queue_lease_deadline = response.lease_deadline
                return
            end
            local definitive_loss = code == 'lease_mismatch' or code == 'lease_inactive'
            local deadline = tonumber(job.global_queue_lease_deadline)
            if definitive_loss or not deadline or os.time() >= deadline then
                handle_global_queue_lease_loss(job, err or ('unexpected heartbeat state: ' .. tostring(response and response.state)))
            else
                mp.msg.warn('Global queue heartbeat failed; retrying before lease deadline: ' .. tostring(err))
            end
        end)
    end)
end

local function current_encode_status_label()
    local job = current_export_job
    if not job then
        return encoder.format_encode_progress_label()
    end
    if job.state == 'global_queue_waiting' then
        return encoder.format_encode_progress_label({ stage = 'global_queue_waiting' })
    end
    if job.state == 'finalizing' then
        return encoder.format_encode_progress_label({ stage = 'finalizing' })
    end
    return encoder.format_encode_progress_label({
        stage = job.encode_stage,
        percent = job.encode_percent,
        speed = job.encode_speed,
    })
end

local function finalize_current_export_job()
    stop_global_queue_heartbeat(current_export_job)
    if current_export_job and current_export_job.global_queue_granted and not current_export_job.global_queue_released then
        queue_client.complete(current_export_job.global_queue_id, current_export_job.global_queue_lease_id)
        current_export_job.global_queue_released = true
    end
    if current_export_job then
        current_export_job.encode_stage = nil
        current_export_job.encode_percent = nil
        current_export_job.encode_speed = nil
    end
    current_export_job = nil
    is_encoding = false
    if #export_queue == 0 then
        encoder.init(config)
        encoder.set_media_snapshot(nil)
        forvo.init(config, platform)
    end
    menu_update_if_active()
    process_export_queue()
end

local function finalize_after_export_callback(callback)
    local ok, err = pcall(callback)
    if not ok then
        mp.msg.error("Queued export post-processing failed: " .. tostring(err))
        this.notify("Export completed, but post-processing failed.", "warn", 3)
    end
    finalize_current_export_job()
end

local function start_current_export_job(job)
    local runtime_sub = runtime_sub_from_snapshot(job.sub)

    current_export_job.state = 'encoding'
    is_encoding = true

    encoder.init(job.config)
    encoder.set_media_snapshot(job.media_snapshot)
    encoder.set_output_dir(job.output_dir)
    if job.kind ~= 'test_encode' then
        forvo.set_output_dir(job.output_dir)
    end
    menu_update_if_active()

    local padding = video_padding(job.is_subtitle_based, job.config)
    local video = encoder.video.create_job(runtime_sub, padding)
    if not video then
        mp.msg.error("Queued export aborted: failed to create video job")
        this.notify("Failed to init video job.", "warn", 3)
        finalize_current_export_job()
        return
    end
    job.encoder_handle = video
    job.encode_stage = nil
    job.encode_percent = nil
    job.encode_speed = nil

    local existing_output_snapshot = capture_existing_output_snapshot(job.output_dir, video.filename)

    video.on_progress(function(info)
        if current_export_job ~= job or job.state == 'cancelled' then
            return
        end
        info = info or {}
        local previous = encoder.format_encode_progress_label({
            stage = job.encode_stage,
            percent = job.encode_percent,
            speed = job.encode_speed,
        })
        job.encode_stage = info.stage or job.encode_stage
        job.encode_percent = info.percent
        job.encode_speed = info.speed
        local next_label = encoder.format_encode_progress_label({
            stage = job.encode_stage,
            percent = job.encode_percent,
            speed = job.encode_speed,
        })
        if next_label ~= previous then
            menu_update_if_active()
        end
    end)

    video.on_finish(function(success)
        job.encoder_handle = nil
        if job.state == 'cancelled' then
            finalize_current_export_job()
            return
        end
        if not success then
            if job.kind == 'test_encode' then
                this.notify("Failed to create test video.", "warn", 2)
            elseif job.kind == 'anki_add' then
                this.notify("Failed to create video. Note not added.", "warn", 2)
            else
                this.notify("Failed to create video. Note not updated.", "warn", 2)
            end
            finalize_current_export_job()
            return
        end

        current_export_job.state = 'finalizing'
        menu_update_if_active()
        report_clip_output(job, runtime_sub, video.filename)

        if job.kind == 'test_encode' then
            log_completed_job_record(job, runtime_sub, video.filename, nil, {
                result = existing_output_snapshot,
            })
            if job.repeated then
                this.notify("Repeated last export.", "info", 2)
            end
            finalize_current_export_job()
            return
        end

        local ok_fields, note_fields = pcall(
            construct_note_fields,
            runtime_sub['text'],
            runtime_sub['secondary'],
            video.filename,
            runtime_sub,
            job.active_fields,
            job.subtitles_export_disabled,
            job.captured,
            job.config
        )
        if not ok_fields then
            mp.msg.error("Queued export field construction failed: " .. tostring(note_fields))
            this.notify("Field construction failed.", "warn", 3)
            finalize_current_export_job()
            return
        end

        if job.kind == 'anki_add' then
            if not this.is_empty(job.active_fields.sentence_field) and this.is_empty(note_fields[job.active_fields.sentence_field]) then
                note_fields[job.active_fields.sentence_field] = "[empty]"
            end
            ankiconnect.add_note(
                note_fields,
                substitute_fmt(job.config.note_tag, runtime_sub, job.captured, job.config),
                job.gui,
                job.config,
                function(note_id, error, gui_opened)
                    finalize_after_export_callback(function()
                        if not error and not gui_opened then
                            refresh_anki_target_info_once(0.35)
                            this.notify(job.repeated and "Repeated last export." or "Exported to Anki.", "info", 2)
                            log_completed_job_record(job, runtime_sub, video.filename, note_fields, {
                                added_note_id = note_id,
                                note_ids = note_id and { note_id } or {},
                                result = existing_output_snapshot,
                            })
                        end
                    end)
                end
            )
            return
        end

        local ok_change, err_change = pcall(
            change_fields,
            job.note_ids,
            note_fields,
            job.overwrite,
            job.active_fields,
            job.config,
            runtime_sub,
            job.captured,
            function(success)
                finalize_after_export_callback(function()
                    if success then
                        log_completed_job_record(job, runtime_sub, video.filename, note_fields, {
                            result = existing_output_snapshot,
                        })
                    else
                        this.notify(job.repeated and "Repeat export failed updating notes." or "Failed updating notes.", "warn", 3)
                    end
                end)
            end
        )
        if not ok_change then
            mp.msg.error("Queued export change_fields failed: " .. tostring(err_change))
            this.notify(job.repeated and "Repeat export failed updating notes." or "Failed updating notes.", "warn", 3)
            finalize_current_export_job()
            return
        end
    end).run_async()
end

local function fail_current_queue_job(job, message)
    mp.msg.error('Global queue job cancelled: ' .. tostring(message))
    this.notify('Global queue unavailable. Export cancelled.', 'warn', 3)
    job.state = 'cancelled'
    queue_client.cancel(job.global_queue_id, job.global_queue_lease_id)
    finalize_current_export_job()
end

handle_global_queue_lease_loss = function(job, message)
    if current_export_job ~= job or job.global_queue_released then return end
    mp.msg.error('Global queue lease lost: ' .. tostring(message))
    this.notify('Global queue lease lost. Encoding cancelled.', 'warn', 4)
    job.state = 'cancelled'
    job.global_queue_released = true
    stop_global_queue_heartbeat(job)
    queue_client.cancel(job.global_queue_id, job.global_queue_lease_id)
    if job.encoder_handle and job.encoder_handle.cancel and job.encoder_handle.cancel() then
        return
    end
    finalize_current_export_job()
end

poll_global_queue_job = function(job)
    mp.add_timeout(1, function()
        if current_export_job ~= job or job.state ~= 'global_queue_waiting' then
            return
        end

        queue_client.get(job.global_queue_id, function(response, err)
            if current_export_job ~= job or job.state ~= 'global_queue_waiting' then
                return
            end
            if not response then
                fail_current_queue_job(job, err)
                return
            end
            if response.state == 'granted' then
                job.global_queue_granted = true
                job.global_queue_lease_id = response.lease_id
                job.global_queue_lease_deadline = response.lease_deadline
                job.global_queue_position = 0
                start_global_queue_heartbeat(job)
                this.notify('Global queue granted. Encoding started.', 'info', 2)
                start_current_export_job(job)
                return
            end
            if response.state == 'cancelled' then
                this.notify('Global queue job was cancelled.', 'warn', 3)
                job.state = 'cancelled'
                finalize_current_export_job()
                return
            end
            if response.state ~= 'pending' then
                fail_current_queue_job(job, 'unexpected job state: ' .. tostring(response.state))
                return
            end
            job.global_queue_position = response.position
            menu_update_if_active()
            poll_global_queue_job(job)
        end)
    end)
end

process_export_queue = function()
    if current_export_job or #export_queue == 0 then
        return
    end

    local job = table.remove(export_queue, 1)
    current_export_job = job
    is_encoding = true

    if not queue_client.is_enabled() then
        start_current_export_job(job)
        return
    end

    job.state = 'global_queue_waiting'
    menu_update_if_active()
    queue_client.request(job, function(response, err)
        if current_export_job ~= job or job.state ~= 'global_queue_waiting' then
            return
        end
        if not response then
            fail_current_queue_job(job, err)
            return
        end
        if response.state == 'granted' then
            job.global_queue_granted = true
            job.global_queue_lease_id = response.lease_id
            job.global_queue_lease_deadline = response.lease_deadline
            job.global_queue_position = 0
            start_global_queue_heartbeat(job)
            start_current_export_job(job)
            return
        end
        if response.state == 'pending' then
            job.global_queue_position = response.position
            this.notify(string.format('Waiting for global queue. Position: %s.', tostring(response.position or '?')), 'info', 2)
            menu_update_if_active()
            poll_global_queue_job(job)
            return
        end

        fail_current_queue_job(job, 'unexpected job state: ' .. tostring(response.state))
    end)
end

mp.register_event('shutdown', function()
    local job = current_export_job
    if not job then return end
    stop_global_queue_heartbeat(job)
    if job.global_queue_id then
        queue_client.cancel(job.global_queue_id, job.global_queue_lease_id)
    end
    if job.encoder_handle and job.encoder_handle.cancel then
        job.global_queue_released = true
        job.encoder_handle.cancel()
    end
end)

local function enqueue_export_job(job)
    job.id = next_export_job_id
    next_export_job_id = next_export_job_id + 1
    job.state = 'queued'
    remember_last_export(job)
    table.insert(export_queue, job)

    if current_export_job then
        this.notify(string.format("Queued %s. Pending: %d.", describe_export_job(job), #export_queue), "info", 2)
    else
        this.notify(string.format("Queued %s.", describe_export_job(job)), "info", 2)
    end

    menu_update_if_active()
    process_export_queue()
end

local function repeat_last_export(force_overwrite)
    if not last_export_snapshot then
        return this.notify("No previous export to repeat.", "warn", 2)
    end

    local snap = this.deepcopy(last_export_snapshot)
    if snap.kind ~= 'test_encode' and snap.kind ~= 'anki_add' and snap.kind ~= 'update_notes' then
        mp.msg.error("Repeat export aborted: unsupported snapshot kind " .. tostring(snap.kind))
        return this.notify("Previous export snapshot is invalid.", "warn", 3)
    end

    if force_overwrite and snap.kind == 'update_notes' then
        snap.overwrite = true
    end

    snap.repeated = true
    snap.report_prefix = 'Repeated export'
    enqueue_export_job(snap)
end

------------------------------------------------------------
-- default config

config = {
    nuke_spaces = false,
    remove_arrows = "join_arrow",
    preserve_newlines_in_anki = true,
    preserve_japanese_parentheses = false,
    copy_text_mode = "single_line",
    copy_text_custom_pattern = "",
    copy_text_custom_replacement = "",
    copy_text_custom_scope = "all",
    copy_text_custom_base_mode = "single_line",
    -- Deprecated: FFmpeg is always used; kept only to avoid warnings with older configs.
    use_ffmpeg = true,
    reload_config_before_card_creation = true,
    card_overwrite_safeguard = 1,
    autoclip = false,
    autoclip_method = "clipboard",
    autoclip_custom_args = "",
    secondary_sub_auto_load = true,
    secondary_sub_lang = 'eng,en,rus,ru,jp,jpn,ja',
    secondary_sub_area = 0.15,
    secondary_sub_visibility = 'auto',

    -- ===== BASE ENCODING OPTIONS =====
    -- These options are always active and expected to be specified

    -- Video settings
        enable_video = true,
    video_container = "mkv",
    video_codec = "libx264",
    video_bitrate = "500k",
    video_use_crf = true,
    video_crf = 20,
    -- Enable/disable built-in video filtering (scaling/FPS). When disabled, width/height and FPS settings are ignored.
    -- Choices: 'enabled' | 'disabled'
    video_filter = 'enabled',
    -- Video quality management: enabled | disabled | allow_combined_crf_bitrate
    video_quality_management = 'enabled',
    video_two_pass = false,
    video_width = cfg_mgr.preserve_aspect_ratio,
    video_height = cfg_mgr.default_height_px,
    video_fps = 24,
    video_preset = "slow",
    video_custom_args = "",
    video_padding = 0.12,
    -- Trim external text subtitle copies to cues that overlap the clip range.
    fix_subtitle_duration = false,

    -- Audio settings
    enable_audio = true,
    audio_track_count = 1,
    audio_lang_priority = "jp,jpn,ja,eng,en,und",
    audio_codec = "aac",
    audio_bitrate = "128k",
    audio_use_vbr = true,
    -- Audio quality management: enabled | disabled | allow_combined_vbr_bitrate
    audio_quality_management = 'enabled',
    audio_custom_args = "",
    audio_fade_in = 1.0,
    audio_fade_out = 1.0,

    -- Loudness normalization
    loudnorm_enabled = "no",
    loudnorm_two_pass = "no",
    loudnorm_I = "-23",
    loudnorm_LRA = "7",
    loudnorm_TP = "-2",
    loudnorm_linear = "yes",

    include_subtitles = true,
    include_external_subtitles = false,
    external_subtitle_unknown_language = "und",
    subtitle_track_count = 2,
    subtitle_lang_priority = "jp,jpn,ja,eng,ger,de",
    include_metadata = true,
    preview_video = "no",
    -- (removed duplicate loudnorm defaults)
    menu_font_name = "Noto Sans CJK JP",
    menu_font_size = 25,
    preview_text_char_limit = 40,
    captured_primarysub_preview_char_limit = 85,
    captured_secondarysub_preview_char_limit = 40,
    cap_video_custom_args_preview = false,
    subtitle_preview_font_scale = 1.0,
    show_selected_text = true,
    menu_key_open = "a",
    menu_key_set_start_to_sub = "S",
    menu_key_set_end_to_sub = "F",
    menu_key_set_start = "s",
    menu_key_set_end = "f",
    menu_key_set_start_from_clipboard = "alt+s",
    menu_key_set_end_from_clipboard = "alt+d",
    menu_key_capture_current = "c",
    menu_key_clear_capture_resume = "C",
    menu_key_toggle_capture = "v",
    menu_key_reset_all = "V",
    menu_key_clear_capture_stop = "Ctrl+alt+c",
    menu_key_seek_previous = "q",
    menu_key_seek_next = "e",
    menu_key_seek_previous_pause = "alt+q",
    menu_key_seek_next_pause = "alt+e",
    menu_key_gui_export = "ctrl+G",
    menu_key_export_note = "ctrl+n",
    menu_key_update_selected = "b",
    menu_key_overwrite_selected = "B",
    menu_key_update_last = "ctrl+m",
    menu_key_overwrite_last = "ctrl+M",
    menu_key_remove_current_subtitle = "g",
    menu_key_test_encode = "h",
    menu_key_repeat_export_overwrite = "X",
    menu_key_repeat_export_respect = "ctrl+X",
    menu_key_refresh_anki_preview = "r",
    menu_key_increment_cards = "U",
    menu_key_decrement_cards = "u",
    menu_key_toggle_autoclip = "z",
    menu_key_cycle_autoclip_method = "Z",
    menu_key_cycle_hints = "i",
    menu_key_toggle_target_preview = "R",
    menu_key_toggle_queue_details = "t",
    menu_key_toggle_encode_command = "T",
    menu_key_toggle_error_tail = "ctrl+T",
    menu_key_load_last_timings = "x",
    menu_key_toggle_subtitle_export = "y",
    menu_key_next_profile = "WHEEL_UP",
    menu_key_previous_profile = "WHEEL_DOWN",
    menu_key_increase_menu_font = "shift+ctrl+WHEEL_UP",
    menu_key_decrease_menu_font = "shift+ctrl+WHEEL_DOWN",
    menu_key_cycle_field_set = "alt+f",
    menu_key_close = "ESC",
    global_key_copy_primary = "Ctrl+c",
    global_key_copy_secondary = "Ctrl+C",
    global_key_secondary_visibility = "Ctrl+v",
    global_key_secondary_previous = "Ctrl+k",
    global_key_secondary_next = "Ctrl+j",
    global_key_quick_line_menu = "ctrl+g",
    global_key_quick_card_menu = "Alt+g",
    global_key_sub_rewind = "Ctrl+h",
    global_key_sub_replay = "Ctrl+H",
    global_key_sub_play_to_next = "Ctrl+L",
    global_key_restart_mpv_current_file = "Ctrl+Y",
    create_deck = false,
    allow_duplicates = false,
    deck_name = "jap_words",
    model_name = "Yomi-custom",
    field_sets = {},
    sentence_field_1 = "example-sentence-mpv-anki-clips",
    secondary_field_1 = "example-sentence-translation-mpv-anki-clips",
    video_field_1 = "picture-mpv-anki-clips",
    miscinfo_field_1 = "notes",
    sentence_field_2 = "example-sentence-2",
    secondary_field_2 = "example-sentence-translation-2",
    video_field_2 = "picture-2",
    miscinfo_field_2 = "notes-2",
    sentence_field_3 = "example-sentence-3",
    secondary_field_3 = "example-sentence-translation-3",
    video_field_3 = "picture-3",
    miscinfo_field_3 = "notes-3",
    video_template = '<video controls="" src="%s" class="clip-tv-general"></video>',
    append_media = true,
    disable_gui_browse = false,
    highlight_exported_notes_in_browser = true,
    ankiconnect_url = '127.0.0.1:8765',
    ankiconnect_api_key = '',
    note_tag = "mpv-anki-clips_video_mod",
    tag_nuke_brackets = true,
    tag_nuke_parentheses = false,
    tag_del_episode_num = true,
    tag_del_after_episode_num = true,
    tag_filename_lowercase = false,
    miscinfo_enable = true,
    miscinfo_format = "%n | (%t) | (loudnorm: %l)",
    -- Queue details preview shown in the OSD export queue when toggled with Shift+T.
    -- Reuses the existing placeholder formatter and adds:
    -- %p       active profile name
    -- %precl   approximate clip length from queued start/end, with milliseconds
    -- %preclms approximate clip length from queued start/end, without milliseconds
    queue_details_format = "%fn | (%p) | (%stms-%etms, length: %preclms) | (loudnorm: %l)",
    use_forvo = "no",
    vocab_field = "VocabKanji",
    vocab_audio_field = "VocabAudio",
    -- When true, if no subtitles are grabbed for export/update, try to read plain text
    -- from the system clipboard (only if non-empty) and use that as the subtitle text.
    -- Default: false
    use_clipboard_when_empty = false,
    clip_log_enabled = false,
    clip_log_save_dir = "",
    clip_log_duplicate_overlap_percent = 90,
    clip_log_advanced_encode_logging = false,
    queue_server_enabled = false,
    queue_server_host = "127.0.0.1",
    queue_server_port = 56789,
    queue_server_connect_timeout = 2,
    queue_server_request_timeout = 5,
    queue_server_heartbeat_interval = 10,
    -- Output directory for test encodes (triggered by 'o' key). When empty, defaults to Videos folder (Windows) or ~/Videos (others)
    test_encode_output_dir = "",
    ffmpeg_exec = "",

    -- Remote FFmpeg over SSH (Windows host supported).
    -- When enabled, MPV Anki Clips will run ffmpeg on a remote machine via ssh, writing the intermediate output to a shared staging directory,
    -- then copying the resulting clip back into the local output directory (e.g. Anki media folder).
    remote_ffmpeg_enabled = "no", -- yes|no
    remote_ssh_host = "",         -- e.g. JOHN-PC or 192.168.1.10
    remote_ssh_user = "",         -- optional
    remote_ssh_port = 22,
    remote_ssh_identity_file = "", -- optional path to private key
    remote_ssh_extra_args = "",    -- optional extra ssh args (shell-like string)
    remote_ffmpeg_exec = "ffmpeg", -- ffmpeg executable name/path on the remote machine
    -- Shared staging directory:
    -- - *_local: path as seen from THIS machine (laptop), used for copying the staged clip back locally
    -- - *_remote: path as seen from the REMOTE machine (host), used as FFmpeg output path
    -- If *_remote is empty, MPV Anki Clips assumes both machines see the same path.
    remote_encode_staging_dir_local = "", -- REQUIRED when remote_ffmpeg_enabled=yes; e.g. \\\\JOHN-PC\\Storage\\... or F:\\...
    remote_encode_staging_dir_remote = "", -- optional; e.g. D:\\Storage\\... if the host sees the share differently
    -- Optional path remapping rules for FFmpeg args (when input paths differ between machines).
    -- Format: localPrefix=>remotePrefix;localPrefix2=>remotePrefix2
    -- Example: \\\\JOHN-PC\\Storage\\=>D:\\Storage\\;F:\\=>D:\\Storage\\
    remote_path_map = "",
    remote_encode_cleanup = true,    -- delete staged clip + arg files after copying back

    -- Debug level for console logging: low | basic | advanced | full
    debug_level = "low",
}

local binding_default_keys = {}
for key in pairs(config) do
    if key == "menu_key_open" or key:match("^menu_key_") or key:match("^global_key_") then
        table.insert(binding_default_keys, key)
    end
end

for _, key in ipairs(binding_default_keys) do
    local default_scope
    if key == "menu_key_open" or key:match("^global_key_") then
        default_scope = "global"
    elseif key:match("^menu_key_") then
        default_scope = "advanced-menu"
    end
    if default_scope then
        config["binding_scope_" .. key] = default_scope
    end
end

local core_config = {}
local core_config_keys = {
    'card_overwrite_safeguard',
    'autoclip', 'autoclip_method', 'autoclip_custom_args',
    'copy_text_mode', 'copy_text_custom_pattern', 'copy_text_custom_replacement',
    'copy_text_custom_scope', 'copy_text_custom_base_mode', 'use_clipboard_when_empty',
    'create_deck', 'deck_name', 'model_name',
    'sentence_field_1', 'secondary_field_1', 'video_field_1', 'miscinfo_field_1',
    'sentence_field_2', 'secondary_field_2', 'video_field_2', 'miscinfo_field_2',
    'sentence_field_3', 'secondary_field_3', 'video_field_3', 'miscinfo_field_3',
    'note_tag', 'highlight_exported_notes_in_browser', 'subtitle_lang_priority',
    'secondary_sub_auto_load', 'secondary_sub_lang', 'secondary_sub_area',
    'secondary_sub_visibility', 'miscinfo_enable', 'queue_details_format',
    'subtitle_preview_font_scale', 'preview_text_char_limit',
    'captured_primarysub_preview_char_limit', 'captured_secondarysub_preview_char_limit',
    'cap_video_custom_args_preview', 'preview_video', 'test_encode_output_dir',
    'ffmpeg_exec',
    'remote_ffmpeg_enabled', 'remote_ssh_host', 'remote_ssh_user', 'remote_ssh_port',
    'remote_ssh_identity_file', 'remote_ssh_extra_args', 'remote_ffmpeg_exec',
    'remote_encode_staging_dir_local', 'remote_encode_staging_dir_remote',
    'remote_path_map', 'remote_encode_cleanup', 'use_forvo', 'vocab_field',
    'vocab_audio_field', 'menu_font_size', 'menu_font_name', 'show_selected_text',
    'menu_key_open',
    'menu_key_set_start_to_sub', 'menu_key_set_end_to_sub', 'menu_key_set_start',
    'menu_key_set_end', 'menu_key_set_start_from_clipboard', 'menu_key_set_end_from_clipboard',
    'menu_key_capture_current', 'menu_key_clear_capture_resume', 'menu_key_toggle_capture',
    'menu_key_reset_all', 'menu_key_clear_capture_stop', 'menu_key_seek_previous',
    'menu_key_seek_next', 'menu_key_seek_previous_pause', 'menu_key_seek_next_pause',
    'menu_key_gui_export', 'menu_key_export_note',
    'menu_key_update_selected', 'menu_key_overwrite_selected', 'menu_key_update_last',
    'menu_key_overwrite_last', 'menu_key_remove_current_subtitle', 'menu_key_test_encode',
    'menu_key_repeat_export_overwrite', 'menu_key_repeat_export_respect',
    'menu_key_refresh_anki_preview', 'menu_key_increment_cards', 'menu_key_decrement_cards',
    'menu_key_toggle_autoclip', 'menu_key_cycle_autoclip_method', 'menu_key_cycle_hints',
    'menu_key_toggle_target_preview', 'menu_key_toggle_queue_details',
    'menu_key_toggle_encode_command', 'menu_key_toggle_error_tail',
    'menu_key_load_last_timings', 'menu_key_toggle_subtitle_export',
    'menu_key_next_profile', 'menu_key_previous_profile',
    'menu_key_increase_menu_font', 'menu_key_decrease_menu_font',
    'menu_key_cycle_field_set', 'menu_key_close',
    'global_key_copy_primary', 'global_key_copy_secondary',
    'global_key_secondary_visibility', 'global_key_secondary_previous',
    'global_key_secondary_next', 'global_key_quick_line_menu',
    'global_key_quick_card_menu', 'global_key_sub_rewind',
    'global_key_sub_replay', 'global_key_sub_play_to_next',
    'global_key_restart_mpv_current_file',
    'ankiconnect_url', 'ankiconnect_api_key', 'fix_subtitle_duration', 'clip_log_enabled', 'clip_log_save_dir',
    'clip_log_advanced_encode_logging', 'clip_log_duplicate_overlap_percent',
    'queue_server_enabled', 'queue_server_host', 'queue_server_port',
    'queue_server_connect_timeout', 'queue_server_request_timeout',
    'queue_server_heartbeat_interval', 'debug_level',
}

local binding_scope_keys = {}
for _, key in ipairs(core_config_keys) do
    if key:match("^menu_key_") or key:match("^global_key_") then
        local scope_key = "binding_scope_" .. key
        if config[scope_key] == nil then
            error("Missing default for binding scope: " .. scope_key)
        end
        table.insert(binding_scope_keys, scope_key)
    end
end
for _, key in ipairs(binding_scope_keys) do
    table.insert(core_config_keys, key)
end

for _, key in ipairs(core_config_keys) do
    local value = config[key]
    if value == nil then
        error("Missing default for core setting: " .. key)
    end
    core_config[key] = value
    config[key] = nil
end
local profiles = {
    profiles = "mpv-anki-clips,tv_general,tv_highq,tv_voldown,tv_voldown_highq,games_general,games_highq,anime_general,anime_voldown,anime_volup",
    active = "mpv-anki-clips",
}

------------------------------------------------------------
-- utility functions

local function _(params)
    return function()
        return pcall(this.unpack(params))
    end
end

-- Format bytes as a human-readable string (e.g., 1.23 MB)
-- Convert bytes to MiB with two decimals
function bytes_to_mib(bytes)
    local size = tonumber(bytes) or 0
    return size / (1024 * 1024)
end

-- Format seconds as M:SS (minutes and seconds)
function seconds_to_mmss(seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 0 then seconds = 0 end
    local m = math.floor(seconds / 60)
    local s = math.floor(seconds % 60)
    return string.format("%d:%02d", m, s)
end

-- Format seconds as M:SS.mmm (minutes, seconds, milliseconds)
function seconds_to_m_ss_mmm(seconds)
    seconds = tonumber(seconds)
    if not seconds or seconds <= 0 then
        return "unknown"
    end
    local m = math.floor(seconds / 60)
    local s = math.floor(seconds % 60)
    local ms = math.floor((seconds * 1000) % 1000)
    return string.format("%d:%02d.%03d", m, s, ms)
end

local function get_last_encode_mib_string()
    local sz = encoder.get_last_encode_filesize and encoder.get_last_encode_filesize() or nil
    if sz and sz > 0 then
        return string.format("%.2f MiB", bytes_to_mib(sz))
    end
    return "unknown"
end

local function get_last_encode_length_string()
    local dur = encoder.get_last_encode_duration and encoder.get_last_encode_duration() or nil
    return seconds_to_m_ss_mmm(dur)
end

local function get_last_encode_length_no_ms_string()
    local dur = encoder.get_last_encode_duration and encoder.get_last_encode_duration() or nil
    if not dur or dur <= 0 then
        return "unknown"
    end
    return seconds_to_mmss(dur)
end

-- Try to read output file duration via ffprobe; fall back to provided seconds on failure
function probe_duration_seconds(path, fallback_seconds)
    if this.is_empty(path) then return fallback_seconds end
    local args = {
        'ffprobe', '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1',
        path
    }
    local res = this.subprocess(args, nil, { log_command = false, capture_stdout = true, capture_stderr = true })
    if res and res.status == 0 and res.stdout and res.stdout ~= '' then
        local val = tonumber((res.stdout:gsub("\r", ""):gsub("\n", "")))
        if val and val > 0 then return val end
    end
    return fallback_seconds
end

local function escape_for_osd(str)
    str = this.trim(str, false, config.preserve_japanese_parentheses, config.remove_arrows)
    str = this.remove_newlines(str)
    str = subs_observer.maybe_remove_all_spaces(str)
    str = str:gsub('[%[%]{}]', '')
    mp.msg.debug("OSD text: " .. str)
    return str
end

local function ensure_deck()
    if config.create_deck == true then
        ankiconnect.create_deck(config.deck_name)
    end
end

local function load_next_profile()
    cfg_mgr.next_profile()
    ensure_deck()
    this.notify("Loaded profile " .. profiles.active, "info", 1, false)
    logger.info_cat('profile_load', "Loaded profile " .. profiles.active)
    if menu.active then menu:update() end
end

local function load_previous_profile()
    cfg_mgr.previous_profile()
    ensure_deck()
    this.notify("Loaded profile " .. profiles.active, "info", 1, false)
    logger.info_cat('profile_load', "Loaded profile " .. profiles.active)
    if menu.active then menu:update() end
end

local function cycle_field_set()
    if not config.field_sets or #config.field_sets == 0 then
        active_field_set = 1
        this.notify("No field sets defined, using default set #1", "warn", 2)
        mp.msg.warn("Field sets empty or not defined")
    else
        mp.msg.debug("Before cycling: active_field_set=" .. active_field_set .. ", field_sets_count=" .. #config.field_sets)
        active_field_set = (active_field_set % #config.field_sets) + 1
        mp.msg.debug("After cycling: active_field_set=" .. active_field_set)
        this.notify("Switched to field set #" .. active_field_set .. " (" .. config.field_sets[active_field_set].sentence_field .. ")", "info", 2)
        mp.msg.info("Cycled to field set #" .. active_field_set .. " of " .. #config.field_sets .. " (" .. config.field_sets[active_field_set].sentence_field .. ")")
    end
    if menu.active then menu:update() end
end

local function adjust_menu_font_size(delta)
    local step = tonumber(delta) or 0
    if step == 0 then
        return
    end

    local current = tonumber(config.menu_font_size) or 25
    local updated = math.floor(current + step)
    if updated < 1 then updated = 1 end
    if updated > 96 then updated = 96 end
    config.menu_font_size = updated
    this.notify("UI preview font size: " .. tostring(updated) .. " (temporary; edit config to persist)", "info", 2)
end

local function get_active_field_set()
    if not config.field_sets or #config.field_sets == 0 then
        mp.msg.warn("No field sets defined, returning default set #1")
        return {
            sentence_field = config.sentence_field_1,
            secondary_field = config.sentence_field_1,
            video_field = config.video_field_1,
            miscinfo_field = config.miscinfo_field_1,
        }
    end
    if active_field_set < 1 or active_field_set > #config.field_sets then
        mp.msg.warn("Invalid active_field_set (" .. active_field_set .. "), resetting to 1")
        active_field_set = 1
    end
    return config.field_sets[active_field_set]
end

tag_format = function(filename, export_config)
    local cfg = export_config or config
    filename = this.remove_extension(filename)
    filename = this.remove_common_resolutions(filename)

    local s, e, episode_num = this.get_episode_number(filename)

    if cfg.tag_del_episode_num == true and not this.is_empty(s) then
        if cfg.tag_del_after_episode_num == true then
            filename = filename:sub(1, s)
        else
            filename = filename:sub(1, s) .. filename:sub(e + 1, -1)
        end
    end

    if cfg.tag_nuke_brackets == true then
        filename = this.remove_text_in_brackets(filename)
    end
    if cfg.tag_nuke_parentheses == true then
        filename = this.remove_filename_text_in_parentheses(filename)
    end

    if cfg.tag_filename_lowercase == true then
        filename = filename:lower()
    end

    filename = this.remove_leading_trailing_spaces(filename)
    filename = filename:gsub(" ", "_")
    filename = filename:gsub("_%-_", "_")
    filename = this.remove_leading_trailing_dashes(filename)
    return filename, episode_num or ''
end

local function substitute_loudnorm(tag)
    if config.loudnorm_enabled == "yes" then
        return tag:gsub("%%l", string.format("I=%s:LRA=%s:TP=%s", config.loudnorm_I, config.loudnorm_LRA, config.loudnorm_TP))
    else
        return tag:gsub("%%l", "none")
    end
end

substitute_fmt = (function()
    local function substitute_filename(tag, filename)
        return tag:gsub("%%n", filename)
    end
    local function substitute_full_filename(tag, raw_filename)
        return tag:gsub("%%fn", raw_filename)
    end
    local function substitute_path(tag, media_path)
        return tag:gsub("%%path", media_path or '')
    end
    local function substitute_profile_name(tag, profile_name)
        return tag:gsub("%%p", profile_name or '')
    end
    local function substitute_dir(tag, media_dir)
        return tag:gsub("%%dir", media_dir or '')
    end
    local function substitute_title(tag, media_title)
        return tag:gsub("%%title", media_title or '')
    end
    local function substitute_episode_number(tag, episode)
        return tag:gsub("%%d", episode)
    end
    local function substitute_time_pos(tag, time_pos)
        return tag:gsub("%%t", this.human_readable_time(time_pos))
    end
    local function substitute_time_pos_no_ms(tag, time_pos)
        return tag:gsub("%%tms", this.human_readable_time_no_ms(time_pos))
    end
    local function substitute_time_start(tag, sub, time_pos)
        local time_start = sub and sub['start'] or time_pos
        return tag:gsub("%%st", this.human_readable_time(time_start))
    end
    local function substitute_time_start_no_ms(tag, sub, time_pos)
        local time_start = sub and sub['start'] or time_pos
        return tag:gsub("%%stms", this.human_readable_time_no_ms(time_start))
    end
    local function substitute_time_end(tag, sub, time_pos)
        local time_end = sub and sub['end'] or time_pos
        return tag:gsub("%%et", this.human_readable_time(time_end))
    end
    local function substitute_time_end_no_ms(tag, sub, time_pos)
        local time_end = sub and sub['end'] or time_pos
        return tag:gsub("%%etms", this.human_readable_time_no_ms(time_end))
    end
    local function substitute_envvar(tag)
        local env_tags = os.getenv('MPV_ANKI_CLIPS_TAGS') or ''
        return tag:gsub("%%e", env_tags)
    end
    local function substitute_loudnorm(tag, export_config)
        local cfg = export_config or config
        if cfg.loudnorm_enabled == "yes" then
            return tag:gsub("%%l", string.format("I=%s:LRA=%s:TP=%s", cfg.loudnorm_I, cfg.loudnorm_LRA, cfg.loudnorm_TP))
        else
            return tag:gsub("%%l", "none")
        end
    end
    local function substitute_output_size_mib(tag)
        return tag:gsub("%%mib", get_last_encode_mib_string())
    end
    local function substitute_output_clip_length(tag)
        return tag:gsub("%%cl", get_last_encode_length_string())
    end
    local function substitute_output_clip_length_no_ms(tag)
        return tag:gsub("%%clms", get_last_encode_length_no_ms_string())
    end
    local function substitute_preencode_clip_length(tag, clip_length_seconds)
        local value = clip_length_seconds and seconds_to_m_ss_mmm(clip_length_seconds) or 'unknown'
        return tag:gsub("%%precl", value)
    end
    local function substitute_preencode_clip_length_no_ms(tag, clip_length_seconds)
        local value = clip_length_seconds and seconds_to_mmss(clip_length_seconds) or 'unknown'
        return tag:gsub("%%preclms", value)
    end
    return function(tag, sub, captured, export_config, placeholder_context)
        local cfg = export_config or config
        if not this.is_empty(tag) then
            local filename, episode, raw_filename
            local context = placeholder_context or {}
            if captured and captured.filename and captured.episode then
                filename, episode = captured.filename, captured.episode
                raw_filename = captured.raw_filename
            else
                raw_filename = mp.get_property("filename") or ''
                filename, episode = tag_format(raw_filename, cfg)
            end

            local media_path = (captured and captured.media_path) or (mp.get_property("path") or '')
            local media_dir = (captured and captured.media_dir)
            if media_dir == nil then
                local dir, _ = utils.split_path(media_path)
                media_dir = dir or ''
            end
            local media_title = (captured and captured.media_title) or (mp.get_property("media-title") or '')
            local time_pos = (captured and captured.time_pos) or mp.get_property_number('time-pos') or 0

            raw_filename = raw_filename or (mp.get_property("filename") or '')
            tag = substitute_full_filename(tag, raw_filename)
            tag = substitute_filename(tag, filename)
            tag = substitute_path(tag, media_path)
            tag = substitute_dir(tag, media_dir)
            tag = substitute_title(tag, media_title)
            tag = substitute_episode_number(tag, episode)
            tag = substitute_time_pos_no_ms(tag, time_pos)
            tag = substitute_time_pos(tag, time_pos)
            tag = substitute_time_start_no_ms(tag, sub, time_pos)
            tag = substitute_time_start(tag, sub, time_pos)
            tag = substitute_time_end_no_ms(tag, sub, time_pos)
            tag = substitute_time_end(tag, sub, time_pos)
            tag = substitute_envvar(tag)
            tag = substitute_loudnorm(tag, cfg)
            tag = substitute_preencode_clip_length_no_ms(tag, context.approximate_clip_length_seconds)
            tag = substitute_preencode_clip_length(tag, context.approximate_clip_length_seconds)
            tag = substitute_output_size_mib(tag)
            tag = substitute_output_clip_length_no_ms(tag)
            tag = substitute_output_clip_length(tag)
            tag = substitute_profile_name(tag, context.profile_name or profiles.active or '')
            tag = this.remove_leading_trailing_spaces(tag)
        end
        return tag
    end
end)()

local function prepare_for_exporting(sub_text, export_config)
    local cfg = export_config or config
    if not this.is_empty(sub_text) then
        mp.msg.debug("Before trim: " .. sub_text)
        sub_text = this.trim(sub_text, cfg.preserve_newlines_in_anki, cfg.preserve_japanese_parentheses, cfg.remove_arrows, true)
        mp.msg.debug("After trim: " .. sub_text)
        sub_text = this.escape_special_characters(sub_text)
        mp.msg.debug("After escape: " .. sub_text)
        sub_text = this.convert_newlines_to_br(sub_text)
        mp.msg.debug("After convert_newlines: " .. sub_text)
        if cfg.nuke_spaces then
            sub_text = subs_observer.maybe_remove_all_spaces(sub_text)
            mp.msg.debug("After maybe_remove_all_spaces: " .. sub_text)
        end
    end
    return sub_text
end

function construct_note_fields(sub_text, secondary_text, video_filename, sub, active_fields, subtitles_disabled, captured, export_config)
    local cfg = export_config or config
    -- Use provided snapshot of active_fields when available to avoid race with user changing field set mid-encode
    local active_fields = active_fields or get_active_field_set()
    local subtitles_export_off = subtitles_export_disabled
    if subtitles_disabled ~= nil then
        subtitles_export_off = subtitles_disabled
    end
    local ret = {}
    if not subtitles_export_off then
        ret[active_fields.sentence_field] = prepare_for_exporting(sub_text, cfg)
        if not this.is_empty(active_fields.secondary_field) then
            ret[active_fields.secondary_field] = prepare_for_exporting(secondary_text, cfg)
        end
    end
    if not this.is_empty(active_fields.video_field) and not this.is_empty(video_filename) then
        ret[active_fields.video_field] = string.format(cfg.video_template, video_filename)
    end
    if cfg.miscinfo_enable == true and not this.is_empty(active_fields.miscinfo_field) then
        ret[active_fields.miscinfo_field] = substitute_fmt(cfg.miscinfo_format, sub, captured, cfg)
    end
    mp.msg.debug("Constructed note fields: " .. table.concat({ret[active_fields.sentence_field]}, ", "))
    return ret
end

local function join_media_fields(new_data, stored_data, active_fields)
    local active_fields = active_fields or get_active_field_set()
    for _, field in pairs { active_fields.video_field, active_fields.miscinfo_field } do
        if not this.is_empty(field) then
            new_data[field] = this.table_get(stored_data, field, "") .. this.table_get(new_data, field, "")
        end
    end
    return new_data
end

local function update_sentence(new_data, stored_data, active_fields)
    local active_fields = active_fields or get_active_field_set()
    if this.is_empty(stored_data[active_fields.sentence_field]) then
        return new_data
    elseif this.is_empty(new_data[active_fields.sentence_field]) then
        new_data[active_fields.sentence_field] = stored_data[active_fields.sentence_field]
        return new_data
    end

    local _, opentag, target, closetag, _ = stored_data[active_fields.sentence_field]:match('^(.-)(<[^>]+>)(.-)(</[^>]+>)(.-)$')
    if target then
        local prefix, _, suffix = new_data[active_fields.sentence_field]:match(table.concat { '^(.-)(', target, ')(.-)$' })
        if prefix and suffix then
            new_data[active_fields.sentence_field] = table.concat { prefix, opentag, target, closetag, suffix }
        end
    end
    return new_data
end

function video_padding(is_subtitle_based, export_config)
    local cfg = export_config or config
    local video_duration = mp.get_property_number('duration')
    if cfg.video_padding == 0.0 or not video_duration then
        this.notify("No padding applied: zero or invalid duration", "info", 2)
        return 0.0
    end
    if not is_subtitle_based then
        this.notify("No padding applied: manual timings", "info", 2)
        return 0.0
    end
    this.notify(string.format("Padding applied: %.2fs (subtitle-based)", cfg.video_padding), "info", 2)
    return cfg.video_padding
end

------------------------------------------------------------
-- front for adding and updating notes

local function maybe_reload_config()
    if config.reload_config_before_card_creation then
        cfg_mgr.reload_from_disk()
        codec_support.configure(config)
    end
end

function get_anki_media_dir_path()
    return ankiconnect.get_media_dir_path()
end

local function get_test_encode_output_dir()
    -- Prefer explicit config value
    local dir = config.test_encode_output_dir
    if dir and dir ~= '' then
        return dir
    end
    -- Fallbacks by platform
    if platform.windows then
        local home = os.getenv("USERPROFILE") or os.getenv("HOMEPATH") or ""
        if home ~= '' then
            return home .. "\\Videos"
        end
    end
    local home = os.getenv("HOME") or ""
    if home ~= '' then
        return home .. "/Videos"
    end
    return mp.get_property("working-directory") or "."
end

local function export_to_anki(gui)
    maybe_reload_config()
    local sub = subs_observer.collect_from_current()
    local is_subtitle_based = subs_observer.is_subtitle_based_timing()
    local had_subtitle_text = not this.is_empty(sub['text'])
    local used_clipboard = false

    if not sub:is_valid() then
        return this.notify("Nothing to export: invalid subtitle data.", "warn", 1)
    end

    mp.msg.info("Subtitle data: start=" .. tostring(sub['start']) .. ", end=" .. tostring(sub['end']) .. ", text=" .. tostring(sub['text']))

    if not gui and this.is_empty(sub['text']) then
        -- If enabled, try to use clipboard text when no subtitles were grabbed.
        if config.use_clipboard_when_empty and platform.get_clipboard then
            local clip = platform.get_clipboard()
            if not this.is_empty(clip) then
                mp.msg.info('Using clipboard contents as subtitle text for export')
                mp.msg.debug("clipboard length=" .. tostring(#clip) .. ", snippet='" .. clip:sub(1,80):gsub('\n','\\n') .. "'")
                sub['text'] = clip
                used_clipboard = true
                this.notify("Using clipboard text", "info", 2, true)
            else
                mp.msg.debug('Clipboard fallback: clipboard empty or unavailable for export')
                sub['text'] = string.format("MPV Anki Clips wasn't able to grab subtitles (%s)", os.time())
            end
        else
            sub['text'] = string.format("MPV Anki Clips wasn't able to grab subtitles (%s)", os.time())
        end
    end

    -- Save last timings from the actual sub timings to ensure availability
    subs_observer.save_last_timings_values(sub['start'], sub['end'])

    local active_fields = get_active_field_set()
    local snapshot_config = make_export_snapshot_config(active_fields)
    local captured = capture_export_context(snapshot_config)
    local output_dir = get_anki_media_dir_path()
    if not output_dir or output_dir == '' then
        return this.notify("Output directory unavailable. Export aborted.", "warn", 3)
    end

    subs_observer.clear()
    subs_observer.clear_all_dialogs()
    quick_creation_opts:reset_all()
    mp.msg.info("Using snapshot field set #" .. tostring(active_field_set) .. " (" .. tostring(active_fields.sentence_field) .. ") for this export")

    enqueue_export_job {
        kind = 'anki_add',
        gui = gui,
        profile_name = profiles.active,
        config = snapshot_config,
        media_snapshot = capture_media_snapshot(),
        output_dir = output_dir,
        report_prefix = 'Anki export',
        target_summary = string.format("%s / %s", tostring(snapshot_config.deck_name or 'deck'), tostring(snapshot_config.model_name or 'model')),
        active_field_set_index = active_field_set,
        field_population_state = 'empty',
        active_fields = clone_active_fields(active_fields),
        text_source_kind = get_text_source_kind(subtitles_export_disabled, had_subtitle_text, used_clipboard),
        subtitles_export_disabled = subtitles_export_disabled,
        is_subtitle_based = is_subtitle_based,
        sub = clone_export_sub(sub),
        captured = clone_captured_info(captured),
        queued_browser_note = menu and menu.anki_target_browser_note or nil,
    }
    menu_update_if_active()
end

-- Perform a test encode only (no Anki interaction)
local function export_test_encode()
    maybe_reload_config()
    local sub = subs_observer.collect_from_current()
    local is_subtitle_based = subs_observer.is_subtitle_based_timing()

    if not sub:is_valid() then
        return this.notify("Nothing to encode: invalid subtitle data.", "warn", 1)
    end

    -- Save last timings for convenience
    subs_observer.save_last_timings_values(sub['start'], sub['end'])
    local snapshot_config = make_export_snapshot_config(nil)
    local captured = capture_export_context(snapshot_config)
    enqueue_export_job {
        kind = 'test_encode',
        profile_name = profiles.active,
        config = snapshot_config,
        media_snapshot = capture_media_snapshot(),
        output_dir = get_test_encode_output_dir(),
        report_prefix = 'Test encode',
        target_summary = 'local clip',
        is_subtitle_based = is_subtitle_based,
        sub = clone_export_sub(sub),
        captured = clone_captured_info(captured),
    }
    subs_observer.clear()
    subs_observer.clear_all_dialogs()
    quick_creation_opts:reset_all()
    menu_update_if_active()
end


local function as_callback(fn, ...)
    local args = {...}
    return function()
        return fn(this.unpack(args))
    end
end

local function notify_user_on_finish(note_ids, export_config)
    local queries = {}
    for _, note_id in ipairs(note_ids) do
        table.insert(queries, string.format("nid:%s", tostring(note_id)))
    end
    local query = table.concat(queries, " OR ")
    if should_highlight_exported_notes(export_config) then
        ankiconnect.gui_browse(query, export_config)
    end

    if #note_ids > 1 then
        this.notify(string.format("Updated %i notes.", #note_ids))
        refresh_anki_target_info_once(0)
    else
        local result_notify = function(_, result, _)
            local note_info, error = ankiconnect.parse_result(result)
            if not error and note_info and note_info[1] then
                local note_display_name = note_display_name_from_info(note_info[1])
                if note_display_name then
                    this.notify(string.format("Updated note: %s", note_display_name))
                else
                    this.notify(string.format("Updated note #%s.", tostring(note_ids[1])))
                end
            else
                this.notify(string.format("Updated note #%s.", tostring(note_ids[1])))
            end
            refresh_anki_target_info_once(0)
        end

        ankiconnect.execute({
            action = "notesInfo",
            version = 6,
            params = {
                notes = { note_ids[1] }
            }
        }, result_notify, export_config)
    end
end

function change_fields(note_ids, new_data, overwrite, active_fields, export_config, sub, captured, on_finish_fn)
    local cfg = export_config or config
    local af = active_fields or get_active_field_set()
    local had_error = false
    local updated_note_ids = {}

    if type(note_ids) ~= 'table' or #note_ids == 0 then
        mp.msg.error("Anki note update aborted: no target notes were provided.")
        if type(on_finish_fn) == 'function' then
            on_finish_fn(false)
        end
        return false
    end

    local change_notes_countdown = dec_counter.new(#note_ids).on_finish(function()
        if #updated_note_ids > 0 then
            notify_user_on_finish(updated_note_ids, cfg)
        end
        if had_error then
            this.notify(string.format(
                "Updated %d of %d notes; one or more note operations failed.",
                #updated_note_ids,
                #note_ids
            ), "warn", 3)
        end
        if type(on_finish_fn) == 'function' then
            on_finish_fn(not had_error)
        end
    end)

    return with_forvo_export_config(cfg, function()
        for _, note_id in ipairs(note_ids) do
            local stored_data, stored_error = ankiconnect.get_note_fields(note_id)
            if not stored_data then
                had_error = true
                mp.msg.error(string.format(
                    "Skipping update for note %s because its current fields could not be read: %s",
                    tostring(note_id),
                    tostring(stored_error or "AnkiConnect returned no fields")
                ))
                change_notes_countdown.decrease()
            else
                local note_data = this.deepcopy(new_data)
                note_data = forvo.append(note_data, stored_data)
                note_data = update_sentence(note_data, stored_data, af)
                if not overwrite then
                    if cfg.append_media then
                        note_data = join_media_fields(note_data, stored_data, af)
                    else
                        note_data = join_media_fields(stored_data, note_data, af)
                    end
                end

                if this.is_empty(note_data[af.sentence_field]) then
                    note_data[af.sentence_field] = string.format("MPV Anki Clips wasn't able to grab subtitles (%s)", os.time())
                end

                ankiconnect.append_media(
                    note_id,
                    note_data,
                    substitute_fmt(cfg.note_tag, sub, captured, cfg),
                    function(error)
                        if error then
                            had_error = true
                            mp.msg.error(string.format(
                                "Anki update failed for note %s: %s",
                                tostring(note_id),
                                tostring(error)
                            ))
                        else
                            table.insert(updated_note_ids, note_id)
                        end
                        change_notes_countdown.decrease()
                    end,
                    cfg
                )
            end
        end
    end)
end

local function update_notes(note_ids, overwrite)
    maybe_reload_config()
    local sub
    local is_subtitle_based = subs_observer.is_subtitle_based_timing()
    local n_lines = quick_creation_opts:get_lines()
    if n_lines then
        sub = subs_observer.collect_from_all_dialogues(n_lines)
    else
        sub = subs_observer.collect_from_current()
    end
    local had_subtitle_text = not this.is_empty(sub['text'])
    local used_clipboard = false

    if not sub:is_valid() then
        return this.notify("Nothing to export: invalid subtitle data.", "warn", 2)
    end

    mp.msg.info("Subtitle data: start=" .. tostring(sub['start']) .. ", end=" .. tostring(sub['end']) .. ", text=" .. tostring(sub['text']))

    -- If subtitle text is empty, try clipboard fallback (when enabled).
    if this.is_empty(sub['text']) then
        if config.use_clipboard_when_empty and platform.get_clipboard then
            local clip = platform.get_clipboard()
            if this.is_empty(clip) then
                -- Immediate second attempt (clipboard may have just been updated by OS)
                local retry = platform.get_clipboard()
                if not this.is_empty(retry) then
                    mp.msg.info('Using clipboard contents (retry) as subtitle text for update')
                    mp.msg.debug("clipboard length=" .. tostring(#retry) .. ", snippet='" .. retry:sub(1,80):gsub('\n','\\n') .. "'")
                    sub['text'] = retry
                    used_clipboard = true
                    this.notify("Using clipboard text (retry)", "info", 2, true)
                else
                    mp.msg.debug('Clipboard fallback: empty after two attempts for update; using placeholder message')
                    sub['text'] = string.format("MPV Anki Clips wasn't able to grab subtitles (%s)", os.time())
                end
            else
                mp.msg.info('Using clipboard contents as subtitle text for update')
                mp.msg.debug("clipboard length=" .. tostring(#clip) .. ", snippet='" .. clip:sub(1,80):gsub('\n','\\n') .. "'")
                sub['text'] = clip
                used_clipboard = true
                this.notify("Using clipboard text", "info", 2, true)
            end
        else
            -- Clipboard fallback disabled; use placeholder so downstream logic is clear
            sub['text'] = string.format("MPV Anki Clips wasn't able to grab subtitles (%s)", os.time())
        end
    end

    -- Save last timings from the actual sub timings to ensure availability
    subs_observer.save_last_timings_values(sub['start'], sub['end'])

    local active_fields = get_active_field_set()
    local snapshot_config = make_export_snapshot_config(active_fields)
    local captured = capture_export_context(snapshot_config)
    local anki_media_dir = get_anki_media_dir_path()
    if not anki_media_dir or anki_media_dir == '' then
        return this.notify("Output directory unavailable. Update aborted.", "warn", 3)
    end

    subs_observer.clear()
    subs_observer.clear_all_dialogs()
    quick_creation_opts:reset_all()
    enqueue_export_job {
        kind = 'update_notes',
        profile_name = profiles.active,
        config = snapshot_config,
        media_snapshot = capture_media_snapshot(),
        output_dir = anki_media_dir,
        report_prefix = 'Anki update',
        note_ids = clone_note_ids(note_ids),
        overwrite = overwrite,
        target_summary = get_note_target_summary(note_ids),
        active_field_set_index = active_field_set,
        field_population_state = get_field_population_state(note_ids, active_fields, subtitles_export_disabled, snapshot_config),
        active_fields = clone_active_fields(active_fields),
        update_mode = overwrite and 'replace' or 'add',
        text_source_kind = get_text_source_kind(subtitles_export_disabled, had_subtitle_text, used_clipboard),
        subtitles_export_disabled = subtitles_export_disabled,
        is_subtitle_based = is_subtitle_based,
        sub = clone_export_sub(sub),
        captured = clone_captured_info(captured),
        queued_browser_note = menu and menu.anki_target_browser_note or nil,
    }
    menu_update_if_active()
end

local function update_last_note(overwrite)
    maybe_reload_config()

    local n_cards = quick_creation_opts:get_cards()
    local last_note_ids = ankiconnect.get_last_note_ids(n_cards)
    n_cards = #last_note_ids

    if this.is_empty(last_note_ids) or last_note_ids[1] < this.minutes_ago(10) then
        return this.notify("Couldn't find the target note.", "warn", 2)
    end

    update_notes(last_note_ids, overwrite)
end

-- Restart mpv in a fresh terminal with the current file path (debug helper)
local function restart_mpv_current_file()
    local current_path = mp.get_property("path")
    if this.is_empty(current_path) then
        return this.notify("No current file to restart.", "warn", 2)
    end
    if platform.windows then
        -- Use `cmd /c start` to force a visible new console window regardless of mpv's subprocess flags.
        local ps_escaped = current_path:gsub("'", "''")
        local ps_command = string.format("mpv '%s'", ps_escaped)
        mp.msg.info("Restarting mpv in a new console with file: " .. current_path)
        this.notify("Restarting mpv (new console)...", "info", 2)
        this.subprocess({ 'cmd', '/c', 'start', '""', 'powershell', '-NoLogo', '-NoProfile', '-NoExit', '-Command', ps_command }, function()
            mp.command('quit')
        end, { log_command = true, detach = true, capture_stdout = false, capture_stderr = false })
        return
    end

    local function shell_quote(value)
        return "'" .. value:gsub("'", "'\\''") .. "'"
    end
    local terminals = {
        { name = 'x-terminal-emulator', args = function() return { '-e', 'mpv', '--', current_path } end },
        { name = 'gnome-terminal', args = function() return { '--', 'mpv', '--', current_path } end },
        { name = 'konsole', args = function() return { '-e', 'mpv', '--', current_path } end },
        { name = 'xfce4-terminal', args = function()
            return { '--disable-server', '--command=' .. shell_quote('mpv') .. ' -- ' .. shell_quote(current_path) }
        end },
        { name = 'xterm', args = function() return { '-e', 'mpv', '--', current_path } end },
    }

    for _, terminal in ipairs(terminals) do
        local available = this.subprocess({ 'sh', '-c', 'command -v ' .. terminal.name .. ' >/dev/null 2>&1' }, nil, { log_command = false })
        if available and available.status == 0 then
            local args = { terminal.name }
            for _, arg in ipairs(terminal.args()) do
                table.insert(args, arg)
            end
            mp.msg.info("Restarting mpv in " .. terminal.name .. " with file: " .. current_path)
            this.notify("Restarting mpv in a new terminal...", "info", 2)
            this.subprocess(args, function(success, result)
                if success then
                    mp.command('quit')
                else
                    mp.msg.error("Could not start mpv in " .. terminal.name .. ": " .. tostring(result and result.error or "terminal launch failed"))
                    this.notify("Could not start mpv in a new terminal.", "error", 3)
                end
            end, { log_command = true, detach = true, capture_stdout = false, capture_stderr = false })
            return
        end
    end

    mp.msg.error("Could not restart mpv: no supported terminal emulator was found.")
    this.notify("No supported terminal emulator found.", "error", 3)
end

local function update_selected_note(overwrite)
    maybe_reload_config()

    local selected_note_ids = ankiconnect.get_selected_note_ids()

    if this.is_empty(selected_note_ids) then
        return this.notify("Couldn't find the target note(s). Did you select the notes you want in Anki?", "warn", 3)
    end

    if #selected_note_ids > config.card_overwrite_safeguard then
        return this.notify(string.format("More than %i notes selected\nnot recommended, but you can change the limit in your config", config.card_overwrite_safeguard), "warn", 4)
    end

    update_notes(selected_note_ids, overwrite)
end

------------------------------------------------------------
-- main menu

menu = Menu:new {
    hints_state = switch.new { 'basic', 'menu', 'global', },
    show_encode_command = false,
    show_queue_details = false,
    show_error_tail = false,
    subtitles_export_disabled = false,
    show_anki_target_info = false,
    anki_target_browser_note = "(not loaded)",
    anki_target_browser_note_tone = 'inactive',
    anki_last_added_note = "(not loaded)",
    anki_last_added_note_tone = 'inactive',
    anki_target_note_fields = nil,
    anki_target_field_fetch_error = nil,
    anki_target_clipboard_preview = '(not refreshed)',
    anki_target_clipboard_tone = 'inactive',
}

local function preview_text_for_osd(value, max_len)
    return compact_preview_text(value, max_len)
end

local MENU_VALUE_COLORS = {
    default = 'ffffff',
    inactive = '8f8f8f',
    active = '9bd6ff',
    accent = 'b97a57',
    profile = 'b9e3b1',
    browser_note = 'a999b8',
    last_added_note = '7fc7b4',
    queue_field_state = 'f0bf62',
    queue_mode_indicator = 'f58f7c',
    queue_mode_replace = 'ff7547',
    queue_source_indicator = '78d6c2',
    encoding = 'ffb347',
    anki_field_preview = 'b46464',
    anki_field_preview_untouched = 'e3cf63',
}

local function anki_field_preview_tone(field_name)
    local active_fields = get_active_field_set()
    if subtitles_export_disabled then
        if field_name == active_fields.sentence_field or field_name == active_fields.secondary_field then
            return 'anki_field_preview_untouched'
        end
    end
    return 'anki_field_preview'
end

local function get_anki_target_field_set_tone(fields, fetch_error)
    if fetch_error or this.is_empty(fields) then
        return 'inactive'
    end

    local active_fields = get_active_field_set()
    local fields_to_check = collect_target_field_names(active_fields, subtitles_export_disabled, config)
    if this.is_empty(fields_to_check) then
        return 'inactive'
    end

    for _, field_name in ipairs(fields_to_check) do
        if note_field_has_content(fields[field_name]) then
            return get_queue_field_state_tone('populated')
        end
    end

    return get_queue_field_state_tone('empty')
end

local function has_captured_primary_subtitles()
    for _, sub in ipairs(subs_observer.recorded_subs()) do
        if sub and not this.is_empty(sub['text']) then
            return true
        end
    end
    return false
end

local function clipboard_preview_display_state()
    local preview = menu and menu.anki_target_clipboard_preview or '(not refreshed)'
    local tone = menu and menu.anki_target_clipboard_tone or 'inactive'

    if not config.use_clipboard_when_empty then
        return 'disabled', 'inactive'
    end

    if subtitles_export_disabled then
        return preview, 'inactive'
    end

    if subs_observer.is_appending() then
        if has_captured_primary_subtitles() then
            return preview, 'inactive'
        end
        if tone ~= 'inactive' then
            return preview, 'active'
        end
    end

    return preview, tone
end

local function queue_status_text(job)
    if not job then
        return 'idle'
    end

    local suffix = job.state == 'finalizing' and ', finalizing' or ', encoding'
    return describe_export_job(job) .. suffix
end

local function append_menu_value(osd, value, tone)
    return osd:styled(tostring(value), MENU_VALUE_COLORS[tone] or MENU_VALUE_COLORS.default)
end

local function set_menu_tone(osd, tone)
    return osd:color(MENU_VALUE_COLORS[tone] or MENU_VALUE_COLORS.default)
end

local function append_toned_text(osd, text, tone)
    set_menu_tone(osd, tone)
    osd:text(tostring(text))
    return osd
end

local function append_queue_job_status(osd, job, base_tone, include_state_suffix)
    if not job then
        append_menu_value(osd, 'idle', 'inactive')
        return
    end

    append_toned_text(osd, escape_for_osd(describe_export_job(job)), base_tone)

    if job.active_field_set_index and job.kind ~= 'test_encode' then
        local field_state_tone = get_queue_field_state_tone(job.field_population_state)
        append_toned_text(osd, ' (', base_tone)
        append_toned_text(osd, 'set ', base_tone)
        append_toned_text(osd, string.format('#%s', tostring(job.active_field_set_index)), field_state_tone)
        if job.field_population_state then
            append_toned_text(osd, ' (', base_tone)
            append_toned_text(osd, tostring(get_queue_field_state_label(job.field_population_state)), field_state_tone)
            append_toned_text(osd, ')', base_tone)
        end
        if job.update_mode then
            append_toned_text(osd, ', mode: ', base_tone)
            append_toned_text(osd, tostring(job.update_mode), get_queue_mode_tone(job.update_mode))
        end
        append_toned_text(osd, ')', base_tone)
    end

    local text_source_label = get_text_source_label(job.text_source_kind)
    if text_source_label then
        append_toned_text(osd, ' ', base_tone)
        append_toned_text(osd, text_source_label, get_queue_source_tone(job.text_source_kind))
    end

    if include_state_suffix then
        append_toned_text(osd, job.state == 'finalizing' and ', finalizing' or ', encoding', base_tone)
    end

    set_menu_tone(osd, 'default')
end

local function append_queue_status_item(osd, label, job, base_tone, include_state_suffix)
    osd:item(label)
    append_queue_job_status(osd, job, base_tone, include_state_suffix)
    return osd:newline()
end

local function get_queue_details_text(job)
    if not job then
        return nil
    end

    local format_string = job.config and job.config.queue_details_format or config.queue_details_format
    if this.is_empty(format_string) then
        return nil
    end

    local runtime_sub = runtime_sub_from_snapshot(job.sub)
    local detail_text = substitute_fmt(
        format_string,
        runtime_sub,
        job.captured,
        job.config,
        {
            profile_name = job.profile_name,
            approximate_clip_length_seconds = snapshot_sub_duration_seconds(job.sub),
        }
    )
    detail_text = this.remove_leading_trailing_spaces(sanitize_osd_inline_text(detail_text))
    if detail_text == '' then
        return nil
    end
    return detail_text
end

local function append_queue_details_item(osd, job)
    if not job then
        return osd
    end

    local detail_text = get_queue_details_text(job)
    if this.is_empty(detail_text) then
        return osd
    end

    osd:item('Details: ')
    append_menu_value(osd, detail_text, 'default')
    osd:newline()
    return osd
end

local function append_menu_item(osd, label, value, tone)
    osd:item(label)
    append_menu_value(osd, value, tone)
    return osd:newline()
end

local function append_timing_value(osd, seconds)
    local has_value = type(seconds) == 'number' and seconds >= 0
    return append_menu_value(osd, has_value and this.human_readable_time(seconds) or 'unset', has_value and 'default' or 'inactive')
end

local function format_subtitle_stream_state(include_internal, include_external)
    if not include_internal then
        return 'no'
    end
    if include_external then
        return 'int+ext'
    end
    return 'int'
end

function menu:refresh_anki_target_info()
    self.anki_target_browser_note = "(doesn't exist)"
    self.anki_target_browser_note_tone = 'inactive'
    self.anki_last_added_note = "(doesn't exist)"
    self.anki_last_added_note_tone = 'inactive'
    self.anki_target_note_fields = nil
    self.anki_target_field_fetch_error = nil

    if config.use_clipboard_when_empty and not platform.get_clipboard then
        self.anki_target_clipboard_preview = '(unavailable)'
        self.anki_target_clipboard_tone = 'inactive'
    elseif config.use_clipboard_when_empty then
        local clip = platform.get_clipboard()
        local preview = compact_preview_text(clip, get_preview_char_limit())
        if preview == '' then
            self.anki_target_clipboard_preview = '(empty)'
            self.anki_target_clipboard_tone = 'inactive'
        else
            self.anki_target_clipboard_preview = preview
            self.anki_target_clipboard_tone = 'default'
        end
    end

    local selected_note_ids = ankiconnect.get_selected_note_ids()
    if not this.is_empty(selected_note_ids) then
        local preview_state = get_note_preview_state(selected_note_ids[1])
        local selected_note_name = preview_state.label
        if preview_state.tone ~= 'inactive' and #selected_note_ids > 1 then
            selected_note_name = string.format("%s (+%d more)", selected_note_name, #selected_note_ids - 1)
        end

        self.anki_target_browser_note = selected_note_name
        self.anki_target_browser_note_tone = preview_state.tone == 'inactive' and 'inactive' or 'browser_note'
        self.anki_target_note_fields = preview_state.fields
        self.anki_target_field_fetch_error = preview_state.error
    end

    local last_note_ids = ankiconnect.get_last_note_ids(1)
    if not this.is_empty(last_note_ids) then
        local last_note_state = get_note_preview_state(last_note_ids[1])
        self.anki_last_added_note = last_note_state.label
        self.anki_last_added_note_tone = last_note_state.tone == 'inactive' and 'inactive' or 'last_added_note'
    end
end

function menu:toggle_anki_target_info()
    local next_state = not self.show_anki_target_info
    self.show_anki_target_info = next_state
    if next_state then
        self:refresh_anki_target_info()
    end
end

function menu:print_anki_field_preview(osd, field_name)
    local fields = self.anki_target_note_fields
    local value = fields and fields[field_name] or nil
    local preview = preview_text_for_osd(value, get_preview_char_limit())
    local tone = anki_field_preview_tone(field_name)

    osd:item(tostring(field_name) .. ': ')
    if preview == "" then
        if self.anki_target_field_fetch_error then
            append_menu_value(osd, escape_for_osd(self.anki_target_field_fetch_error), 'inactive')
        else
            osd:selected('(empty)')
        end
    else
        append_menu_value(osd, escape_for_osd(preview), tone)
    end
    osd:newline()
end

menu.keybindings = {
    { config_key = 'menu_key_set_start_to_sub', key = 'S', fn = menu:with_update { subs_observer.set_manual_timing_to_sub, 'start' } },
    { config_key = 'menu_key_set_end_to_sub', key = 'F', fn = menu:with_update { subs_observer.set_manual_timing_to_sub, 'end' } },
    { config_key = 'menu_key_set_start', key = 's', fn = menu:with_update { subs_observer.set_manual_timing, 'start' } },
    { config_key = 'menu_key_set_end', key = 'f', fn = menu:with_update { subs_observer.set_manual_timing, 'end' } },
    { config_key = 'menu_key_set_start_from_clipboard', key = 'alt+s', fn = menu:with_update { subs_observer.set_manual_timing_from_clipboard, 'start' } },
    { config_key = 'menu_key_set_end_from_clipboard', key = 'alt+d', fn = menu:with_update { subs_observer.set_manual_timing_from_clipboard, 'end' } },
    { config_key = 'menu_key_capture_current', key = 'c', fn = menu:with_update { subs_observer.set_to_current_sub } },
    { config_key = 'menu_key_clear_capture_resume', key = 'C', fn = menu:with_update { function()
        subs_observer.clear_captured_subtitles(true)
    end } },
    { config_key = 'menu_key_toggle_capture', key = 'v', fn = menu:with_update { subs_observer.toggle_subtitle_capture } },
    { config_key = 'menu_key_reset_all', key = 'V', fn = menu:with_update { function()
        subs_observer.clear()
        subs_observer.clear_all_dialogs()
        this.notify("All timings and dialogs reset.", "info", 2)
    end } },
    { config_key = 'menu_key_clear_capture_stop', key = 'Ctrl+alt+c', fn = menu:with_update { function()
        subs_observer.clear_captured_subtitles(false)
    end } },
    { config_key = 'menu_key_seek_previous', key = 'q', fn = _ { play_control.sub_seek, 'backward' } },
    { config_key = 'menu_key_seek_next', key = 'e', fn = _ { play_control.sub_seek, 'forward' } },
    { config_key = 'menu_key_seek_previous_pause', key = 'alt+q', fn = _ { play_control.sub_seek, 'backward', true } },
    { config_key = 'menu_key_seek_next_pause', key = 'alt+e', fn = _ { play_control.sub_seek, 'forward', true } },
    { config_key = 'menu_key_gui_export', key = 'ctrl+G', fn = menu:with_update { export_to_anki, true } },
    { config_key = 'menu_key_export_note', key = 'ctrl+n', fn = menu:with_update { export_to_anki, false } },
    { config_key = 'menu_key_update_selected', key = 'b', fn = menu:with_update { update_selected_note, false } },
    { config_key = 'menu_key_overwrite_selected', key = 'B', fn = menu:with_update { update_selected_note, true } },
    { config_key = 'menu_key_update_last', key = 'ctrl+m', fn = menu:with_update { update_last_note, false } },
    { config_key = 'menu_key_overwrite_last', key = 'ctrl+M', fn = menu:with_update { update_last_note, true } },
    { config_key = 'menu_key_remove_current_subtitle', key = 'g', fn = menu:with_update { subs_observer.remove_current_subtitle_from_recorded } },
    -- Test encode: one-off clip encode without Anki
    { config_key = 'menu_key_test_encode', key = 'h', fn = menu:with_update { export_test_encode } },
    -- Shift+X: repeat the last export, forcing overwrite for note updates
    { config_key = 'menu_key_repeat_export_overwrite', key = 'X', fn = menu:with_update { function() repeat_last_export(true) end } },
    -- Ctrl+Shift+X: repeat the last export while respecting the original overwrite mode
    { config_key = 'menu_key_repeat_export_respect', key = 'ctrl+X', fn = menu:with_update { function() repeat_last_export(false) end } },
    { config_key = 'menu_key_refresh_anki_preview', key = 'r', fn = menu:with_update { refresh_anki_preview } },
    { config_key = 'menu_key_increment_cards', key = 'U', fn = menu:with_update { function()
        quick_creation_opts:increment_cards()
    end } },
    { config_key = 'menu_key_decrement_cards', key = 'u', fn = menu:with_update { function()
        quick_creation_opts:decrement_cards()
    end } },
    { config_key = 'menu_key_toggle_autoclip', key = 'z', fn = menu:with_update { subs_observer.toggle_autocopy } },
    { config_key = 'menu_key_cycle_autoclip_method', key = 'Z', fn = menu:with_update { subs_observer.next_autoclip_method } },
    { config_key = 'menu_key_cycle_hints', key = 'i', fn = menu:with_update { menu.hints_state.bump } },
    { config_key = 'menu_key_toggle_target_preview', key = 'R', fn = menu:with_update { function() menu:toggle_anki_target_info() end } },
    { config_key = 'menu_key_toggle_queue_details', key = 't', fn = menu:with_update { function() menu.show_queue_details = not menu.show_queue_details end } },
    { config_key = 'menu_key_toggle_encode_command', key = 'T', fn = menu:with_update { function() menu.show_encode_command = not menu.show_encode_command end } },
    { config_key = 'menu_key_toggle_error_tail', key = 'ctrl+T', fn = menu:with_update { function() menu.show_error_tail = not menu.show_error_tail end } },
    { config_key = 'menu_key_load_last_timings', key = 'x', fn = menu:with_update { subs_observer.load_last_timings } },
    { config_key = 'menu_key_toggle_subtitle_export', key = 'y', fn = menu:with_update { function()
        subtitles_export_disabled = not subtitles_export_disabled
        this.notify(subtitles_export_disabled and "Subtitles export disabled" or "Subtitles export enabled", "info", 2)
    end } },
    { config_key = 'menu_key_next_profile', key = 'WHEEL_UP', fn = menu:with_update { load_next_profile } },
    { config_key = 'menu_key_previous_profile', key = 'WHEEL_DOWN', fn = menu:with_update { load_previous_profile } },
    { config_key = 'menu_key_increase_menu_font', key = 'shift+ctrl+WHEEL_UP', fn = menu:with_update { function() adjust_menu_font_size(1) end } },
    { config_key = 'menu_key_decrease_menu_font', key = 'shift+ctrl+WHEEL_DOWN', fn = menu:with_update { function() adjust_menu_font_size(-1) end } },
    { config_key = 'menu_key_cycle_field_set', key = 'alt+f', fn = menu:with_update { cycle_field_set } },
    { config_key = 'menu_key_close', key = 'ESC', fn = function()
        menu:close()
    end },
}

local function normalize_key_binding(key)
    local parts = {}
    for part in string.gmatch(key, "[^+]+") do
        local trimmed_part = part:gsub("^%s*(.-)%s*$", "%1")
        table.insert(parts, trimmed_part)
    end
    if #parts < 2 then
        return key
    end

    local key_name = table.remove(parts)
    for index, modifier in ipairs(parts) do
        parts[index] = string.lower(modifier)
    end
    table.sort(parts)
    table.insert(parts, key_name)
    return table.concat(parts, "+")
end

local function configure_keybindings(bindings)
    local assigned_keys = {
        ["advanced-menu"] = {},
        global = {},
    }
    local action_names = {
        menu_key_seek_previous = "mpv-anki-clips-sub-seek-backward",
        menu_key_seek_next = "mpv-anki-clips-sub-seek-forward",
    }
    local registered_actions = {}
    for _, binding in ipairs(bindings) do
        local key = config[binding.config_key]
        if type(key) ~= "string" then
            error("Shortcut setting must be a string: " .. binding.config_key)
        end

        binding.scope_config_key = binding.scope_config_key or ("binding_scope_" .. binding.config_key)
        local scope = config[binding.scope_config_key]
        if scope ~= "advanced-menu" and scope ~= "global" then
            error("Invalid binding scope for " .. binding.config_key .. ": " .. tostring(scope))
        end
        binding.scope = scope
        binding.action_group = binding.action_group
            or (binding.config_key == "menu_key_open" or binding.config_key:match("^global_key_"))
                and "global"
            or "advanced-menu"
        binding.action_name = binding.action_name
            or action_names[binding.config_key]
            or "mpv-anki-clips-" .. binding.config_key:gsub("^[^_]+_key_", ""):gsub("_", "-")
        binding.display_name = binding.display_name
            or binding.action_name:gsub("^mpv%-anki%-clips%-", ""):gsub("%-", " ")
        binding.key = key
        local previous_action = registered_actions[binding.action_name]
        if previous_action then
            error(string.format(
                "Duplicate action binding name '%s' for %s and %s",
                binding.action_name,
                previous_action,
                binding.config_key
            ))
        end
        registered_actions[binding.action_name] = binding.config_key
        if key ~= "" then
            local normalized_key = normalize_key_binding(key)
            local previous_setting = assigned_keys[scope][normalized_key]
            if previous_setting then
                mp.msg.warn(string.format(
                    "%s shortcut '%s' is configured for both %s and %s; disabling %s",
                    scope == "global" and "Global" or "Advanced-menu",
                    key,
                    previous_setting,
                    binding.config_key,
                    binding.config_key
                ))
                binding.key = ""
            else
                assigned_keys[scope][normalized_key] = binding.config_key
            end
        end
    end
end

function menu:print_header(osd)
    osd:submenu('MPV Anki Clips options'):newline()
    local start_time = subs_observer.get_timing('start')
    local end_time = subs_observer.get_timing('end')
    osd:item('Timings: ')
    append_timing_value(osd, start_time)
    osd:item(' to ')
    append_timing_value(osd, end_time)
    osd:newline()
    if is_encoding then
        osd:item('Status: ')
        append_menu_value(osd, current_encode_status_label(), 'encoding')
        osd:newline()
    end
    if current_export_job or #export_queue > 0 then
        osd:submenu('Export queue'):newline()
        local waiting_for_global_queue = current_export_job and current_export_job.state == 'global_queue_waiting'
        append_queue_status_item(osd, waiting_for_global_queue and 'Global queue: ' or 'Running: ', current_export_job, current_export_job and 'encoding' or 'inactive', false)
        if waiting_for_global_queue then
            append_menu_item(osd, 'Global position: ', tostring(current_export_job.global_queue_position or '?'), 'accent')
        end
        if self.show_queue_details then
            append_queue_details_item(osd, current_export_job)
        end
        append_menu_item(osd, 'Pending: ', tostring(#export_queue), #export_queue > 0 and 'accent' or 'inactive')
        if export_queue[1] then
            append_queue_status_item(osd, 'Next: ', export_queue[1], 'default', false)
            if self.show_queue_details then
                append_queue_details_item(osd, export_queue[1])
            end
        end
    end
    if queue_client.is_enabled() then
        append_menu_item(osd, 'Queue sync: ', tostring(config.queue_server_host) .. ':' .. tostring(config.queue_server_port), 'active')
    end
    local clipboard_status = subs_observer.autocopy_status_str()
    append_menu_item(osd, 'Clipboard: ', clipboard_status, clipboard_status:match('^enabled') and 'accent' or 'inactive')
    append_menu_item(osd, 'Subtitle capture: ', subs_observer.subtitle_capture_disabled() and 'disabled' or 'enabled', subs_observer.subtitle_capture_disabled() and 'inactive' or 'active')
    append_menu_item(osd, 'Profile: ', profiles.active, 'profile')
    append_menu_item(osd, 'Deck: ', config.deck_name, 'default')
    append_menu_item(osd, '# cards: ', quick_creation_opts:get_cards(), 'default')
    local video_filter_enabled = config.video_filter ~= 'disabled'
    append_menu_item(osd, 'Video filter: ', video_filter_enabled and 'enabled' or 'disabled', video_filter_enabled and 'active' or 'inactive')
    append_menu_item(osd, 'Video height: ', video_filter_enabled and tostring(config.video_height or 'unk') or 'ignored', video_filter_enabled and 'active' or 'inactive')
    local fps_display = (config.video_fps and config.video_fps > 0) and tostring(config.video_fps) or 'default'
    local fps_tone = (not video_filter_enabled) and 'inactive' or ((config.video_fps and config.video_fps > 0) and 'active' or 'default')
    append_menu_item(osd, 'Video FPS: ', video_filter_enabled and fps_display or 'ignored', fps_tone)
    osd:submenu('Profile'):newline()
    local remote_ffmpeg_effective = (config.remote_ffmpeg_enabled == 'yes')
    local encode_mode_display = remote_ffmpeg_effective and 'ssh' or 'local'
    append_menu_item(osd, 'Encode mode: ', encode_mode_display, remote_ffmpeg_effective and 'accent' or 'default')
    append_menu_item(osd, 'Container: ', config.video_container or 'unk', 'default')
    local two_pass_effective = ((config.video_two_pass == true or config.video_two_pass == 'yes') and not (config.video_use_crf == true or config.video_use_crf == 'yes'))
    append_menu_item(osd, 'Two-pass video: ', two_pass_effective and 'yes' or 'no', two_pass_effective and 'active' or 'inactive')
    local vqm = config.video_quality_management or ((config.allow_combined_crf_bitrate == true or config.allow_combined_crf_bitrate == 'yes') and 'allow_combined_crf_bitrate' or 'enabled')
    local crf_effective = (config.video_use_crf == true or config.video_use_crf == 'yes') and not two_pass_effective and vqm ~= 'disabled'
    local combined_video = (vqm == 'allow_combined_crf_bitrate') and crf_effective
    local video_stream_enabled = is_enabled_like(config.enable_video)
    local video_mode
    if vqm == 'disabled' then
        video_mode = 'no b:v/crf'
    elseif combined_video then
        video_mode = (config.video_bitrate or 'unk') .. ' + CRF ' .. tostring(config.video_crf)
    else
        video_mode = crf_effective and ('CRF ' .. tostring(config.video_crf)) or (config.video_bitrate or 'unk')
    end
    local video_codec_tone = (not video_stream_enabled) and 'inactive' or ((vqm ~= 'disabled') and 'active' or 'default')
    append_menu_item(osd, 'Video-codec: ', (config.video_codec or 'unk') .. '/' .. video_mode, video_codec_tone)
    local aqm = config.audio_quality_management or ((config.allow_combined_vbr_bitrate == true or config.allow_combined_vbr_bitrate == 'yes') and 'allow_combined_vbr_bitrate' or 'enabled')
    local vbr_effective = (config.audio_use_vbr == true or config.audio_use_vbr == 'yes') and aqm ~= 'disabled'
    local combined_audio = (aqm == 'allow_combined_vbr_bitrate') and vbr_effective
    local audio_stream_enabled = is_enabled_like(config.enable_audio)
    local audio_mode
    if aqm == 'disabled' then
        audio_mode = 'no vbr/b:a'
    elseif combined_audio then
        audio_mode = (config.audio_bitrate or 'unk') .. ' + VBR'
    else
        audio_mode = vbr_effective and 'VBR' or (config.audio_bitrate or 'unk')
    end
    local audio_codec_tone = (not audio_stream_enabled) and 'inactive' or ((aqm ~= 'disabled') and 'active' or 'default')
    append_menu_item(osd, 'Audio-codec: ', (config.audio_codec or 'unk') .. '/' .. audio_mode, audio_codec_tone)
    local internal_subtitles_enabled = is_enabled_like(config.include_subtitles)
    local external_subtitles_enabled = is_enabled_like(config.include_external_subtitles)
    local subtitle_stream_state = format_subtitle_stream_state(internal_subtitles_enabled, external_subtitles_enabled)
    append_menu_item(osd, 'Streams (v/a/sub): ', (video_stream_enabled and 'yes' or 'no') .. '/' .. (audio_stream_enabled and 'yes' or 'no') .. '/' .. subtitle_stream_state, 'default')
    local audio_fade_in = tonumber(config.audio_fade_in) or 0
    local audio_fade_out = tonumber(config.audio_fade_out) or 0
    local audio_fade_tone = (not audio_stream_enabled) and 'inactive' or ((audio_fade_in ~= 0 or audio_fade_out ~= 0) and 'active' or 'inactive')
    append_menu_item(osd, 'Audio fade in/out: ', string.format('%s/%s', config.audio_fade_in or 'unk', config.audio_fade_out or 'unk'), audio_fade_tone)
    append_menu_item(osd, 'Video preset: ', config.video_preset or 'unk', video_stream_enabled and 'default' or 'inactive')
    do
        local raw_args = (config.video_custom_args and config.video_custom_args ~= '') and tostring(config.video_custom_args) or 'none'
        local shown_args = raw_args
        if should_cap_video_custom_args_preview() then
            shown_args = preview_text_for_osd(raw_args, get_preview_char_limit())
        end
        append_menu_item(osd, 'Video custom args: ', shown_args, raw_args ~= 'none' and 'active' or 'inactive')
    end
    local video_padding_value = tonumber(config.video_padding) or 0
    local video_padding_tone = 'inactive'
    if video_stream_enabled and video_padding_value ~= 0 and subs_observer.is_padding_expected and subs_observer.is_padding_expected() then
        video_padding_tone = 'active'
    end
    append_menu_item(osd, 'Video padding: ', tostring(config.video_padding or 'unk'), video_padding_tone)
    local loudnorm_two_pass_active = audio_stream_enabled and (config.loudnorm_enabled == 'yes') and (config.loudnorm_two_pass == 'yes')
    append_menu_item(osd, 'Two-pass loudnorm: ', loudnorm_two_pass_active and 'yes' or 'no', loudnorm_two_pass_active and 'active' or 'inactive')
    local loudnorm_enabled = audio_stream_enabled and (config.loudnorm_enabled == 'yes')
    append_menu_item(osd, 'Loudnorm I/LRA/TP: ', string.format('%s/%s/%s', config.loudnorm_I or 'unk', config.loudnorm_LRA or 'unk', config.loudnorm_TP or 'unk'), loudnorm_enabled and 'active' or 'inactive')
    local arrow_display = config.remove_arrows == "yes" and "remove" or
                         config.remove_arrows == "no" and "keep" or
                         config.remove_arrows == "join" and "join" or
                         config.remove_arrows == "join_arrow" and "join with arrow" or "unknown"
    append_menu_item(osd, 'Subtitle arrows: ', arrow_display, arrow_display == 'keep' and 'inactive' or 'default')
    local copy_text_mode_name = subs_observer.copy_text_mode and subs_observer.copy_text_mode() or 'single_line'
    local copy_text_mode_display = copy_text_mode_name == 'subtitle_content'
        and 'subtitle content'
        or copy_text_mode_name == 'custom_pattern'
        and 'custom pattern'
        or 'single line'
    append_menu_item(osd, 'Copy text mode: ', copy_text_mode_display, copy_text_mode_name ~= 'single_line' and 'active' or 'default')
    
    -- Always show the encode command section title when enabled
    if self.show_encode_command then
        osd:submenu('Last encode command'):newline()
        -- Display command if available, otherwise show status
        local last_cmd = encoder.get_last_encode_command()
        if last_cmd then
            -- Use a slightly smaller font size for the command
            osd:append('{\\fs' .. math.max(config.menu_font_size - 14, 8) .. '}')
            osd:text(last_cmd)
            osd:append('{\\fs' .. math.max(config.menu_font_size - 10, 12) .. '}')
            osd:newline()
            -- Also display last output file size and duration if known
            local sz = encoder.get_last_encode_filesize and encoder.get_last_encode_filesize() or nil
            local dur = encoder.get_last_encode_duration and encoder.get_last_encode_duration() or nil
            if sz or dur then
                local mib = (sz and sz > 0) and string.format('%.2f MiB', (sz / (1024*1024))) or 'unknown'
                local function fmt_duration(seconds)
                    if not seconds or seconds <= 0 then return 'unknown' end
                    local m = math.floor(seconds / 60)
                    local s = math.floor(seconds % 60)
                    local ms = math.floor((seconds * 1000) % 1000)
                    return string.format('%d:%02d.%03d', m, s, ms)
                end
                osd:append('{\\fs' .. math.max(config.menu_font_size - 12, 10) .. '}')
                osd:text('Output file size: ' .. mib):newline()
                osd:text('Output clip length: ' .. fmt_duration(dur)):newline()
                osd:append('{\\fs' .. math.max(config.menu_font_size - 10, 12) .. '}')
            end
        else
            osd:text('(No encode command yet)'):newline()
        end
    end

    if self.show_error_tail then
        osd:submenu('Last error (tail)'):newline()
        local last_tail = encoder.get_last_error_tail and encoder.get_last_error_tail() or nil
        if last_tail and last_tail ~= '' then
            osd:append('{\fs' .. math.max(config.menu_font_size - 14, 8) .. '}')
            osd:text(last_tail)
            osd:append('{\fs' .. math.max(config.menu_font_size - 10, 12) .. '}')
            osd:newline()
        else
            osd:text('(No recent error)'):newline()
        end
    end

    if subtitles_export_disabled then
        osd:submenu('Subtitles export disabled'):newline()
        osd:text('Subtitle fields will not be updated in Anki notes.'):newline()
    end

    if self.show_anki_target_info then
        local active_fields = get_active_field_set()
        local clipboard_preview, clipboard_tone = clipboard_preview_display_state()

        osd:submenu('Anki target note'):newline()
        osd:item('Browser note: ')
        append_menu_value(osd, escape_for_osd(self.anki_target_browser_note or '(unknown)'), self.anki_target_browser_note_tone or 'browser_note')
        osd:newline()
        osd:item('Last added: ')
        append_menu_value(osd, escape_for_osd(self.anki_last_added_note or "(doesn't exist)"), self.anki_last_added_note_tone or 'inactive')
        osd:newline()
        osd:item('Field set: ')
        append_menu_value(osd, string.format('#%d', active_field_set), get_anki_target_field_set_tone(self.anki_target_note_fields, self.anki_target_field_fetch_error))
        osd:newline()
        osd:item('Clipboard fallback: ')
        append_menu_value(osd, escape_for_osd(clipboard_preview), clipboard_tone)
        osd:newline()

        self:print_anki_field_preview(osd, active_fields.sentence_field)
        self:print_anki_field_preview(osd, active_fields.secondary_field)
        self:print_anki_field_preview(osd, active_fields.video_field)
        self:print_anki_field_preview(osd, active_fields.miscinfo_field)
    end
end

function menu:print_bindings(osd)
    local main_size = math.max(config.menu_font_size - 10, 4)
    local bindings_size = math.max(main_size - 3, 1)
    osd:size(bindings_size)

    local keys_by_context = {
        ["advanced-menu"] = {},
        global = {},
    }
    for _, binding in ipairs(self.keybindings) do
        if binding.key ~= "" then
            keys_by_context[binding.scope][binding.config_key] = binding.key
        end
    end

    local function key_label(settings, context)
        local keys = {}
        for _, setting in ipairs(settings) do
            local key = keys_by_context[context or "advanced-menu"][setting]
            if key and key ~= "" then
                table.insert(keys, key)
            end
        end
        return table.concat(keys, '/')
    end

    local function hint(settings, description)
        local keys = key_label(settings)
        if keys ~= "" then
            osd:tab():item(keys .. ': '):text(description):newline()
        end
    end

    local function hint_instruction(setting, label, context)
        local key = key_label({ setting }, context)
        if key ~= "" then
            osd:italics("Press "):item(key):italics(label):newline()
        end
    end

    if self.hints_state.get() == 'global' then
        osd:submenu('Global bindings'):newline()
        for _, binding in ipairs(self.keybindings) do
            if binding.scope == "global"
                and binding.key ~= ""
                and binding.config_key ~= "menu_key_cycle_hints"
            then
                osd:tab():item(binding.key .. ': '):text(binding.display_name):newline()
            end
        end
        local cycle_hints_key = key_label({ "menu_key_cycle_hints" }, "global")
        if cycle_hints_key ~= "" then
            osd:tab():item(cycle_hints_key .. ': '):text('Cycle menu hints'):newline()
        end
    elseif self.hints_state.get() == 'menu' then
        osd:submenu('Menu bindings'):newline()
        hint({ 'menu_key_capture_current' }, 'Capture from current sub')
        hint({ 'menu_key_set_start', 'menu_key_set_start_to_sub' }, 'Set start / to current sub')
        hint({ 'menu_key_set_end', 'menu_key_set_end_to_sub' }, 'Set end / to current sub')
        hint({ 'menu_key_set_start_from_clipboard', 'menu_key_set_end_from_clipboard' }, 'Set start/end from clipboard')
        hint({ 'menu_key_seek_previous', 'menu_key_seek_next' }, 'Prev/next subtitle')
        hint({ 'menu_key_seek_previous_pause', 'menu_key_seek_next_pause' }, 'Prev/next subtitle+pause')
        hint({ 'menu_key_decrement_cards', 'menu_key_increment_cards' }, 'Decrement/increment cards')
        hint({
            'menu_key_toggle_capture',
            'menu_key_clear_capture_resume',
            'menu_key_clear_capture_stop',
            'menu_key_reset_all',
        }, 'Toggle capture disable / clear subs+resume / clear subs+stop / reset all')
        hint({ 'menu_key_export_note' }, 'Export note')
        hint({ 'menu_key_gui_export' }, 'GUI export')
        hint({ 'menu_key_update_selected', 'menu_key_overwrite_selected' }, 'Update selected note / overwrite')
        hint({ 'menu_key_update_last', 'menu_key_overwrite_last' }, 'Update last added note / overwrite')
        hint({ 'menu_key_toggle_autoclip', 'menu_key_cycle_autoclip_method' }, 'Toggle/switch auto-clipboard')
        hint({ 'menu_key_toggle_target_preview', 'menu_key_refresh_anki_preview' }, 'Toggle target-note preview / refresh + open Anki preview')
        hint({ 'menu_key_toggle_queue_details', 'menu_key_toggle_encode_command' }, 'Toggle queue details / encode command')
        hint({ 'menu_key_toggle_error_tail' }, 'Toggle error tail')
        hint({ 'menu_key_remove_current_subtitle', 'menu_key_test_encode' }, 'Remove current subtitle / test encode clip')
        hint({ 'menu_key_repeat_export_overwrite', 'menu_key_repeat_export_respect' }, 'Repeat last export (overwrite/respect)')
        hint({ 'menu_key_load_last_timings' }, 'Load last timings')
        hint({ 'menu_key_toggle_subtitle_export' }, 'Toggle subtitles export')
        for _, binding in ipairs(self.keybindings) do
            if binding.action_group == "global"
                and binding.scope == "advanced-menu"
                and binding.key ~= ""
            then
                hint({ binding.config_key }, binding.display_name)
            end
        end
        hint({ 'menu_key_next_profile', 'menu_key_previous_profile' }, 'Next/prev profile')
        hint({ 'menu_key_increase_menu_font', 'menu_key_decrease_menu_font' }, 'Preview UI font size +/- (temporary)')
        hint({ 'menu_key_cycle_field_set' }, 'Cycle field set')
        hint({ 'menu_key_close' }, 'Close')
        hint_instruction('menu_key_cycle_hints', ' for global')
    else
        hint_instruction(
            'menu_key_cycle_hints',
            ' for menu bindings',
            config.binding_scope_menu_key_cycle_hints
        )
    end

    osd:size(main_size)
end

function menu:print_legend(osd)
    osd:new_layer():size(math.max(config.menu_font_size - 10, 4)):font(config.menu_font_name):align(4)
    osd:append('{\\q2}')
    self:print_header(osd)
    self:print_bindings(osd)
    self:warn_formats(osd)
    self:warn_clipboard(osd)
    osd:append('{\\q0}')
end

function menu:warn_formats(osd)
    -- FFmpeg is the only supported encoder backend.
    return
end

function menu:warn_clipboard(osd)
    if subs_observer.autocopy_current_method() == "clipboard" and platform.healthy == false then
        osd:red('warning: '):text(string.format("%s is not installed.", platform.clip_util)):newline()
    end
end

function menu:print_selection(osd)
    if subs_observer.is_appending() and config.show_selected_text then
        local subtitle_font_size = math.max(config.menu_font_size * config.subtitle_preview_font_scale, 4)
        local text_tone = subtitles_export_disabled and MENU_VALUE_COLORS.inactive or MENU_VALUE_COLORS.active
        osd:new_layer():size(subtitle_font_size):font(config.menu_font_name):align(6)
        osd:submenu("Primary text"):newline()
        for _, s in ipairs(subs_observer.recorded_subs()) do
            osd:styled(escape_for_osd(preview_text_for_osd(s['text'], get_captured_primarysub_preview_char_limit())), text_tone):newline()
        end
        if not this.is_empty(get_active_field_set().secondary_field) then
            osd:submenu("Secondary text"):newline()
            for _, s in ipairs(subs_observer.recorded_secondary_subs()) do
                osd:styled(escape_for_osd(preview_text_for_osd(s['text'], get_captured_secondarysub_preview_char_limit())), text_tone):newline()
            end
        end
    end
end

function menu:make_osd()
    local osd = OSD:new()
    self:print_legend(osd)
    self:print_selection(osd)
    return osd
end

------------------------------------------------------------
-- quick_menu line selection

local choose_cards = function(i)
    quick_creation_opts:set_cards(i)
    quick_menu_card:close()
    quick_menu:open()
end

local choose_lines = function(i)
    quick_creation_opts:set_lines(i)
    update_last_note(true)
    quick_menu:close()
end

quick_menu = Menu:new()
quick_menu.keybindings = {}
for i = 1, 9 do
    table.insert(quick_menu.keybindings, { key = tostring(i), action_name = "mpv-anki-clips-quick-line-select-" .. i, fn = function()
        choose_lines(i)
    end })
end
table.insert(quick_menu.keybindings, { key = 'g', action_name = "mpv-anki-clips-quick-line-select-one", fn = function()
    choose_lines(1)
end })
table.insert(quick_menu.keybindings, { key = 'ESC', action_name = "mpv-anki-clips-quick-line-menu-close-escape", fn = function()
    quick_menu:close()
end })
table.insert(quick_menu.keybindings, { key = 'q', action_name = "mpv-anki-clips-quick-line-menu-close-q", fn = function()
    quick_menu:close()
end })

function quick_menu:print_header(osd)
    osd:submenu('quick card creation: line selection'):newline()
    osd:item('# lines: '):text('Enter 1-9'):newline()
end

function quick_menu:print_legend(osd)
    osd:new_layer():size(config.menu_font_size):font(config.menu_font_name):align(4)
    self:print_header(osd)
    menu:warn_formats(osd)
end

function quick_menu:make_osd()
    local osd = OSD:new()
    self:print_legend(osd)
    return osd
end

quick_menu_card = Menu:new()
quick_menu_card.keybindings = {}
for i = 1, 9 do
    table.insert(quick_menu_card.keybindings, { key = tostring(i), action_name = "mpv-anki-clips-quick-card-select-" .. i, fn = function()
        choose_cards(i)
    end })
end
table.insert(quick_menu_card.keybindings, { key = 'ESC', action_name = "mpv-anki-clips-quick-card-menu-close-escape", fn = function()
    quick_menu_card:close()
end })
table.insert(quick_menu_card.keybindings, { key = 'q', action_name = "mpv-anki-clips-quick-card-menu-close-q", fn = function()
    quick_menu_card:close()
end })

function quick_menu_card:print_header(osd)
    osd:submenu('quick card creation: card selection'):newline()
    osd:item('# cards: '):text('Enter 1-9'):newline()
end

function quick_menu_card:print_legend(osd)
    osd:new_layer():size(config.menu_font_size):font(config.menu_font_name):align(4)
    self:print_header(osd)
    menu:warn_formats(osd)
end

function quick_menu_card:make_osd()
    local osd = OSD:new()
    self:print_legend(osd)
    return osd
end

------------------------------------------------------------
-- main

local main = (function()
    local main_executed = false
    return function()
        if main_executed then
            subs_observer.clear_all_dialogs()
            return
        else
            main_executed = true
        end

        cfg_mgr.init(config, profiles, core_config)
        codec_support.configure(config)
    -- Initialize logger with current config debug level
    logger.set_config(config)
        -- Now that logger is configured, log codec compatibility if enabled
        if codec_support and codec_support.log_support then
            codec_support.log_support()
        end
        if not config.field_sets or #config.field_sets == 0 then
            mp.msg.warn("No field sets defined during initialization, resetting to default")
            config.field_sets = {{
                sentence_field = config.sentence_field_1,
                secondary_field = config.secondary_field_1,
                video_field = config.video_field_1,
                miscinfo_field = config.miscinfo_field_1,
            }}
            active_field_set = 1
        elseif active_field_set > #config.field_sets then
            mp.msg.warn("active_field_set (" .. active_field_set .. ") exceeds field_sets count (" .. #config.field_sets .. "), resetting to 1")
            active_field_set = 1
        end
        local active_fields = get_active_field_set()
        config.video_field = active_fields.video_field
        ankiconnect.init(config, platform)
        forvo.init(config, platform)
        encoder.init(config)
        queue_client.init(config)
        secondary_sid.init(config)
        ensure_deck()
        subs_observer.init(menu, config)

        local configurable_global_actions = {
            { config_key = "menu_key_open", action_name = "mpv-anki-clips-menu-open", display_name = "Open advanced menu", fn = function() menu:open() end },
            { config_key = "global_key_copy_primary", action_name = "mpv-anki-clips-copy-sub-to-clipboard", display_name = "Copy primary subtitle", fn = subs_observer.copy_current_primary_to_clipboard, forced = true },
            { config_key = "global_key_copy_secondary", action_name = "mpv-anki-clips-copy-secondary-sub-to-clipboard", display_name = "Copy secondary subtitle", fn = subs_observer.copy_current_secondary_to_clipboard },
            { config_key = "global_key_secondary_visibility", action_name = "mpv-anki-clips-secondary-sid-toggle", display_name = "Toggle secondary subtitle visibility", fn = secondary_sid.change_visibility },
            { config_key = "global_key_secondary_previous", action_name = "mpv-anki-clips-secondary-sid-prev", display_name = "Select previous secondary subtitle track", fn = secondary_sid.select_previous },
            { config_key = "global_key_secondary_next", action_name = "mpv-anki-clips-secondary-sid-next", display_name = "Select next secondary subtitle track", fn = secondary_sid.select_next },
            { config_key = "global_key_quick_line_menu", action_name = "mpv-anki-clips-quick-card-menu-open", display_name = "Open quick line-selection menu", fn = function() quick_menu:open() end },
            { config_key = "global_key_quick_card_menu", action_name = "mpv-anki-clips-quick-card-sel-menu-open", display_name = "Open quick card-count menu", fn = function() quick_menu_card:open() end },
            { config_key = "global_key_sub_rewind", action_name = "mpv-anki-clips-sub-rewind", display_name = "Rewind to current subtitle start", fn = _ { play_control.sub_rewind } },
            { config_key = "global_key_sub_replay", action_name = "mpv-anki-clips-sub-replay", display_name = "Replay current subtitle", fn = _ { play_control.play_till_sub_end } },
            { config_key = "global_key_sub_play_to_next", action_name = "mpv-anki-clips-sub-play-up-to-next", display_name = "Play to next subtitle end", fn = _ { play_control.play_till_next_sub_end } },
            { config_key = "global_key_restart_mpv_current_file", action_name = "mpv-anki-clips-restart-mpv-current-file", display_name = "Restart mpv with current file (debug)", fn = restart_mpv_current_file },
        }

        for _, binding in ipairs(configurable_global_actions) do
            binding.action_group = "global"
            table.insert(menu.keybindings, binding)
        end
        configure_keybindings(menu.keybindings)
        menu:register_keybindings()
        quick_menu:register_keybindings()
        quick_menu_card:register_keybindings()

        for _, binding in ipairs(menu.keybindings) do
            if binding.scope == "global" then
                local configured_key = binding.key ~= "" and binding.key or nil
                if binding.forced and configured_key then
                    mp.add_forced_key_binding(configured_key, binding.action_name, binding.fn)
                else
                    mp.add_key_binding(configured_key, binding.action_name, binding.fn)
                end
            end
        end

        if config.menu_key_open ~= "" and config.binding_scope_menu_key_open == "global" then
            mp.msg.warn("Press '" .. config.menu_key_open .. "' to open the MPV Anki Clips menu.")
        elseif config.menu_key_open ~= "" then
            mp.msg.warn("The menu opener key is scoped to the advanced menu; bind mpv-anki-clips-menu-open in input.conf to open it.")
        else
            mp.msg.warn("The advanced menu has no default key; bind mpv-anki-clips-menu-open in input.conf.")
        end
    end
end)()

mp.register_event("file-loaded", main)