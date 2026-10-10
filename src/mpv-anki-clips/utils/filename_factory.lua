--[[
Copyright: Ren Tatsumoto and contributors
License: GNU GPL, version 3 or later; http://www.gnu.org/licenses/gpl.html

Creates image and audio filenames compatible with Anki.
]]

local mp = require('mp')
local h = require('helpers')

local filename

local function sanitize_media_filename(media_name)
    local sanitized = media_name or ''
    sanitized = h.remove_extension(sanitized)
    sanitized = h.remove_filename_text_in_parentheses(sanitized)
    sanitized = h.remove_text_in_brackets(sanitized)
    sanitized = h.remove_special_characters(sanitized)
    sanitized = h.remove_newlines(sanitized)
    sanitized = h.remove_leading_trailing_spaces(sanitized)
    sanitized = h.remove_leading_trailing_dashes(sanitized)

    if not sanitized or sanitized == '' then
        sanitized = 'mpv-anki-clips_' .. tostring(os.time())
    end

    return sanitized
end

local anki_compatible_length = (function()
    -- Anki forcibly mutilates all filenames longer than 119 bytes when you run `Tools->Check Media...`.
    local allowed_bytes = 119
    local timestamp_bytes = #'_99h99m99s999ms-99h99m99s999ms.webp'

    return function(str, timestamp)
        -- if timestamp provided, recalculate limit_bytes
        local limit_bytes = allowed_bytes - (timestamp and #timestamp or timestamp_bytes)

        if #str <= limit_bytes then
            return str
        end

        local bytes_per_char = h.contains_non_latin_letters(str) and #'車' or #'z'
        local limit_chars = math.floor(limit_bytes / bytes_per_char)

        if limit_chars == limit_bytes then
            return str:sub(1, limit_bytes)
        end

        -- UTF-8 safe substring of the first N characters (codepoints)
        local function utf8_sub(s, n)
            if n <= 0 then return '' end
            local i = 1
            local out_bytes = 0
            local taken = 0
            while i <= #s and taken < n do
                local c = s:byte(i)
                local len
                if c < 0x80 then
                    len = 1
                elseif c >= 0xC2 and c <= 0xDF then
                    len = 2
                elseif c >= 0xE0 and c <= 0xEF then
                    len = 3
                elseif c >= 0xF0 and c <= 0xF4 then
                    len = 4
                else
                    -- Invalid start byte, skip as 1 to avoid infinite loop
                    len = 1
                end
                out_bytes = i + len - 1
                i = i + len
                taken = taken + 1
            end
            return s:sub(1, out_bytes)
        end

        local truncated = utf8_sub(str, limit_chars)
        truncated = h.remove_newlines(truncated)
        truncated = h.remove_leading_trailing_spaces(truncated)
        return truncated
    end
end)()

local make_media_filename = function()
    filename = sanitize_media_filename(mp.get_property("filename")) -- filename without path
end

local function timestamp_range(start_timestamp, end_timestamp, extension)
    -- Generates a filename suffix of the form: _00h00m00s000ms_99h99m99s999ms.extension
    -- Extension must already contain the dot.
    return string.format(
            '_%s_%s%s',
            h.human_readable_time(start_timestamp),
            h.human_readable_time(end_timestamp),
            extension
    )
end

local function timestamp_static(timestamp, extension)
    -- Generates a filename suffix of the form: _00h00m00s000ms.extension
    -- Extension must already contain the dot.
    return string.format(
            '_%s%s',
            h.human_readable_time(timestamp),
            extension
    )
end

local make_filename = function(...)
    local args = {...}
    local timestamp = #args < 3 and timestamp_static(...) or timestamp_range(...)

    -- Best-effort: ensure we have a base name even if file-loaded event didn't run.
    if not filename or filename == '' then
        make_media_filename()
    end

    return string.lower(anki_compatible_length(filename, timestamp) .. timestamp)
end

local make_filename_for_media_name = function(media_name, ...)
    local args = {...}
    local timestamp = #args < 3 and timestamp_static(...) or timestamp_range(...)
    local explicit_filename = sanitize_media_filename(media_name)
    return string.lower(anki_compatible_length(explicit_filename, timestamp) .. timestamp)
end

mp.register_event("file-loaded", make_media_filename)

return {
    make_filename = make_filename,
    make_filename_for_media_name = make_filename_for_media_name,
}
