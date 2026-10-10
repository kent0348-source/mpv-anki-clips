--[[
Copyright: Ren Tatsumoto and contributors
License: GNU GPL, version 3 or later; http://www.gnu.org/licenses/gpl.html

AnkiConnect requests
]]

local utils = require('mp.utils')
local msg = require('mp.msg')
local h = require('helpers')
local self = {}
local verify_note_fields

local function resolve_config(config_override)
    return config_override or self.config
end

self.execute = function(request, completion_fn, config_override)
    -- utils.format_json returns a string
    -- On error, request_json will contain "null", not nil.
    local request_json, error = utils.format_json(request)
    local cfg = resolve_config(config_override)

    if error ~= nil or request_json == nil or request_json == "null" then
        local result = {
            status = -1,
            stdout = '',
            stderr = error or 'AnkiConnect request could not be serialized',
        }
        if type(completion_fn) == 'function' then
            completion_fn(false, result)
            return nil
        end
        return result
    else
        return self.platform.curl_request(cfg.ankiconnect_url, request_json, completion_fn)
    end
end

self.parse_result = function(curl_output)
    if type(curl_output) ~= 'table' then
        return nil, "AnkiConnect returned no response"
    end

    if curl_output.status ~= 0 then
        local detail = curl_output.stderr or curl_output.stdout or ''
        return nil, string.format(
            "AnkiConnect transport failed (curl exit %s)%s",
            tostring(curl_output.status),
            detail ~= '' and ': ' .. detail or ''
        )
    end

    if type(curl_output.http_status) ~= 'number' then
        return nil, "AnkiConnect response did not include an HTTP status"
    end

    if curl_output.http_status < 200 or curl_output.http_status >= 300 then
        local detail = curl_output.stderr or curl_output.stdout or ''
        return nil, string.format(
            "AnkiConnect returned HTTP %d%s",
            curl_output.http_status,
            detail ~= '' and ': ' .. detail or ''
        )
    end

    local stdout_json = utils.parse_json(curl_output.stdout)

    if type(stdout_json) ~= 'table' then
        return nil, "AnkiConnect returned invalid JSON"
    end

    if stdout_json.error ~= nil then
        return nil, tostring(stdout_json.error)
    end

    return stdout_json.result, nil
end

self.get_media_dir_path = function()
    -- Ask AnkiConnect where to store media files.
    -- If AnkiConnect isn't running, returns nil.

    local ret = self.execute({
        action = "getMediaDirPath",
        version = 6,
    })
    local dir_path, error = self.parse_result(ret)
    if not error then
        return dir_path
    else
        msg.error(string.format("Couldn't retrieve path to collection.media folder: %s", error))
        return nil
    end
end

self.create_deck = function(deck_name)
    local args = {
        action = "changeDeck",
        version = 6,
        params = {
            cards = {},
            deck = deck_name
        }
    }
    local result_notify = function(_, result, _)
        local _, error = self.parse_result(result)
        if not error then
            msg.info(string.format("Deck %s: check completed.", deck_name))
        else
            msg.warn(string.format("Deck %s: check failed. Reason: %s.", deck_name, error))
        end
    end
    self.execute(args, result_notify)
end

self.add_note = function(note_fields, tag, gui, config_override, on_finish_fn)
    local action = gui and 'guiAddCards' or 'addNote'
    local cfg = resolve_config(config_override)
    local args = {
        action = action,
        version = 6,
        params = {
            note = {
                deckName = cfg.deck_name,
                modelName = cfg.model_name,
                fields = note_fields,
                options = {
                    allowDuplicate = cfg.allow_duplicates,
                    duplicateScope = "deck",
                },
                tags = h.is_empty(tag) and {} or { tag, },
            }
        }
    }
    local result_notify = function(_, result, _)
        local result_value, error = self.parse_result(result)
        if error then
            h.notify(string.format("Error: %s.", error), "error", 2)
            if type(on_finish_fn) == 'function' then
                on_finish_fn(nil, error, false)
            end
            return
        end

        if gui then
            h.notify("Anki Add Cards window opened. Save there to add the note.", "info", 3)
            if type(on_finish_fn) == 'function' then
                on_finish_fn(nil, nil, true)
            end
            return
        end

        if type(result_value) ~= 'number' or result_value <= 0 then
            local add_error = "AnkiConnect did not return a valid note ID; the add outcome may be unknown. Check Anki before retrying."
            h.notify(string.format("Error: %s.", add_error), "error", 3)
            if type(on_finish_fn) == 'function' then
                on_finish_fn(nil, add_error, false)
            end
            return
        end

        verify_note_fields(result_value, note_fields, cfg, function(verified, verification_error)
            if not verified then
                local add_error = string.format(
                    "Anki returned note ID %s, but the saved fields could not be verified: %s",
                    tostring(result_value),
                    verification_error
                )
                h.notify(string.format("Error: %s.", add_error), "error", 3)
                if type(on_finish_fn) == 'function' then
                    on_finish_fn(result_value, add_error, false)
                end
                return
            end

            h.notify(string.format("Note added and verified. ID = %s.", result_value))
            if type(on_finish_fn) == 'function' then
                on_finish_fn(result_value, nil, false)
            end
        end)
    end
    self.execute(args, result_notify, cfg)
end

self.get_last_note_ids = function(n_cards)
    local ret = self.execute {
        action = "findNotes",
        version = 6,
        params = {
            query = "added:1" -- find all notes added today
        }
    }

    local note_ids, _ = self.parse_result(ret)

    if not h.is_empty(note_ids) then
        return h.get_last_n_added_notes(note_ids, n_cards)
    else
        return {}
    end
end

self.get_selected_note_ids = function()
    local ret = self.execute {
        action = "guiSelectedNotes",
        version = 6
    }

    local note_ids, _ = self.parse_result(ret)
    return note_ids
end

local function parse_note_fields(note_id, response)
    local result, error = self.parse_result(response)
    if error then
        return nil, error
    end

    local note_info = type(result) == 'table' and result[1] or nil
    if type(note_info) ~= 'table' or type(note_info.fields) ~= 'table' then
        return nil, string.format("AnkiConnect returned no fields for note %s", tostring(note_id))
    end

    local fields = {}
    for name, field in pairs(note_info.fields) do
        if type(field) ~= 'table' or type(field.value) ~= 'string' then
            return nil, string.format("AnkiConnect returned an invalid value for field %s", tostring(name))
        end
        fields[name] = field.value
    end
    return fields, nil
end

local function request_note_fields(note_id, completion_fn, config_override)
    local request = {
        action = "notesInfo",
        version = 6,
        params = {
            notes = { note_id }
        }
    }

    if type(completion_fn) == 'function' then
        return self.execute(request, function(_, response)
            completion_fn(parse_note_fields(note_id, response))
        end, config_override)
    end

    return parse_note_fields(note_id, self.execute(request, nil, config_override))
end

self.get_note_fields = function(note_id)
    return request_note_fields(note_id)
end

verify_note_fields = function(note_id, expected_fields, config_override, completion_fn)
    request_note_fields(note_id, function(actual_fields, error)
        if error then
            completion_fn(false, string.format("Could not verify note %s: %s", tostring(note_id), error))
            return
        end

        local mismatches = {}
        for field_name, expected_value in pairs(expected_fields) do
            if actual_fields[field_name] ~= expected_value then
                table.insert(mismatches, tostring(field_name))
            end
        end
        if #mismatches > 0 then
            completion_fn(false, string.format(
                "Field verification failed for note %s (mismatched fields: %s)",
                tostring(note_id),
                table.concat(mismatches, ', ')
            ))
            return
        end
        completion_fn(true, nil)
    end, config_override)
end

self.get_first_field = function(model_name)
    local ret = self.execute {
        action = "findModelsByName",
        version = 6,
        params = {
            modelNames = { model_name }
        }
    }

    local result, error = self.parse_result(ret)

    if error == nil then
        for _, field in pairs(result[1].flds) do
            if field.ord == 0 then
                return field.name
            end
        end
    else
        msg.error(string.format("Couldn't retrieve the first field's name of note type %s: %s", model_name, error))
        return nil
    end
end

self.get_sort_field = function(model_name)
    local ret = self.execute {
        action = "findModelsByName",
        version = 6,
        params = {
            modelNames = { model_name }
        }
    }

    local result, error = self.parse_result(ret)
    local model = not error and result and result[1] or nil
    if model and model.flds and model.sortf ~= nil then
        for _, field in pairs(model.flds) do
            if field.ord == model.sortf then
                return field.name
            end
        end
    end

    ret = self.execute {
        action = "modelFieldNames",
        version = 6,
        params = {
            modelName = model_name
        }
    }

    result, error = self.parse_result(ret)

    if error == nil and #result > 0 then
        return result[1]
    else
        msg.error(string.format("Couldn't retrieve sort field of note type %s: %s", model_name, error))
        return nil
    end
end

self.gui_browse = function(query, config_override)
    local cfg = resolve_config(config_override)
    if not cfg.disable_gui_browse then
        self.execute({
            action = 'guiBrowse',
            version = 6,
            params = {
                query = query
            }
        }, nil, cfg)
    end
end

self.add_tag = function(note_id, tag, completion_fn, config_override)
    if not h.is_empty(tag) then
        local args = {
            action = 'addTags',
            version = 6,
            params = {
                notes = { note_id },
                tags = tag
            }
        }
        self.execute(args, function(_, result)
            local _, error = self.parse_result(result)
            if error and type(completion_fn) ~= 'function' then
                msg.warn(string.format("Couldn't add tag to note %s: %s", tostring(note_id), error))
            end
            if type(completion_fn) == 'function' then
                completion_fn(error)
            end
        end, config_override)
    elseif type(completion_fn) == 'function' then
        completion_fn(nil)
    end
end

self.append_media = function(note_id, fields, tag, on_finish_fn, config_override)
    local cfg = resolve_config(config_override)
    if type(fields) ~= 'table' then
        local error = "Fields to update must be a table"
        h.notify(string.format("Error: %s.", error), "error", 2)
        if type(on_finish_fn) == 'function' then
            on_finish_fn(error)
        end
        return
    end

    local expected_fields = {}
    for field_name, value in pairs(fields) do
        expected_fields[field_name] = value
    end

    local args = {
        action = "updateNoteFields",
        version = 6,
        params = {
            note = {
                id = note_id,
                fields = expected_fields,
            }
        }
    }

    local function finish(error)
        if type(on_finish_fn) == 'function' then
            on_finish_fn(error)
        end
    end

    self.execute(args, function(_, result)
        local _, update_error = self.parse_result(result)
        verify_note_fields(note_id, expected_fields, cfg, function(verified, verification_error)
            if not verified then
                local errors = {}
                if update_error then
                    table.insert(errors, "update request: " .. update_error)
                end
                table.insert(errors, verification_error)
                local error = table.concat(errors, "; ")
                h.notify(string.format("Error: %s.", error), "error", 2)
                finish(error)
                return
            end

            if update_error then
                msg.warn(string.format(
                    "AnkiConnect reported an update error for note %s, but read-back verified the requested fields: %s",
                    tostring(note_id),
                    update_error
                ))
            end

            self.add_tag(note_id, tag, function(tag_error)
                if tag_error then
                    h.notify(string.format(
                        "Fields were verified, but the tag could not be added: %s.",
                        tag_error
                    ), "warn", 3)
                end
                finish(nil)
            end, cfg)
        end)
    end, cfg)
end

self.init = function(config, platform)
    self.config = config
    self.platform = platform
end

return self
