local M = {}

local function decode(text)
    local position = 1

    local function skip_whitespace()
        local _, next_position = text:find('^[ \n\r\t]*', position)
        position = (next_position or (position - 1)) + 1
    end

    local parse_value

    local function parse_string()
        position = position + 1
        local parts = {}

        while position <= #text do
            local current = text:sub(position, position)
            if current == '"' then
                position = position + 1
                return table.concat(parts)
            end
            if current == '\\' then
                local escape = text:sub(position + 1, position + 1)
                local replacements = {
                    ['"'] = '"',
                    ['\\'] = '\\',
                    ['/'] = '/',
                    ['b'] = '\b',
                    ['f'] = '\f',
                    ['n'] = '\n',
                    ['r'] = '\r',
                    ['t'] = '\t',
                }
                if escape == 'u' then
                    local hex = text:sub(position + 2, position + 5)
                    if not hex:match('^%x%x%x%x$') then
                        error('invalid unicode escape at position ' .. tostring(position))
                    end
                    table.insert(parts, utf8.char(tonumber(hex, 16)))
                    position = position + 6
                else
                    if replacements[escape] == nil then
                        error('invalid escape at position ' .. tostring(position))
                    end
                    table.insert(parts, replacements[escape])
                    position = position + 2
                end
            else
                table.insert(parts, current)
                position = position + 1
            end
        end

        error('unterminated string')
    end

    local function parse_number()
        local start_position = position
        local number_text = text:match('^-?%d+%.?%d*[eE]?[+-]?%d*', position)
        if not number_text or number_text == '' or number_text == '-' then
            error('invalid number at position ' .. tostring(position))
        end
        position = start_position + #number_text
        return tonumber(number_text)
    end

    local function parse_array()
        position = position + 1
        skip_whitespace()
        local result = {}
        if text:sub(position, position) == ']' then
            position = position + 1
            return result
        end

        while true do
            result[#result + 1] = parse_value()
            skip_whitespace()
            local current = text:sub(position, position)
            if current == ']' then
                position = position + 1
                return result
            end
            if current ~= ',' then
                error('expected comma in array at position ' .. tostring(position))
            end
            position = position + 1
            skip_whitespace()
        end
    end

    local function parse_object()
        position = position + 1
        skip_whitespace()
        local result = {}
        if text:sub(position, position) == '}' then
            position = position + 1
            return result
        end

        while true do
            if text:sub(position, position) ~= '"' then
                error('expected string key at position ' .. tostring(position))
            end
            local key = parse_string()
            skip_whitespace()
            if text:sub(position, position) ~= ':' then
                error('expected colon at position ' .. tostring(position))
            end
            position = position + 1
            skip_whitespace()
            result[key] = parse_value()
            skip_whitespace()
            local current = text:sub(position, position)
            if current == '}' then
                position = position + 1
                return result
            end
            if current ~= ',' then
                error('expected comma in object at position ' .. tostring(position))
            end
            position = position + 1
            skip_whitespace()
        end
    end

    function parse_value()
        skip_whitespace()
        local current = text:sub(position, position)
        if current == '"' then
            return parse_string()
        end
        if current == '{' then
            return parse_object()
        end
        if current == '[' then
            return parse_array()
        end
        if current == '-' or current:match('%d') then
            return parse_number()
        end
        if text:sub(position, position + 3) == 'true' then
            position = position + 4
            return true
        end
        if text:sub(position, position + 4) == 'false' then
            position = position + 5
            return false
        end
        if text:sub(position, position + 3) == 'null' then
            position = position + 4
            return nil
        end
        error('unexpected token at position ' .. tostring(position))
    end

    local value = parse_value()
    skip_whitespace()
    if position <= #text then
        error('unexpected trailing content at position ' .. tostring(position))
    end
    return value
end

function M.decode(text)
    local ok, value = pcall(decode, text)
    if ok then
        return value
    end
    return nil
end

return M