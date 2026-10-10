--[[
Copyright: Ren Tatsumoto and contributors
License: GNU GPL, version 3 or later; http://www.gnu.org/licenses/gpl.html

Platform-specific functions for *nix systems.
]]

local h = require('helpers')
local self = { healthy = true, clip_util = "", clip_cmd = "", }

if h.is_mac() then
    self.clip_util = "pbcopy"
    self.clip_cmd = "LANG=en_US.UTF-8 " .. self.clip_util
elseif h.is_wayland() then
    local function is_wl_copy_installed()
        local handle = h.subprocess { 'wl-copy', '--version' }
        return handle.status == 0 and handle.stdout:match("wl%-clipboard") ~= nil
    end

    self.clip_util = "wl-copy"
    self.clip_cmd = self.clip_util
    self.healthy = is_wl_copy_installed()
else
    local function is_xclip_installed()
        local handle = h.subprocess { 'xclip', '-version' }
        return handle.status == 0 and handle.stderr:match("xclip version") ~= nil
    end

    self.clip_util = "xclip"
    self.clip_cmd = self.clip_util .. " -i -selection clipboard"
    self.healthy = is_xclip_installed()
end

self.tmp_dir = function()
    return os.getenv("TMPDIR") or '/tmp'
end

self.copy_to_clipboard = function(text)
    local handle = io.popen(self.clip_cmd, 'w')
    handle:write(text)
    handle:close()
end

-- Read text from the system clipboard. Returns string or nil.
self.get_clipboard = function()
    local read_cmd
    if self.clip_util == 'pbcopy' then
        -- macOS: use pbpaste
        read_cmd = 'pbpaste'
    elseif self.clip_util == 'wl-copy' then
        read_cmd = 'wl-paste -n'
    else
        read_cmd = 'xclip -o -selection clipboard'
    end
    local handle = io.popen(read_cmd, 'r')
    if not handle then return nil end
    local out = handle:read('*a')
    handle:close()
    if out and out ~= '' then
        local trimmed = (out:gsub('[\r\n]+$', ''))
        if type(mp) ~= 'nil' then
            mp.msg.debug("platform.nix.get_clipboard: success, length=" .. tostring(#trimmed))
            mp.msg.debug("platform.nix.get_clipboard: snippet='" .. trimmed:sub(1, 80):gsub('\n', '\\n') .. "'")
        end
        return trimmed
    end
    if type(mp) ~= 'nil' then
        mp.msg.debug("platform.nix.get_clipboard: failed or empty")
    end
    return nil
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
