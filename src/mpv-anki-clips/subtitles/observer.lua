--[[
Copyright: Ren Tatsumoto and contributors
License: GNU GPL, version 3 or later; http://www.gnu.org/licenses/gpl.html

Observer waits for subtitles to appear on the screen and adds them to a list.
]]

local h = require('helpers')
local timings = require('utils.timings')
local sub_list = require('subtitles.sub_list')
local Subtitle = require('subtitles.subtitle')
local mp = require('mp')
local platform = require('platform.init')
local switch = require('utils.switch')

local self = {}

local dialogs = sub_list.new()
local secondary_dialogs = sub_list.new()
local all_dialogs = sub_list.new()
local all_secondary_dialogs = sub_list.new()
local user_timings = timings.new()
local last_timings = timings.new()
local is_subtitle_based_timing = false
local user_timing_source = { start = nil, ['end'] = nil }

local append_dialogue = false
local subtitle_capture_enabled = true
local autoclip_enabled = false
local autoclip_method = {}

local function reset_recorded_dialogs()
    dialogs = sub_list.new()
    secondary_dialogs = sub_list.new()
    all_dialogs = sub_list.new()
    all_secondary_dialogs = sub_list.new()
end

local function has_user_timing_source(source_name)
    return user_timing_source.start == source_name or user_timing_source['end'] == source_name
end

local function set_user_timing_source(position, source_name)
    user_timing_source[position] = source_name
end

local function clear_user_timing_sources()
    user_timing_source.start = nil
    user_timing_source['end'] = nil
end

local function sync_subtitle_based_timing()
    if has_user_timing_source('manual') then
        is_subtitle_based_timing = false
        return
    end

    if user_timings.is_set('start') or user_timings.is_set('end') then
        is_subtitle_based_timing = has_user_timing_source('subtitle')
    end
end

------------------------------------------------------------
-- private

local function copy_primary_sub()
    if autoclip_enabled then
        autoclip_method.call()
    end
end

local function append_primary_sub()
    local current_sub = Subtitle:now()
    all_dialogs.insert(current_sub)
    if append_dialogue and subtitle_capture_enabled and dialogs.insert(current_sub) then
        self.menu:update()
    end
end

local function append_secondary_sub()
    local current_secondary = Subtitle:now('secondary')
    all_secondary_dialogs.insert(current_secondary)
    if append_dialogue and subtitle_capture_enabled and secondary_dialogs.insert(current_secondary) then
        self.menu:update()
    end
end

local function start_appending()
    append_dialogue = true
    if subtitle_capture_enabled then
        append_primary_sub()
        append_secondary_sub()
    end
end

local function handle_primary_sub()
    append_primary_sub()
    copy_primary_sub()
end

local function handle_secondary_sub()
    append_secondary_sub()
end

local function on_external_finish(success, result, error)
    if success ~= true or error ~= nil then
        h.notify("Command failed: " .. table.concat(result))
    end
end

local function external_command_args(cur_lines)
    local args = {}
    local tokens = h.parse_shell_like_args(self.config.autoclip_custom_args or "")
    for _, token in ipairs(tokens) do
        local arg = token
        if arg == '%MPV_PRIMARY%' then
            arg = cur_lines.primary
        elseif arg == '%MPV_SECONDARY%' then
            arg = cur_lines.secondary
        end
        table.insert(args, arg)
    end
    return args
end

local function call_external_command(cur_lines)
    if not h.is_empty(self.config.autoclip_custom_args) then
        h.subprocess(external_command_args(cur_lines), on_external_finish)
    end
end

local function copy_text_mode()
    if self.config.copy_text_mode == 'subtitle_content' then
        return 'subtitle_content'
    elseif self.config.copy_text_mode == 'custom_pattern' then
        return 'custom_pattern'
    end
    return 'single_line'
end

local function copy_text_custom_base_mode()
    if self.config.copy_text_custom_base_mode == 'subtitle_content' then
        return 'subtitle_content'
    end
    return 'single_line'
end

local function prepare_copy_text_base(text, mode)
    if mode == 'subtitle_content' then
        return text
    end

    text = h.trim(text, false, self.config.preserve_japanese_parentheses, self.config.remove_arrows)
    text = h.remove_newlines(text)
    return text
end

local function apply_copy_text_custom_pattern(text)
    local pattern = self.config.copy_text_custom_pattern or ''
    if h.is_empty(pattern) then
        return text
    end

    local replacement = self.config.copy_text_custom_replacement or ''
    local ok, filtered = pcall(function()
        if self.config.copy_text_custom_scope == 'per_line' then
            local filtered_lines = {}
            for line in (text .. '\n'):gmatch('(.-)\n') do
                table.insert(filtered_lines, (line:gsub(pattern, replacement)))
            end
            return table.concat(filtered_lines, '\n')
        end
        return (text:gsub(pattern, replacement))
    end)

    if ok then
        return filtered
    end

    mp.msg.warn('Failed to apply copy_text_custom_pattern; using unfiltered text.')
    return text
end

local function prepare_copy_lines(cur_lines)
    return {
        primary = self.clipboard_prepare(cur_lines.primary),
        secondary = self.clipboard_prepare(cur_lines.secondary),
    }
end

local function current_subtitle_lines()
    local primary = dialogs.get_text(self.config.remove_arrows)

    if h.is_empty(primary) then
        primary = mp.get_property("sub-text")
    end

    if h.is_empty(primary) then
        return nil
    end

    local secondary = secondary_dialogs.get_text(self.config.remove_arrows)

    if h.is_empty(secondary) then
        secondary = mp.get_property("secondary-sub-text") or ""
    end

    return { primary = primary, secondary = secondary }
end

local function ensure_goldendict_running()
    --- Ensure that goldendict is running and is disowned by mpv.
    --- Avoid goldendict getting killed when mpv exits.
    if autoclip_enabled and self.autocopy_current_method() == "goldendict" then
        os.execute("setsid -f goldendict")
    end
end

------------------------------------------------------------
-- autoclip methods

autoclip_method = (function()
    local methods = { 'clipboard', 'goldendict', 'custom_command', }
    local current_method = switch.new(methods)

    local function call()
        local cur_lines = current_subtitle_lines()
        if h.is_empty(cur_lines) then
            return
        end

        local prepared_lines = prepare_copy_lines(cur_lines)

        if current_method.get() == 'clipboard' then
            self.copy_to_clipboard("autocopy action", cur_lines.primary)
        elseif current_method.get() == 'goldendict' then
            h.subprocess_detached({ 'goldendict', prepared_lines.primary }, on_external_finish)
        elseif current_method.get() == 'custom_command' then
            call_external_command(prepared_lines)
        end
    end

    return {
        call = call,
        get = current_method.get,
        bump = current_method.bump,
        set = current_method.set,
    }
end)()

local function copy_subtitle(subtitle_id)
    self.copy_to_clipboard("copy-on-demand", mp.get_property(subtitle_id))
end

------------------------------------------------------------
-- public

self.copy_to_clipboard = function(_, text)
    if platform.healthy == false then
        h.notify(platform.clip_util .. " is not installed.", "error", 5)
    end
    if not h.is_empty(text) then
        platform.copy_to_clipboard(self.clipboard_prepare(text))
    end
end

self.clipboard_prepare = function(text)
    local mode = copy_text_mode()

    if mode == 'custom_pattern' then
        local filtered = apply_copy_text_custom_pattern(text)
        return prepare_copy_text_base(filtered, copy_text_custom_base_mode())
    end

    return prepare_copy_text_base(text, mode)
end

self.copy_text_mode = function()
    return copy_text_mode()
end

self.maybe_remove_all_spaces = function(str)
    if self.config.nuke_spaces == true and h.contains_non_latin_letters(str) then
        return h.remove_all_spaces(str)
    else
        return str
    end
end

self.copy_current_primary_to_clipboard = function()
    copy_subtitle("sub-text")
end

self.copy_current_secondary_to_clipboard = function()
    copy_subtitle("secondary-sub-text")
end

self.user_altered = function()
    --- Return true if the user manually set at least start or end.
    return user_timings.is_set('start') or user_timings.is_set('end')
end

self.is_subtitle_based_timing = function()
    return is_subtitle_based_timing
end

self.is_padding_expected = function()
    return is_subtitle_based_timing
end

self.get_timing = function(position)
    if user_timings.is_set(position) then
        return user_timings.get(position)
    elseif not dialogs.is_empty() then
        return dialogs.get_time(position)
    end
    return -1
end

self.collect_from_all_dialogues = function(n_lines)
    local current_sub = Subtitle:now()
    local current_secondary_sub = Subtitle:now('secondary')
    all_dialogs.insert(current_sub)
    all_secondary_dialogs.insert(current_secondary_sub)
    if current_sub == nil then
        return Subtitle:new() -- return a default empty new Subtitle to let consumer handle
    end
    local text, end_sub = all_dialogs.get_n_text(current_sub, n_lines, self.config.remove_arrows)
    local secondary_text, _
    if current_secondary_sub == nil then
        secondary_text = ''
    else
        secondary_text, _ = all_secondary_dialogs.get_n_text(current_secondary_sub, n_lines, self.config.remove_arrows)
    end
    local sub = Subtitle:new {
        ['text'] = text,
        ['secondary'] = secondary_text,
        ['start'] = current_sub['start'],
        ['end'] = end_sub['end'],
    }
    if is_subtitle_based_timing then
        local original_start = sub['start']
        local original_end = sub['end']
        sub['start'] = sub['start'] - self.config.video_padding
        sub['end'] = sub['end'] + self.config.video_padding
        h.notify(string.format("Applied padding (%.3f) to all dialogues: old start=%.2f → new start=%.2f, old end=%.2f → new end=%.2f", self.config.video_padding, original_start, sub['start'], original_end, sub['end']), "info", 2)
    end
    mp.msg.debug("Collected from all dialogues: " .. text)
    return sub
end

self.collect_from_current = function()
    --- Return all recorded subtitle lines as one subtitle object.
    --- The caller has to call subs_observer.clear() afterwards.
    if dialogs.is_empty() then
        dialogs.insert(Subtitle:now())
    end
    if secondary_dialogs.is_empty() then
        secondary_dialogs.insert(Subtitle:now('secondary'))
    end
    local sub = Subtitle:new {
        ['text'] = dialogs.get_text(self.config.remove_arrows),
        ['secondary'] = secondary_dialogs.get_text(self.config.remove_arrows),
        ['start'] = self.get_timing('start'),
        ['end'] = self.get_timing('end'),
    }
    if is_subtitle_based_timing and sub:is_valid() then
        local original_start = sub['start']
        local original_end = sub['end']
        sub['start'] = sub['start'] - self.config.video_padding
        sub['end'] = sub['end'] + self.config.video_padding
        mp.msg.info(string.format("Applied padding (%.3f) to current: old start=%.2f → new start=%.2f, old end=%.2f → new end=%.2f", self.config.video_padding, original_start, sub['start'], original_end, sub['end']))
    end
    mp.msg.debug("Collected from current: " .. sub['text'])
    return sub
end

self.set_manual_timing = function(position)
    user_timings.set(position, mp.get_property_number('time-pos') - mp.get_property("audio-delay"))
    set_user_timing_source(position, 'manual')
    sync_subtitle_based_timing()
    h.notify(h.capitalize_first_letter(position) .. " time has been set (manual, no padding).")
    start_appending()
end

self.set_manual_timing_to_sub = function(position)
    local sub = Subtitle:now()
    if sub then
        user_timings.set(position, sub[position] - mp.get_property("audio-delay"))
        set_user_timing_source(position, 'subtitle')
        sync_subtitle_based_timing()
        h.notify(h.capitalize_first_letter(position) .. " time has been set (subtitle-based).")
        start_appending()
    else
        h.notify("There's no visible subtitle.", "info", 2)
    end
end

self.set_manual_timing_from_clipboard = function(position)
    local clip = platform.get_clipboard()
    if not clip or clip == '' then
        h.notify("Clipboard is empty.", "warn", 2)
        return
    end
    -- Check for combined start_end format
    local start_str, end_str = clip:match("^(.+)_(.+)$")
    if start_str and end_str then
        local start_time = h.parse_time_string(start_str)
        local end_time = h.parse_time_string(end_str)
        if start_time and end_time then
            user_timings.set('start', start_time - mp.get_property("audio-delay"))
            user_timings.set('end', end_time - mp.get_property("audio-delay"))
            set_user_timing_source('start', 'manual')
            set_user_timing_source('end', 'manual')
            sync_subtitle_based_timing()
            h.notify("Start and end times have been set from clipboard (no padding).")
            start_appending()
            return
        end
    end
    -- Single time format
    local time = h.parse_time_string(clip)
    if not time then
        h.notify("Invalid time format in clipboard. Use formats like 123.456, 1:23.456, 1:23:45.678, or start_end format like 05m23s548ms_06m30s665ms", "warn", 3)
        return
    end
    -- Find the nearest subtitle time if needed, but for now, set exactly
    user_timings.set(position, time - mp.get_property("audio-delay"))
    set_user_timing_source(position, 'manual')
    sync_subtitle_based_timing()
    h.notify(h.capitalize_first_letter(position) .. " time has been set to " .. h.human_readable_time(time) .. " (from clipboard, no padding).")
    start_appending()
end

self.set_to_current_sub = function()
    local current_sub = Subtitle:now()
    if not current_sub then
        h.notify("There's no visible subtitle.", "info", 2)
        return
    end

    reset_recorded_dialogs()
    if self.user_altered() then
        sync_subtitle_based_timing()
        start_appending()
        h.notify("Captured subtitles cleared. Existing timings preserved; capture resumed.")
    else
        is_subtitle_based_timing = true
        start_appending()
        h.notify("Timings have been set to the current sub (subtitle-based).")
    end
end

self.clear = function()
    append_dialogue = false
    dialogs = sub_list.new()
    secondary_dialogs = sub_list.new()
    user_timings = timings.new()
    clear_user_timing_sources()
    is_subtitle_based_timing = false
end

self.clear_captured_subtitles = function(resume_capture)
    append_dialogue = false
    reset_recorded_dialogs()

    if resume_capture then
        start_appending()
        if subtitle_capture_enabled then
            h.notify("Captured subtitles cleared. Subtitle capture resumed.", "info", 2)
        else
            h.notify("Captured subtitles cleared. Subtitle capture remains disabled.", "info", 2)
        end
    else
        h.notify("Captured subtitles cleared. Subtitle capture stopped.", "info", 2)
    end
end

self.subtitle_capture_disabled = function()
    return not subtitle_capture_enabled
end

self.toggle_subtitle_capture = function()
    subtitle_capture_enabled = not subtitle_capture_enabled
    if subtitle_capture_enabled and append_dialogue then
        append_primary_sub()
        append_secondary_sub()
    end
    h.notify(
        subtitle_capture_enabled and "Subtitle capture enabled." or "Subtitle capture disabled. Timings remain unchanged.",
        "info",
        2
    )
end

self.remove_current_subtitle_from_recorded = function()
    local removed = false
    local current_sub = Subtitle:now()
    local current_secondary_sub = Subtitle:now('secondary')

    if dialogs.remove(current_sub) then
        removed = true
    end
    if secondary_dialogs.remove(current_secondary_sub) then
        removed = true
    end

    if removed then
        h.notify("Current subtitle removed from captured list.", "info", 2)
    elseif current_sub ~= nil or current_secondary_sub ~= nil then
        h.notify("Current subtitle is not in the captured list.", "info", 2)
    else
        h.notify("There's no visible subtitle.", "info", 2)
    end
end

self.clear_all_dialogs = function()
    all_dialogs = sub_list.new()
    all_secondary_dialogs = sub_list.new()
end

self.clear_and_notify = function()
    --- Clear then notify the user.
    --- Called by the OSD menu when the user presses a button to drop recorded subtitles.
    self.clear()
    h.notify("Timings have been reset.", "info", 2)
end

self.is_appending = function()
    return append_dialogue
end

self.recorded_subs = function()
    return dialogs.get_subs_list()
end

self.recorded_secondary_subs = function()
    return secondary_dialogs.get_subs_list()
end

self.autocopy_status_str = function()
    return string.format(
            "%s (%s)",
            (autoclip_enabled and 'enabled' or 'disabled'),
            autoclip_method.get():gsub('_', ' ')
    )
end

self.autocopy_current_method = function()
    return autoclip_method.get()
end

local function notify_autocopy()
    if autoclip_enabled then
        copy_primary_sub()
    end
    h.notify(string.format("Clipboard autocopy has been %s.", self.autocopy_status_str()))
end

self.toggle_autocopy = function()
    autoclip_enabled = not autoclip_enabled
    notify_autocopy()
end

self.next_autoclip_method = function()
    autoclip_method.bump()
    notify_autocopy()
end

self.save_last_timings_values = function(start_t, end_t)
    if type(start_t) == 'number' and type(end_t) == 'number' and start_t >= 0 and end_t >= 0 and end_t >= start_t then
        last_timings.set('start', start_t)
        last_timings.set('end', end_t)
        h.notify("Last timings saved.", "info", 2)
    else
        h.notify("Couldn't save last timings: invalid values.", "warn", 2)
    end
end

self.save_last_timings = function()
    if user_timings.is_set('start') and user_timings.is_set('end') then
        last_timings.set('start', user_timings.get('start'))
        last_timings.set('end', user_timings.get('end'))
        h.notify("Last timings saved.", "info", 2)
    end
end

self.load_last_timings = function()
    if last_timings.is_set('start') and last_timings.is_set('end') then
        user_timings.set('start', last_timings.get('start'))
        user_timings.set('end', last_timings.get('end'))
        set_user_timing_source('start', 'manual')
        set_user_timing_source('end', 'manual')
        sync_subtitle_based_timing()
        h.notify("Last timings loaded.", "info", 2)
        start_appending()
    else
        h.notify("No last timings saved.", "warn", 2)
    end
end

self.init = function(menu, config)
    self.menu = menu
    self.config = config

    -- The autoclip state is copied as a local value
    -- to prevent it from being reset when the user reloads the config file.
    autoclip_enabled = self.config.autoclip
    autoclip_method.set(self.config.autoclip_method)

    mp.observe_property("sub-text", "string", handle_primary_sub)
    mp.observe_property("secondary-sub-text", "string", handle_secondary_sub)
end

return self