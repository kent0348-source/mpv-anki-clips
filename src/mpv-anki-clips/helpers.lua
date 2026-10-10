--[[
Copyright: Ren Tatsumoto and contributors
License: GNU GPL, version 3 or later; http://www.gnu.org/licenses/gpl.html

Various helper functions.
]]

local mp = require('mp')
local msg = require('mp.msg')
local logger = require('utils.logger')
local utils = require('mp.utils')
local this = {}

-- Deep copy a table, handling nested tables and cycles
function this.deepcopy(orig, copies)
    copies = copies or {}
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        if copies[orig] then
            copy = copies[orig]
        else
            copy = {}
            copies[orig] = copy
            for orig_key, orig_value in next, orig, nil do
                copy[this.deepcopy(orig_key, copies)] = this.deepcopy(orig_value, copies)
            end
            setmetatable(copy, this.deepcopy(getmetatable(orig), copies))
        end
    else
        copy = orig
    end
    return copy
end

this.unpack = unpack and unpack or table.unpack

this.remove_all_spaces = function(str)
    return str:gsub('%s*', '')
end

this.table_get = function(table, key, default)
    if table[key] == nil then
        return default or 'nil'
    else
        return table[key]
    end
end

this.max_num = function(table)
    local max = table[1]
    for _, value in ipairs(table) do
        if value > max then
            max = value
        end
    end
    return max
end

this.get_last_n_added_notes = function(note_ids, n)
    table.sort(note_ids)
    return { this.unpack(note_ids, math.max(#note_ids - n + 1, 1), #note_ids) }
end

this.contains = function(table, element)
    for _, value in pairs(table) do
        if value == element then
            return true
        end
    end
    return false
end

this.minutes_ago = function(m)
    return (os.time() - 60 * m) * 1000
end

this.is_wayland = function()
    return os.getenv('WAYLAND_DISPLAY') ~= nil
end

this.is_win = function()
    return mp.get_property('options/vo-mmcss-profile') ~= nil
end

this.is_mac = function()
    return mp.get_property('options/macos-force-dedicated-gpu') ~= nil
end

local function map(tab, func)
    local t = {}
    for k, v in pairs(tab) do
        t[k] = func(v)
    end
    return t
end

local function args_as_str(args)
    return table.concat(map(args, function(str) return string.format("'%s'", str) end), " ")
end

this.subprocess = function(args, completion_fn, override_settings)
    override_settings = override_settings or {}
    -- Optional categorized logging control
    local log_category = override_settings.log_category
    local log_command = override_settings.log_command
    if log_command == nil then log_command = true end

    if log_command then
        local line = "Executing: " .. args_as_str(args)
        if log_category then
            logger.info_cat(log_category, line)
        else
            msg.info(line)
        end
    end
    local command_native = type(completion_fn) == 'function' and mp.command_native_async or mp.command_native
    local command_table = {
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args
    }
    -- Only forward supported keys to mpv (others are our wrapper controls)
    local allowed = { detach=true, capture_stdout=true, capture_stderr=true, playback_only=true, cwd=true, env=true }
    for k, v in pairs(override_settings) do
        if allowed[k] ~= nil then
            command_table[k] = v
        end
    end

    -- Local helpers for summarization
    local function tail_lines(s, n)
        if not s or s == '' then return '' end
        local lines = {}
        for line in s:gmatch("[^\r\n]+") do table.insert(lines, line) end
        local start = math.max(1, #lines - (n or 30) + 1)
        return table.concat({ table.unpack(lines, start, #lines) }, "\n")
    end

    local function summarize_and_callback(cb_args, result)
        if result and result.status and result.status ~= 0 and override_settings.summarize_on_error then
            local tail = tail_lines(result.stderr or result.stdout or '', override_settings.stderr_tail_lines or 30)
            msg.error("Subprocess failed (exit " .. tostring(result.status) .. ")")
            if tail ~= '' then
                msg.error("stderr (tail):\n" .. tail)
            end
            if type(override_settings.on_error) == 'function' then
                pcall(override_settings.on_error, cb_args, result, tail)
            end
        end
    end

    if type(completion_fn) == 'function' then
        -- Async path: wrap completion to summarize on error
        local function wrapped(success, result)
            if not success then
                result = result or { status = -1, stderr = '', stdout = '' }
            end
            summarize_and_callback(args, result)
            return completion_fn(success, result)
        end
        return command_native(command_table, wrapped)
    else
        -- Sync path
        local res = command_native(command_table)
        summarize_and_callback(args, res)
        return res
    end
end

this.subprocess_detached = function(args, completion_fn)
    local overwrite_settings = {
        detach=true,
        capture_stdout = false,
        capture_stderr = false,
    }
    return this.subprocess(args, completion_fn, overwrite_settings)
end

this.is_empty = function(var)
    return var == nil or var == '' or (type(var) == 'table' and next(var) == nil)
end

this.contains_non_latin_letters = function(str)
    return str:match("[^%c%p%s%w—]")
end

this.capitalize_first_letter = function(string)
    return string:gsub("^%l", string.upper)
end

this.remove_leading_trailing_spaces = function(str)
    return str:gsub('^%s*(.-)%s*$', '%1')
end

this.remove_leading_trailing_dashes = function(str)
    return str:gsub('^[%-_]*(.-)[%-_]*$', '%1')
end

this.remove_text_in_parentheses = function(str)
    return str:gsub('(%b())(.)', '%2'):gsub('(（.-）)(.)', '%2')
end

this.remove_newlines = function(str)
    return str:gsub('[\n\r]+', ' ')
end

this.remove_arrows = function(str, remove_arrows_mode, for_anki_export)
    if remove_arrows_mode == "join" then
        if for_anki_export then
            -- Remove arrows but preserve newlines for Anki export
            return str:gsub("➡%s*\n", "\n"):gsub("→%s*\n", "\n"):gsub("➡%s*$", ""):gsub("→%s*$", "")
        else
            -- Replace arrows with space for preview/clipboard
            return str:gsub("➡%s*", " "):gsub("→%s*", " ")
        end
    elseif remove_arrows_mode == "join_arrow" and for_anki_export then
        return str -- Skip arrow processing for Anki export with join_arrow
    elseif remove_arrows_mode == true or remove_arrows_mode == "yes" then
        return str:gsub("➡", ""):gsub("→", "")
    end
    return str
end

this.has_arrow = function(str)
    return str:match("➡%s*$") or str:match("→%s*$")
end

this.trim = function(str, preserve_newlines, preserve_japanese_parentheses, remove_arrows, for_anki_export)
    str = this.remove_leading_trailing_spaces(str)
    if not preserve_japanese_parentheses then
        str = this.remove_text_in_parentheses(str)
    end
    if not preserve_newlines then
        str = this.remove_newlines(str)
    end
    msg.debug("Before remove_arrows: " .. str)
    str = this.remove_arrows(str, remove_arrows, for_anki_export)
    msg.debug("After remove_arrows: " .. str)
    return str
end

this.escape_special_characters = (function()
    local entities = {
        ['&'] = '&',
        ['"'] = '"',
        ["'"] = "'",
        ['<'] = '<',
        ['>'] = '>',
    }
    return function(s)
        return s:gsub('[&"\'<>]', entities)
    end
end)()

this.convert_newlines_to_br = function(str)
    return str:gsub('[\n\r]+', '<br>')
end

this.remove_extension = function(filename)
    return filename:gsub('%.%w+$', '')
end

this.remove_special_characters = function(str)
    return str:gsub('[%c%p%s]', ''):gsub('　', '')
end

this.remove_text_in_brackets = function(str)
    return str:gsub('%b[]', ''):gsub('【.-】', '')
end

this.remove_filename_text_in_parentheses = function(str)
    return str:gsub('%b()', ''):gsub('（.-）', '')
end

this.remove_common_resolutions = function(str)
    return str:gsub("2160p", ""):gsub("1080p", ""):gsub("720p", ""):gsub("576p", ""):gsub("480p", ""):gsub("%(%)", ""):gsub("%[%]", "")
end

this.human_readable_time = function(seconds)
    if type(seconds) ~= 'number' or seconds < 0 then
        return 'empty'
    end

    local parts = {
        h = math.floor(seconds / 3600),
        m = math.floor(seconds / 60) % 60,
        s = math.floor(seconds % 60),
        ms = math.floor((seconds * 1000) % 1000),
    }

    local ret = string.format("%02dm%02ds%03dms", parts.m, parts.s, parts.ms)

    if parts.h > 0 then
        ret = string.format('%dh%s', parts.h, ret)
    end

    return ret
end

this.human_readable_time_no_ms = function(seconds)
    if type(seconds) ~= 'number' or seconds < 0 then
        return 'empty'
    end

    local parts = {
        h = math.floor(seconds / 3600),
        m = math.floor(seconds / 60) % 60,
        s = math.floor(seconds % 60),
    }

    local ret = string.format("%02dm%02ds", parts.m, parts.s)

    if parts.h > 0 then
        ret = string.format('%dh%s', parts.h, ret)
    end

    return ret
end

this.parse_time_string = function(time_str)
    if not time_str or time_str == '' then
        return nil
    end
    -- Remove leading/trailing whitespace
    time_str = time_str:match("^%s*(.-)%s*$")
    -- Match formats with units: e.g., 35m50s482ms
    local h_u, m_u, s_u, ms_u = time_str:match("^(%d+)h(%d+)m(%d+)s(%d+)ms$")
    if h_u and m_u and s_u and ms_u then
        return tonumber(h_u) * 3600 + tonumber(m_u) * 60 + tonumber(s_u) + tonumber(ms_u) / 1000
    end
    local m_u2, s_u2, ms_u2 = time_str:match("^(%d+)m(%d+)s(%d+)ms$")
    if m_u2 and s_u2 and ms_u2 then
        return tonumber(m_u2) * 60 + tonumber(s_u2) + tonumber(ms_u2) / 1000
    end
    local s_u3, ms_u3 = time_str:match("^(%d+)s(%d+)ms$")
    if s_u3 and ms_u3 then
        return tonumber(s_u3) + tonumber(ms_u3) / 1000
    end
    -- Match formats: H:M:S.ms, M:S.ms, S.ms
    local h, m, s, ms = time_str:match("^(%d+):(%d+):(%d+)%.(%d+)$")
    if h and m and s and ms then
        return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + tonumber(ms) / 1000
    end
    local m2, s2, ms2 = time_str:match("^(%d+):(%d+)%.(%d+)$")
    if m2 and s2 and ms2 then
        return tonumber(m2) * 60 + tonumber(s2) + tonumber(ms2) / 1000
    end
    local s3, ms3 = time_str:match("^(%d+)%.(%d+)$")
    if s3 and ms3 then
        return tonumber(s3) + tonumber(ms3) / 1000
    end
    -- Also support without ms
    local h4, m4, s4 = time_str:match("^(%d+):(%d+):(%d+)$")
    if h4 and m4 and s4 then
        return tonumber(h4) * 3600 + tonumber(m4) * 60 + tonumber(s4)
    end
    local m5, s5 = time_str:match("^(%d+):(%d+)$")
    if m5 and s5 then
        return tonumber(m5) * 60 + tonumber(s5)
    end
    local s6 = time_str:match("^(%d+)$")
    if s6 then
        return tonumber(s6)
    end
    return nil
end

this.get_episode_number = function(filename)
    local filename_reversed = filename:reverse()

    local ep_num_patterns = {
        "[%s_](%d?%d?%d)[pP]?[eE]", -- Starting with E or EP (case-insensitive). "Example Series S01E01 [94Z295D1]"
        "^(%d?%d?%d)[pP]?[eE]", -- Starting with E or EP (case-insensitive) at the end of filename. "Example Series S01E01"
        "%)(%d?%d?%d)%(", -- Surrounded by parentheses. "Example Series (12)"
        "%](%d?%d?%d)%[", -- Surrounded by brackets. "Example Series [01]"
        "%s(%d?%d?%d)%s", -- Surrounded by whitespace. "Example Series 124 [1080p 10-bit]"
        "_(%d?%d?%d)_", -- Surrounded by underscores. "Example_Series_04_1080p"
        "^(%d?%d?%d)[%s_]", -- Ending to the episode number. "Example Series 124"
        "(%d?%d?%d)%-edosipE", -- Prepended by "Episode-". "Example Episode-165"
    }

    local s, e, episode_num
    for _, pattern in pairs(ep_num_patterns) do
        s, e, episode_num = string.find(filename_reversed, pattern)
        if not this.is_empty(episode_num) then
            return #filename - e, #filename - s, episode_num:reverse()
        end
    end
end

-- Notification system with stacking support
local notification_stack = {}
local refresh_timer = nil
local overwrite_message_id = "overwrite_notif"

this.notify = function(message, level, duration, stack)
    level = level or 'info'
    duration = duration or 1
    stack = stack ~= false  -- Default to true (stacking)
    msg[level](message)

    if not stack then
        -- Overwriting mode: use a single OSD message that gets replaced
        mp.osd_message(message, duration, overwrite_message_id)
        return
    end

    -- Stacking mode
    -- Add to stack
    table.insert(notification_stack, {
        message = message,
        duration = duration,
        start_time = os.time(),
        timer = nil
    })

    -- Limit stack size
    if #notification_stack > 10 then
        table.remove(notification_stack, 1)
    end

    -- Update display
    this.update_display()

    -- Schedule removal
    local current_notif = notification_stack[#notification_stack]
    current_notif.timer = mp.add_timeout(duration, function()
        -- Remove this specific notification
        for i, notif in ipairs(notification_stack) do
            if notif == current_notif then
                table.remove(notification_stack, i)
                break
            end
        end
        this.update_display()
    end)

    -- Start refresh timer if not already running
    if not refresh_timer then
        refresh_timer = mp.add_periodic_timer(0.5, this.update_display)
    end
end

this.update_display = function()
    -- Clean up expired notifications
    local current_time = os.time()
    local i = 1
    while i <= #notification_stack do
        if current_time >= notification_stack[i].start_time + notification_stack[i].duration then
            table.remove(notification_stack, i)
        else
            i = i + 1
        end
    end

    if #notification_stack == 0 then
        mp.osd_message("", 0)
        if refresh_timer then
            refresh_timer:kill()
            refresh_timer = nil
        end
        return
    end

    -- Build combined message with line breaks (newest on top)
    local lines = {}
    for i = #notification_stack, 1, -1 do
        table.insert(lines, notification_stack[i].message)
    end

    local combined_message = table.concat(lines, "\n")
    mp.osd_message(combined_message, 1)  -- Keep visible
end

this.get_active_track = function(track_type)
    for _, track in pairs(mp.get_property_native('track-list')) do
        if track.type == track_type and track.selected == true then
            return track
        end
    end
    return nil
end

this.has_video_track = function()
    return mp.get_property_native('vid') ~= false
end

this.has_audio_track = function()
    return mp.get_property_native('aid') ~= false
end

this.str_contains = function(s, pattern)
    return not this.is_empty(s) and string.find(string.lower(s), string.lower(pattern)) ~= nil
end

this.filter = function(arr, func)
    local filtered = {}
    for _, elem in ipairs(arr) do
        if func(elem) == true then
            table.insert(filtered, elem)
        end
    end
    return filtered
end

this.safe_file_info = function(filepath)
    if this.is_empty(filepath) then
        return nil
    end

    local info = utils.file_info(filepath)
    if info and info.is_file then
        return info
    end

    -- Fallback for paths that utils.file_info may fail to resolve (e.g., UTF-8 on Windows)
    local ok, f = pcall(io.open, filepath, "rb")
    if ok and f then
        local size = f:seek("end")
        f:close()
        if size and size >= 0 then
            return { is_file = true, size = size }
        end
    end

    return nil
end

this.file_exists = function(filepath)
    local info = this.safe_file_info(filepath)
    return info and info.is_file and info.size > 0 or false
end

this.get_loaded_tracks = function(track_type)
    return this.filter(mp.get_property_native('track-list'), function(track) return track.type == track_type end)
end

-- Parse a shell-like argument string into an array of tokens with support for
-- quoting (single and double) and backslash escaping. Preserves values with
-- spaces/colons when quoted or provided in key=value form.
-- Example:
--   [[-svtav1-params=mbr=1000:mbr-overshoot-pct=25 "-vf scale=1280:720" 'foo bar']]
-- becomes {"-svtav1-params=mbr=1000:mbr-overshoot-pct=25", "-vf", "scale=1280:720", "foo bar"}
this.parse_shell_like_args = function(s)
    if this.is_empty(s) then return {} end
    local args = {}
    local buf = {}
    local in_single = false
    local in_double = false
    local escape = false

    for c in s:gmatch(".") do
        if escape then
            table.insert(buf, c)
            escape = false
        elseif c == "\\" and not in_single then
            -- Backslash escapes outside single quotes; inside double quotes it's honored
            escape = true
        elseif c == '"' and not in_single then
            in_double = not in_double
        elseif c == "'" and not in_double then
            in_single = not in_single
        elseif c:match("%s") and not in_single and not in_double then
            if #buf > 0 then
                table.insert(args, table.concat(buf))
                buf = {}
            end
        else
            table.insert(buf, c)
        end
    end
    if #buf > 0 then
        table.insert(args, table.concat(buf))
    end
    return args
end

-- Copy a file from src to dst (binary-safe). Returns true on success.
-- Intended for moving staged outputs (e.g. from a shared network drive) into the local Anki media folder.
this.copy_file = function(src, dst)
    if this.is_empty(src) or this.is_empty(dst) then return false end
    local in_f = io.open(src, 'rb')
    if not in_f then return false end
    local out_f = io.open(dst, 'wb')
    if not out_f then
        in_f:close()
        return false
    end
    local chunk_size = 4 * 1024 * 1024
    while true do
        local chunk = in_f:read(chunk_size)
        if not chunk then break end
        out_f:write(chunk)
    end
    in_f:close()
    out_f:close()
    return true
end

return this