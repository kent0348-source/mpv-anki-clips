--[[
Copyright: Ren Tatsumoto and contributors
License: GNU GPL, version 3 or later; http://www.gnu.org/licenses/gpl.html

Platform-specific functions for Windows.
]]

local mp = require('mp')
local h = require('helpers')
local utils = require('mp.utils')
local base64 = require('utils.base64')
local self = { windows = true, healthy = true, clip_util = "cmd", }
local tmp_files = {}

mp.register_event('shutdown', function()
    for _, file in ipairs(tmp_files) do
        os.remove(file)
    end
end)

self.tmp_dir = function()
    return os.getenv('TEMP')
end

self.copy_to_clipboard = function(text)
    local args = {
        "powershell", "-NoLogo", "-NoProfile", "-WindowStyle", "Hidden", "-Command",
        string.format(
                "Set-Clipboard ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s')))",
                base64.enc(text)
        )
    }
    return h.subprocess_detached(
            args,
            function()
            end
    )
end

-- Read text from the system clipboard. Returns string or nil.
self.get_clipboard = function()
    -- Use PowerShell Get-Clipboard and capture stdout as base64 UTF-8
    local args = {
        "powershell", "-NoLogo", "-NoProfile", "-WindowStyle", "Hidden", "-Command",
        "[Console]::OutputEncoding = [Text.Encoding]::UTF8; try { $text = Get-Clipboard -Raw; [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) } catch { exit 1 }"
    }
    local handle = h.subprocess(args)
    if handle and handle.status == 0 and handle.stdout and handle.stdout ~= '' then
        local out = (handle.stdout:gsub('[\r\n]+$', ''))
        local decoded = base64.dec(out)
        if decoded then
            mp.msg.debug("platform.win.get_clipboard: success, length=" .. tostring(#decoded))
            -- Log a short snippet (first 80 chars) to help debugging without flooding the console
            mp.msg.debug("platform.win.get_clipboard: snippet='" .. decoded:sub(1, 80):gsub('\n', '\\n') .. "'")
            return decoded
        else
            mp.msg.debug("platform.win.get_clipboard: base64 decode failed")
        end
    else
        mp.msg.debug("platform.win.get_clipboard: failed or empty (status=" .. tostring(handle and handle.status or 'nil') .. ")")
    end
    return nil
end

self.gen_random_tmp_file_path = function()
    return utils.join_path(self.tmp_dir(), string.format('curl_tmp_%d.txt', math.random(10 ^ 9)))
end

self.gen_unique_tmp_file_path = function()
    local curl_tmpfile_path = self.gen_random_tmp_file_path()
    while h.file_exists(curl_tmpfile_path) do
        curl_tmpfile_path = self.gen_random_tmp_file_path()
    end
    return curl_tmpfile_path
end

self.http_request = function(options, completion_fn)
    local method = options.method or 'GET'
    local args = {
        'curl', '--silent', '--show-error',
        '--connect-timeout', tostring(options.connect_timeout or 2),
        '--max-time', tostring(options.timeout or 5),
        '--request', method,
        '--write-out', '\n%{http_code}',
        options.url,
    }
    if options.body ~= nil then
        table.insert(args, '--header')
        table.insert(args, 'Content-Type: application/json; charset=UTF-8')
        table.insert(args, '--data-binary')
        table.insert(args, options.body)
    end

    local function parse_response(result)
        if result and result.stdout then
            local body, status = result.stdout:match('^(.*)\r?\n(%d%d%d)$')
            if status then
                result.stdout = body
                result.http_status = tonumber(status)
            end
        end
        return result
    end

    if type(completion_fn) == 'function' then
        return h.subprocess(args, function(success, result)
            completion_fn(success, parse_response(result))
        end, { log_command = false })
    end

    return parse_response(h.subprocess(args, nil, { log_command = false }))
end

self.curl_request = function(url, request_json, completion_fn)
    return self.http_request({
        url = url,
        method = 'POST',
        body = request_json,
    }, completion_fn)
end

return self
