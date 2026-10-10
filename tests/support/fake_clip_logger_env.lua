local json = require('tests.support.json')

local M = {}

local function normalize_path(path)
    return tostring(path or ''):gsub('\\', '/')
end

local function join_path(left, right)
    left = normalize_path(left)
    right = normalize_path(right)
    if left == '' then
        return right
    end
    if right == '' then
        return left
    end
    if left:sub(-1) == '/' then
        return left .. right
    end
    return left .. '/' .. right
end

local function dirname(path)
    local normalized = normalize_path(path)
    return normalized:match('^(.*)/[^/]+$') or ''
end

local function is_empty(value)
    return value == nil or value == '' or (type(value) == 'table' and next(value) == nil)
end

function M.new()
    local env = {
        files = {},
        dirs = {},
        warnings = {},
        rename_failures = {},
    }

    function env:ensure_dir(path)
        local normalized = normalize_path(path)
        if normalized == '' then
            return
        end

        local prefix = ''
        for part in normalized:gmatch('[^/]+') do
            prefix = prefix == '' and part or (prefix .. '/' .. part)
            self.dirs[prefix] = true
        end
    end

    function env:write_file(path, contents)
        local normalized = normalize_path(path)
        self:ensure_dir(dirname(normalized))
        self.files[normalized] = contents
    end

    function env:read_file(path)
        return self.files[normalize_path(path)]
    end

    function env:file_exists(path)
        return self.files[normalize_path(path)] ~= nil
    end

    function env:dir_exists(path)
        return self.dirs[normalize_path(path)] == true
    end

    function env:add_rename_failure(predicate)
        table.insert(self.rename_failures, predicate)
    end

    function env:clear_rename_failures()
        self.rename_failures = {}
    end

    function env:set_ffprobe_result(result)
        self.ffprobe_result = result
    end

    function env:file_info(path)
        local normalized = normalize_path(path)
        if self.files[normalized] ~= nil then
            return { size = #self.files[normalized] }
        end
        if self.dirs[normalized] then
            return { is_dir = true }
        end
        return nil
    end

    function env:readdir(path, kind)
        local normalized = normalize_path(path)
        if normalized ~= '' and not self.dirs[normalized] then
            return nil
        end

        local prefix = normalized == '' and '' or (normalized .. '/')
        local names = {}
        local seen = {}

        local function add_child(candidate)
            if prefix ~= '' and candidate:sub(1, #prefix) ~= prefix then
                return
            end
            local remainder = candidate:sub(#prefix + 1)
            if remainder == '' then
                return
            end
            if remainder:find('/', 1, true) then
                local child = remainder:match('^[^/]+')
                if child and not seen[child] then
                    seen[child] = true
                    table.insert(names, child)
                end
                return
            end
            if not seen[remainder] then
                seen[remainder] = true
                table.insert(names, remainder)
            end
        end

        if kind == 'dirs' then
            for candidate, _ in pairs(self.dirs) do
                if candidate ~= normalized then
                    add_child(candidate)
                end
            end
        elseif kind == 'files' then
            for candidate, _ in pairs(self.files) do
                add_child(candidate)
            end
        end

        table.sort(names)
        return names
    end

    function env:io_open(path, mode)
        local normalized = normalize_path(path)
        if mode == 'rb' then
            local contents = self.files[normalized]
            if contents == nil then
                return nil
            end
            return {
                read = function(_, spec)
                    if spec == '*a' then
                        return contents
                    end
                    return nil
                end,
                close = function()
                    return true
                end,
            }
        end

        if mode == 'wb' then
            self:ensure_dir(dirname(normalized))
            local buffer = {}
            return {
                write = function(_, chunk)
                    buffer[#buffer + 1] = chunk
                    return true
                end,
                close = function()
                    self.files[normalized] = table.concat(buffer)
                    return true
                end,
            }
        end

        return nil, 'unsupported mode: ' .. tostring(mode)
    end

    function env:rename(source, destination)
        local normalized_source = normalize_path(source)
        local normalized_destination = normalize_path(destination)

        for _, predicate in ipairs(self.rename_failures) do
            local allowed, error_message = predicate(normalized_source, normalized_destination, self)
            if allowed == false then
                return nil, error_message or 'rename failed'
            end
        end

        if self.files[normalized_source] ~= nil then
            self:ensure_dir(dirname(normalized_destination))
            self.files[normalized_destination] = self.files[normalized_source]
            self.files[normalized_source] = nil
            return true
        end

        if self.dirs[normalized_source] then
            self.dirs[normalized_destination] = true
            self.dirs[normalized_source] = nil
            return true
        end

        return nil, 'source does not exist'
    end

    function env:remove(path)
        local normalized = normalize_path(path)
        if self.files[normalized] ~= nil then
            self.files[normalized] = nil
            return true
        end
        return nil, 'file does not exist'
    end

    function env:install_modules()
        local file_info = function(path)
            return self:file_info(path)
        end

        package.loaded['utils.clip_logger'] = nil
        package.loaded['helpers'] = nil
        package.loaded['mp'] = nil
        package.loaded['mp.msg'] = nil
        package.loaded['mp.utils'] = nil

        package.preload['mp'] = function()
            return {}
        end

        package.preload['mp.msg'] = function()
            return {
                warn = function(message)
                    table.insert(self.warnings, message)
                end,
                info = function()
                end,
                error = function()
                end,
                debug = function()
                end,
            }
        end

        package.preload['mp.utils'] = function()
            return {
                join_path = join_path,
                file_info = file_info,
                readdir = function(path, kind)
                    return self:readdir(path, kind)
                end,
                parse_json = function(text)
                    return json.decode(text)
                end,
            }
        end

        package.preload['helpers'] = function()
            return {
                is_empty = is_empty,
                is_win = function()
                    return false
                end,
                subprocess = function(args)
                    if args[1] == 'mkdir' and args[2] == '-p' then
                        self:ensure_dir(args[3])
                        return { status = 0, stderr = '' }
                    end
                    if args[1] == 'cmd' and args[2] == '/c' and args[3] == 'mkdir' then
                        self:ensure_dir(args[4])
                        return { status = 0, stderr = '' }
                    end
                    if args[1] == 'ffprobe' and self.ffprobe_result then
                        return { status = 0, stdout = self.ffprobe_result, stderr = '' }
                    end
                    return { status = 1, stderr = 'unsupported subprocess' }
                end,
                safe_file_info = function(path)
                    return file_info(path)
                end,
            }
        end
    end

    function env:load_clip_logger()
        self:install_modules()

        local original_io_open = io.open
        local original_rename = os.rename
        local original_remove = os.remove
        local original_date = os.date

        io.open = function(path, mode)
            return self:io_open(path, mode)
        end
        os.rename = function(source, destination)
            return self:rename(source, destination)
        end
        os.remove = function(path)
            return self:remove(path)
        end
        os.date = function(format)
            local overrides = {
                ['%z'] = '+0200',
                ['%Y-%m-%dT%H:%M:%S'] = '2026-04-23T12:34:56',
                ['%Y-%m-%dT%H-%M-%S'] = '2026-04-23T12-34-56',
                ['!%Y-%m'] = '2026-04',
            }
            return overrides[format] or original_date(format)
        end

        local ok, module = pcall(require, 'utils.clip_logger')

        io.open = original_io_open
        os.rename = original_rename
        os.remove = original_remove
        os.date = original_date

        if not ok then
            error(module)
        end

        return module
    end

    function env:with_patched_os(callback)
        local original_io_open = io.open
        local original_rename = os.rename
        local original_remove = os.remove
        local original_date = os.date

        io.open = function(path, mode)
            return self:io_open(path, mode)
        end
        os.rename = function(source, destination)
            return self:rename(source, destination)
        end
        os.remove = function(path)
            return self:remove(path)
        end
        os.date = function(format)
            local overrides = {
                ['%z'] = '+0200',
                ['%Y-%m-%dT%H:%M:%S'] = '2026-04-23T12:34:56',
                ['%Y-%m-%dT%H-%M-%S'] = '2026-04-23T12-34-56',
                ['!%Y-%m'] = '2026-04',
            }
            return overrides[format] or original_date(format)
        end

        local ok, result, extra = pcall(callback)

        io.open = original_io_open
        os.rename = original_rename
        os.remove = original_remove
        os.date = original_date

        if not ok then
            error(result)
        end

        return result, extra
    end

    return env
end

return M