local assertx = require('tests.support.assert')

local function clear_modules()
    package.loaded['encoder.codec_support'] = nil
    package.loaded['encoder.ffmpeg_exec'] = nil
    package.loaded['mp.utils'] = nil
    package.loaded['mp.msg'] = nil
    package.loaded['helpers'] = nil
    package.loaded['utils.logger'] = nil
    package.preload['encoder.codec_support'] = nil
end

return {
    {
        name = 'FFmpeg resolver honors explicit Linux and Windows executable paths',
        run = function()
            local is_windows = true
            package.preload['mp.utils'] = function()
                return {
                    join_path = function(left, right)
                        return left .. '/' .. right
                    end,
                    file_info = function()
                        return nil
                    end,
                }
            end
            package.preload['helpers'] = function()
                return { is_win = function() return is_windows end }
            end
            clear_modules()
            local resolver = require('encoder.ffmpeg_exec')

            local linux_path = '/home/ghoeb/ffmpeg_build/bin/ffmpeg'
            local windows_path = [[C:\ffmpeg custom\bin\ffmpeg.exe]]
            assertx.equals(linux_path, resolver.resolve(linux_path), 'Linux executable path should be passed through unchanged')
            assertx.equals(windows_path, resolver.resolve(windows_path), 'Windows executable path should be passed through unchanged')
            assertx.equals('ffmpeg', resolver.resolve(''), 'an empty setting should retain automatic Windows executable lookup')
        end,
    },
    {
        name = 'codec support checks the configured local FFmpeg executable',
        run = function()
            local commands = {}
            package.preload['mp.utils'] = function()
                return {
                    join_path = function(left, right)
                        return left .. '/' .. right
                    end,
                    file_info = function()
                        return nil
                    end,
                }
            end
            package.preload['mp.msg'] = function()
                return { warn = function() end }
            end
            package.preload['helpers'] = function()
                return {
                    is_win = function() return false end,
                    subprocess = function(args)
                        commands[#commands + 1] = args
                        return {
                            status = 0,
                            stdout = ' V..... libsvtav1 AV1 encoder\n',
                            stderr = '',
                        }
                    end,
                    notify = function() end,
                }
            end
            package.preload['utils.logger'] = function()
                return {
                    should_log = function() return false end,
                    info_cat = function() end,
                    warn_cat = function() end,
                }
            end
            clear_modules()
            local codec_support = require('encoder.codec_support')
            local configured_path = '/home/ghoeb/ffmpeg_build/bin/ffmpeg'
            codec_support.configure({ ffmpeg_exec = configured_path })

            assertx.equals(configured_path, commands[#commands][1], 'codec checks should invoke the configured executable')
            assertx.truthy(codec_support.codecs.ffmpeg.video.libsvtav1, 'codec checks should inspect the configured executable output')
        end,
    },
    {
        name = 'codec support reports an unusable explicitly configured FFmpeg path',
        run = function()
            local commands = {}
            local warnings = {}
            package.preload['mp.utils'] = function()
                return {
                    join_path = function(left, right)
                        return left .. '/' .. right
                    end,
                    file_info = function()
                        return nil
                    end,
                }
            end
            package.preload['mp.msg'] = function()
                return {
                    warn = function(message)
                        warnings[#warnings + 1] = message
                    end,
                }
            end
            package.preload['helpers'] = function()
                return {
                    is_win = function() return false end,
                    subprocess = function(args)
                        commands[#commands + 1] = args
                        return { status = 1, stdout = '', stderr = 'executable not found' }
                    end,
                    notify = function() end,
                }
            end
            package.preload['utils.logger'] = function()
                return {
                    should_log = function() return false end,
                    info_cat = function() end,
                    warn_cat = function() end,
                }
            end
            clear_modules()
            local codec_support = require('encoder.codec_support')
            local configured_path = '/missing/ffmpeg'
            codec_support.configure({ ffmpeg_exec = configured_path })

            assertx.equals(configured_path, commands[#commands][1], 'an invalid explicit path must not fall back')
            assertx.truthy(warnings[#warnings]:find(configured_path, 1, true), 'the invalid configured path should be named in the warning')
            assertx.truthy(warnings[#warnings]:find('executable not found', 1, true), 'the command failure should be surfaced')
        end,
    },
}
