--[[
Copyright: Ren Tatsumoto and contributors
License: GNU GPL, version 3 or later; http://www.gnu.org/licenses/gpl.html

Subtitle list remembers selected subtitle lines.
]]

local h = require('helpers')

local new_sub_list = function()
    local subs_list = {}

    local find_i = function(sub)
        for i, v in ipairs(subs_list) do
            if sub < v then
                return i
            end
        end
        return #subs_list + 1
    end
    local get_time = function(position)
        local i = position == 'start' and 1 or #subs_list
        return subs_list[i][position]
    end
    local get_text = function(remove_arrows_mode)
        local speech = {}
        local i = 1
        while i <= #subs_list do
            local sub = subs_list[i]
            local text = sub['text']
            if (remove_arrows_mode == "join_arrow" or remove_arrows_mode == "join") and i < #subs_list and h.has_arrow(text) then
                -- Join with the next subtitle entry, preserving internal newlines
                local next_sub = subs_list[i + 1]
                local cleaned_text = text:gsub("➡%s*$", ""):gsub("→%s*$", "")
                -- Check if the cleaned text ends with a Japanese period (。) or comma (、)
                local separator = (cleaned_text:match("。$") or cleaned_text:match("、$")) and "" or "　"
                text = cleaned_text .. separator .. next_sub['text']
                i = i + 2 -- Skip the next subtitle
            else
                i = i + 1
            end
            table.insert(speech, text)
        end
        return table.concat(speech, '\n')
    end
    local get_n_text = function(sub, n_lines, remove_arrows_mode)
        local speech = {}
        local end_sub = sub
        local count = 0
        local i = 1
        while i <= #subs_list and count < n_lines do
            local v = subs_list[i]
            if v['start'] - end_sub['end'] >= 20 then
                break
            end
            if v >= sub and count < n_lines then
                local text = v['text']
                if (remove_arrows_mode == "join_arrow" or remove_arrows_mode == "join") and i < #subs_list and h.has_arrow(text) and count + 1 < n_lines then
                    -- Join with the next subtitle entry, preserving internal newlines
                    local next_sub = subs_list[i + 1]
                    local cleaned_text = text:gsub("➡%s*$", ""):gsub("→%s*$", "")
                    -- Check if the cleaned text ends with a Japanese period (。) or comma (、)
                    local separator = (cleaned_text:match("。$") or cleaned_text:match("、$")) and "" or "　"
                    text = cleaned_text .. separator .. next_sub['text']
                    i = i + 2 -- Skip the next subtitle
                    count = count + 1
                else
                    i = i + 1
                    count = count + 1
                end
                table.insert(speech, text)
                end_sub = v
            else
                i = i + 1
            end
        end
        return table.concat(speech, '\n'), end_sub
    end
    local insert = function(sub)
        if sub ~= nil and not h.contains(subs_list, sub) then
            table.insert(subs_list, find_i(sub), sub)
            return true
        end
        return false
    end
    local remove = function(sub)
        if sub == nil then
            return false
        end
        for i, v in ipairs(subs_list) do
            if v == sub then
                table.remove(subs_list, i)
                return true
            end
        end
        return false
    end
    local get_subs_list = function()
        local copy = {}
        for key, value in pairs(subs_list) do
            copy[key] = value
        end
        return copy
    end
    return {
        get_subs_list = get_subs_list,
        get_time = get_time,
        get_text = get_text,
        get_n_text = get_n_text,
        insert = insert,
        remove = remove,
        is_empty = function()
            return h.is_empty(subs_list)
        end,
    }
end

return {
    new = new_sub_list,
}