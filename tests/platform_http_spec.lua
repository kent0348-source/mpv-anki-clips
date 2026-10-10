local assertx = require('tests.support.assert')

local function load_platform(module_name, response)
    package.loaded['mp'] = nil
    package.loaded['mp.utils'] = nil
    package.loaded['helpers'] = nil
    package.loaded['utils.base64'] = nil
    package.loaded[module_name] = nil

    local captured = {}

    package.preload['mp'] = function()
        return {
            register_event = function() end,
            msg = { debug = function() end },
        }
    end
    package.preload['mp.utils'] = function()
        return { join_path = function(left, right) return left .. '/' .. right end }
    end
    package.preload['utils.base64'] = function()
        return {}
    end
    package.preload['helpers'] = function()
        return {
            is_mac = function() return false end,
            is_wayland = function() return false end,
            subprocess = function(args, completion_fn, settings)
                captured.args = args
                captured.settings = settings
                captured.has_callback = type(completion_fn) == 'function'
                if completion_fn then
                    completion_fn(true, response)
                    return 'async-request-id'
                end
                return response
            end,
        }
    end

    return require(module_name), captured
end

local function response()
    return { status = 0, stdout = '{"ok":true}\n200', stderr = '' }
end

local function assert_sync_request(module_name)
    local platform, captured = load_platform(module_name, response())
    local result = platform.http_request({ url = 'http://localhost/test' })

    assertx.equals(0, result.status)
    assertx.equals('{"ok":true}', result.stdout)
    assertx.equals(200, result.http_status)
    assertx.falsy(captured.has_callback)
end

local function assert_async_request(module_name)
    local platform, captured = load_platform(module_name, response())
    local callback_result
    local request_id = platform.http_request({ url = 'http://localhost/test' }, function(_, result)
        callback_result = result
    end)

    assertx.equals('async-request-id', request_id)
    assertx.equals('{"ok":true}', callback_result.stdout)
    assertx.equals(200, callback_result.http_status)
    assertx.truthy(captured.has_callback)
end

return {
    {
        name = 'platform HTTP requests return a result without a callback',
        run = function()
            assert_sync_request('platform.win')
            assert_sync_request('platform.nix')
        end,
    },
    {
        name = 'platform HTTP requests use callbacks when supplied',
        run = function()
            assert_async_request('platform.win')
            assert_async_request('platform.nix')
        end,
    },
}