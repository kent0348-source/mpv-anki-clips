local utils = require('mp.utils')
local h = require('helpers')

local ffmpeg_exec = {}

function ffmpeg_exec.find(name)
    local alt_path_dirs = {
        '/opt/homebrew/bin',
        '/usr/local/bin',
        utils.join_path(os.getenv("HOME") or "~", '.local/bin'),
    }
    local executable_name = name
    if h.is_win() and not executable_name:match('%.exe$') then
        executable_name = executable_name .. '.exe'
    end

    for _, directory in ipairs(alt_path_dirs) do
        local candidate = utils.join_path(directory, executable_name)
        local info = utils.file_info(candidate)
        if info and info.is_file then
            return candidate
        end
    end

    if h.is_win() and executable_name:match('%.exe$') then
        executable_name = executable_name:gsub('%.exe$', '')
    end
    return executable_name
end

function ffmpeg_exec.resolve(configured_path)
    if type(configured_path) == 'string' and configured_path:match('%S') then
        return configured_path
    end
    return ffmpeg_exec.find('ffmpeg')
end

return ffmpeg_exec
