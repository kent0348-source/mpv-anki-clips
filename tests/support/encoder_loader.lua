local M = {}

function M.load_encoder(options)
    options = options or {}
    options.pending_callbacks = {}
    options.aborted_async_ids = {}
    options.periodic_timers = {}
    package.loaded['encoder.encoder'] = nil
    package.loaded['mp'] = nil
    package.loaded['mp.msg'] = nil
    package.loaded['mp.utils'] = nil
    package.loaded['helpers'] = nil
    package.loaded['encoder.ffmpeg_exec'] = nil
    package.loaded['utils.filename_factory'] = nil
    package.loaded['encoder.codec_support'] = nil
    package.loaded['utils.logger'] = nil
    package.loaded['platform.init'] = nil

    package.preload['mp'] = function()
        return {
            get_property = function()
                return nil
            end,
            get_property_number = function()
                return 0
            end,
            get_property_bool = function()
                return false
            end,
            osd_message = function()
            end,
            add_timeout = function(_, callback)
                if callback then
                    callback()
                end
            end,
            add_periodic_timer = function(_, callback)
                local timer = {
                    callback = callback,
                    killed = false,
                }
                function timer:kill()
                    self.killed = true
                end
                table.insert(options.periodic_timers, timer)
                return timer
            end,
            abort_async_command = function(async_id)
                table.insert(options.aborted_async_ids, async_id)
            end,
        }
    end

    package.preload['mp.msg'] = function()
        return {
            debug = function()
            end,
            info = function()
            end,
            warn = function()
            end,
            error = function()
            end,
        }
    end

    package.preload['mp.utils'] = function()
        return {
            join_path = function(left, right)
                if not left or left == '' then
                    return right
                end
                if not right or right == '' then
                    return left
                end
                local separator = left:match('\\$') and '' or '\\'
                return left .. separator .. right
            end,
            file_info = function(path)
                if options.file_info then
                    return options.file_info(path)
                end
                return nil
            end,
            parse_json = function()
                if options.ffprobe_result then
                    return options.ffprobe_result
                end
                if options.ffprobe_has_subtitles then
                    return { streams = { { index = 0 } } }
                end
                return nil
            end,
        }
    end

    package.preload['helpers'] = function()
        return {
            is_win = function()
                return options.is_win ~= false
            end,
            is_mac = function()
                return false
            end,
            subprocess = function(args, completion_fn)
                options.last_subprocess_args = args
                if completion_fn then
                    if options.defer_async then
                        table.insert(options.pending_callbacks, completion_fn)
                        return 700 + #options.pending_callbacks
                    end
                    completion_fn(true, { status = 0, stdout = '', stderr = '' })
                end
                return { status = 0, stdout = '', stderr = '' }
            end,
            subprocess_detached = function(_, completion_fn)
                if completion_fn then
                    completion_fn(true, { status = 0, stdout = '', stderr = '' })
                end
                return { status = 0, stdout = '', stderr = '' }
            end,
            human_readable_time_no_ms = function()
                return '0:00'
            end,
            file_exists = function()
                return false
            end,
            safe_file_info = function(path)
                if options.file_info then
                    return options.file_info(path)
                end
                return nil
            end,
            copy_file = function()
                return true
            end,
            is_empty = function(value)
                return value == nil or value == ''
            end,
            parse_shell_like_args = function()
                return {}
            end,
        }
    end

    package.preload['utils.filename_factory'] = function()
        return {
            make_filename_for_media_name = function()
                return 'clip.webm'
            end,
        }
    end

    package.preload['encoder.codec_support'] = function()
        return {
            is_valid_combination = function()
                return true
            end,
        }
    end

    package.preload['utils.logger'] = function()
        return {
            info_cat = function()
            end,
        }
    end

    package.preload['platform.init'] = function()
        return {
            windows = true,
            tmp_dir = function()
                return '.'
            end,
        }
    end

    return require('encoder.encoder')
end

return M