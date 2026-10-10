local M = {}

local function format_value(value)
    if type(value) == 'string' then
        return string.format('%q', value)
    end
    return tostring(value)
end

function M.equals(expected, actual, context)
    if expected ~= actual then
        error((context or 'values differ') .. ': expected ' .. format_value(expected) .. ', got ' .. format_value(actual), 2)
    end
end

function M.truthy(value, context)
    if not value then
        error(context or 'expected a truthy value', 2)
    end
end

function M.falsy(value, context)
    if value then
        error(context or 'expected a falsy value', 2)
    end
end

function M.same(expected, actual, context)
    local function compare(left, right, path)
        if type(left) ~= type(right) then
            error(string.format('%s: expected %s, got %s', path, type(left), type(right)), 0)
        end
        if type(left) ~= 'table' then
            if left ~= right then
                error(string.format('%s: expected %s, got %s', path, format_value(left), format_value(right)), 0)
            end
            return
        end

        for key, value in pairs(left) do
            compare(value, right[key], path .. '.' .. tostring(key))
        end
        for key, _ in pairs(right) do
            if left[key] == nil then
                error(string.format('%s.%s: unexpected key', path, tostring(key)), 0)
            end
        end
    end

    local ok, err = pcall(compare, expected, actual, context or 'table')
    if not ok then
        error(err, 2)
    end
end

return M