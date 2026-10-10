local json = require('tests.support.json')

local M = {}

function M.load(config, responses)
    package.loaded['utils.queue_client'] = nil
    package.loaded['mp'] = nil
    package.loaded['mp.utils'] = nil
    package.loaded['platform.init'] = nil

    local captured = {
        requests = {},
        formatted = {},
    }

    package.preload['mp'] = function()
        return {
            get_property_native = function(name)
                if name == 'pid' then return 42 end
                return nil
            end,
            get_property = function(name)
                if name == 'filename/no-ext' then return 'test-video' end
                return nil
            end,
        }
    end

    package.preload['mp.utils'] = function()
        return {
            format_json = function(value)
                table.insert(captured.formatted, value)
                return '{}'
            end,
            parse_json = function(value)
                local ok, decoded = pcall(json.decode, value)
                return ok and decoded or nil
            end,
        }
    end

    package.preload['platform.init'] = function()
        return {
            http_request = function(options, callback)
                table.insert(captured.requests, options)
                local response = table.remove(responses, 1)
                callback(true, response)
                return #captured.requests
            end,
        }
    end

    local client = require('utils.queue_client')
    client.init(config)
    return client, captured
end

return M