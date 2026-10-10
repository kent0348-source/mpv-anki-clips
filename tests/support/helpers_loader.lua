local M = {}

function M.load_helpers()
    package.loaded['helpers'] = nil
    package.preload['helpers'] = nil
    package.loaded['mp'] = nil
    package.loaded['mp.msg'] = nil
    package.loaded['mp.utils'] = nil
    package.loaded['utils.logger'] = nil

    package.preload['mp'] = function()
        return {
            get_property = function()
                return nil
            end,
            command_native = function()
                return { status = 0, stdout = '', stderr = '' }
            end,
            command_native_async = function(_, callback)
                if callback then
                    callback(true, { status = 0, stdout = '', stderr = '' })
                end
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
        return {}
    end

    package.preload['utils.logger'] = function()
        return {
            info_cat = function()
            end,
        }
    end

    return require('helpers')
end

return M