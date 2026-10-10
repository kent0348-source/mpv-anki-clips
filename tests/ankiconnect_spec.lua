local assertx = require('tests.support.assert')
local json = require('tests.support.json')

local function load_client(responses)
    package.loaded['ankiconnect'] = nil
    package.loaded['mp.utils'] = nil
    package.loaded['mp.msg'] = nil
    package.loaded['helpers'] = nil

    local captured = {
        requests = {},
        formatted_requests = {},
        notifications = {},
        warnings = {},
    }

    package.preload['mp.utils'] = function()
        return {
            format_json = function(value)
                table.insert(captured.formatted_requests, value)
                return '{}'
            end,
            parse_json = function(value)
                local ok, decoded = pcall(json.decode, value)
                return ok and decoded or nil
            end,
        }
    end
    package.preload['mp.msg'] = function()
        return {
            error = function(message) table.insert(captured.warnings, message) end,
            info = function() end,
            warn = function(message) table.insert(captured.warnings, message) end,
        }
    end
    package.preload['helpers'] = function()
        return {
            is_empty = function(value)
                return value == nil or value == '' or (type(value) == 'table' and next(value) == nil)
            end,
            notify = function(message, tone)
                table.insert(captured.notifications, { message = message, tone = tone })
            end,
        }
    end

    local platform = {
        curl_request = function(url, _, completion_fn)
            local request = table.remove(captured.formatted_requests, 1)
            table.insert(captured.requests, { url = url, request = request })
            local response = table.remove(responses, 1)
            if type(completion_fn) == 'function' then
                completion_fn(response.status == 0, response)
                return #captured.requests
            end
            return response
        end,
    }

    local client = require('ankiconnect')
    client.init({ ankiconnect_url = '127.0.0.1:8765' }, platform)
    return client, captured
end

local function http_response(body, status)
    return {
        status = 0,
        stdout = body,
        stderr = '',
        http_status = status or 200,
    }
end

local function api_response(result_json)
    return http_response(result_json)
end

local function note_info_response(fields)
    local encoded_fields = {}
    for name, value in pairs(fields) do
        table.insert(encoded_fields, string.format('"%s":{"value":"%s"}', name, value))
    end
    return http_response('{"result":[{"fields":{' .. table.concat(encoded_fields, ',') .. '}}],"error":null}')
end

local function append_and_capture(client, fields, tag)
    local callback_error
    client.append_media(42, fields, tag, function(error)
        callback_error = error
    end)
    return callback_error
end

return {
    {
        name = 'AnkiConnect update succeeds only after read-back matches',
        run = function()
            local client, captured = load_client({
                api_response('{"result":null,"error":null}'),
                note_info_response({ Front = 'new text', Audio = '[sound:clip.mp3]' }),
            })
            local callback_error = append_and_capture(client, {
                Front = 'new text',
                Audio = '[sound:clip.mp3]',
            })

            assertx.equals(nil, callback_error)
            assertx.equals(2, #captured.requests)
            assertx.equals('updateNoteFields', captured.requests[1].request.action)
            assertx.equals('notesInfo', captured.requests[2].request.action)
        end,
    },
    {
        name = 'AnkiConnect update reconciles a lost response without retrying',
        run = function()
            local client, captured = load_client({
                { status = 28, stdout = '', stderr = 'operation timed out' },
                note_info_response({ Front = 'new text' }),
            })
            local callback_error = append_and_capture(client, { Front = 'new text' })

            assertx.equals(nil, callback_error)
            assertx.equals(2, #captured.requests)
            assertx.equals('updateNoteFields', captured.requests[1].request.action)
            assertx.equals('notesInfo', captured.requests[2].request.action)
        end,
    },
    {
        name = 'AnkiConnect update reports mismatched persisted fields',
        run = function()
            local client, captured = load_client({
                api_response('{"result":null,"error":null}'),
                note_info_response({ Front = 'old text' }),
            })
            local callback_error = append_and_capture(client, { Front = 'new text' })

            assertx.truthy(callback_error)
            assertx.truthy(callback_error:find('Front', 1, true))
            assertx.equals(2, #captured.requests)
        end,
    },
    {
        name = 'AnkiConnect update reports API errors when read-back differs',
        run = function()
            local client = load_client({
                api_response('{"result":null,"error":"invalid field"}'),
                note_info_response({ Front = 'old text' }),
            })
            local callback_error = append_and_capture(client, { Front = 'new text' })

            assertx.truthy(callback_error)
            assertx.truthy(callback_error:find('invalid field', 1, true))
            assertx.truthy(callback_error:find('verification failed', 1, true))
        end,
    },
    {
        name = 'AnkiConnect tag failure is surfaced after fields are verified',
        run = function()
            local client, captured = load_client({
                api_response('{"result":null,"error":null}'),
                note_info_response({ Front = 'new text' }),
                api_response('{"result":null,"error":"tag rejected"}'),
            })
            local callback_error = append_and_capture(client, { Front = 'new text' }, 'mpv-test')

            assertx.equals(nil, callback_error)
            assertx.equals(3, #captured.requests)
            assertx.equals('addTags', captured.requests[3].request.action)
            assertx.truthy(#captured.notifications > 0)
            assertx.truthy(captured.notifications[1].message:find('tag rejected', 1, true))
        end,
    },
    {
        name = 'AnkiConnect rejects non-success HTTP statuses',
        run = function()
            local client = load_client({})
            local _, error = client.parse_result(http_response('gateway failure', 503))
            assertx.truthy(error)
            assertx.truthy(error:find('HTTP 503', 1, true))
        end,
    },
    {
        name = 'AnkiConnect note field reads report missing note data',
        run = function()
            local client = load_client({
                api_response('{"result":[],"error":null}'),
            })
            local fields, error = client.get_note_fields(42)

            assertx.equals(nil, fields)
            assertx.truthy(error)
            assertx.truthy(error:find('no fields for note 42', 1, true))
        end,
    },
    {
        name = 'AnkiConnect direct note creation requires verified saved fields',
        run = function()
            local client, captured = load_client({
                api_response('{"result":12345,"error":null}'),
                note_info_response({ Front = 'new note' }),
            })
            local note_id, callback_error, gui_opened
            client.add_note({ Front = 'new note' }, nil, false, nil, function(id, error, opened)
                note_id, callback_error, gui_opened = id, error, opened
            end)

            assertx.equals(12345, note_id)
            assertx.equals(nil, callback_error)
            assertx.falsy(gui_opened)
            assertx.equals(2, #captured.requests)
            assertx.equals('addNote', captured.requests[1].request.action)
            assertx.equals('notesInfo', captured.requests[2].request.action)
        end,
    },
    {
        name = 'AnkiConnect direct note creation does not accept a null note ID as success',
        run = function()
            local client, captured = load_client({
                api_response('{"result":null,"error":null}'),
            })
            local note_id, callback_error
            client.add_note({ Front = 'new note' }, nil, false, nil, function(id, error)
                note_id, callback_error = id, error
            end)

            assertx.equals(nil, note_id)
            assertx.truthy(callback_error)
            assertx.truthy(callback_error:find('Check Anki before retrying', 1, true))
            assertx.equals(1, #captured.requests)
        end,
    },
    {
        name = 'AnkiConnect GUI note creation reports dialog handoff without claiming a saved note',
        run = function()
            local client, captured = load_client({
                api_response('{"result":null,"error":null}'),
            })
            local note_id, callback_error, gui_opened
            client.add_note({ Front = 'new note' }, nil, true, nil, function(id, error, opened)
                note_id, callback_error, gui_opened = id, error, opened
            end)

            assertx.equals(nil, note_id)
            assertx.equals(nil, callback_error)
            assertx.truthy(gui_opened)
            assertx.equals(1, #captured.requests)
            assertx.equals('guiAddCards', captured.requests[1].request.action)
            assertx.truthy(captured.notifications[1].message:find('Save there to add the note', 1, true))
        end,
    },
}
