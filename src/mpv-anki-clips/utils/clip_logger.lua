local mp = require('mp')
local msg = require('mp.msg')
local utils = require('mp.utils')
local h = require('helpers')

local self = {}

local SCHEMA_VERSION = 4
local LOG_TYPE = 'mpv_anki_clips'
local INDEX_FILENAME = 'index.json'
local RECORDS_DIRNAME = 'records'

local MEDIA_TRACK_LABELS = {
    video = 'video',
    audio = 'audio',
    subtitle = 'subtitle',
    attachment = 'attachment',
    data = 'data',
}
local MEDIA_TRACK_ORDER = { 'video', 'audio', 'subtitle', 'attachment', 'data' }

local function is_array(value)
    if type(value) ~= 'table' then
        return false
    end

    local count = 0
    local max_index = 0
    for key, _ in pairs(value) do
        if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then
            return false
        end
        if key > max_index then
            max_index = key
        end
        count = count + 1
    end

    return max_index == count
end

local function escape_json_string(value)
    local replacements = {
        ['\\'] = '\\\\',
        ['\"'] = '\\\"',
        ['\b'] = '\\b',
        ['\f'] = '\\f',
        ['\n'] = '\\n',
        ['\r'] = '\\r',
        ['\t'] = '\\t',
    }

    return (tostring(value):gsub('[\\\"\b\f\n\r\t]', replacements))
end

local function sorted_keys(tbl)
    local keys = {}
    for key, _ in pairs(tbl) do
        table.insert(keys, key)
    end
    table.sort(keys, function(left, right)
        if type(left) == type(right) then
            return left < right
        end
        return tostring(type(left)) < tostring(type(right))
    end)
    return keys
end

local function to_pretty_json(value, indent)
    indent = indent or 0
    local value_type = type(value)

    if value_type == 'nil' then
        return 'null'
    end
    if value_type == 'boolean' then
        return value and 'true' or 'false'
    end
    if value_type == 'number' then
        return tostring(value)
    end
    if value_type == 'string' then
        return '"' .. escape_json_string(value) .. '"'
    end
    if value_type ~= 'table' then
        return '"' .. escape_json_string(tostring(value)) .. '"'
    end

    local next_indent = indent + 2
    local prefix = string.rep(' ', indent)
    local child_prefix = string.rep(' ', next_indent)

    if is_array(value) then
        if #value == 0 then
            return '[]'
        end

        local lines = { '[' }
        for index, item in ipairs(value) do
            local suffix = index < #value and ',' or ''
            table.insert(lines, child_prefix .. to_pretty_json(item, next_indent) .. suffix)
        end
        table.insert(lines, prefix .. ']')
        return table.concat(lines, '\n')
    end

    local keys = sorted_keys(value)
    if #keys == 0 then
        return '{}'
    end

    local lines = { '{' }
    for index, key in ipairs(keys) do
        local suffix = index < #keys and ',' or ''
        table.insert(
            lines,
            child_prefix .. '"' .. escape_json_string(key) .. '": ' .. to_pretty_json(value[key], next_indent) .. suffix
        )
    end
    table.insert(lines, prefix .. '}')
    return table.concat(lines, '\n')
end

local function read_all(path)
    local handle = io.open(path, 'rb')
    if not handle then
        return nil
    end

    local contents = handle:read('*a')
    handle:close()
    return contents
end

local function path_exists(path)
    return not h.is_empty(path) and utils.file_info(path) ~= nil
end

local function replacement_backup_path(path)
    return path .. '.bak'
end

local function restore_replacement_backup(path)
    local backup_path = replacement_backup_path(path)
    if path_exists(path) or not path_exists(backup_path) then
        return false
    end

    return os.rename(backup_path, path)
end

local function safe_write(path, contents)
    local temp_path = path .. '.tmp'
    local backup_path = replacement_backup_path(path)
    local handle, open_error = io.open(temp_path, 'wb')
    if not handle then
        return false, open_error
    end

    local ok, write_error = pcall(handle.write, handle, contents)
    handle:close()
    if not ok then
        os.remove(temp_path)
        return false, write_error
    end

    local had_original = path_exists(path)
    if path_exists(backup_path) then
        if had_original then
            os.remove(backup_path)
            if path_exists(backup_path) then
                os.remove(temp_path)
                return false, 'failed to clear stale backup file'
            end
        else
            local restored, restore_error = restore_replacement_backup(path)
            if not restored then
                os.remove(temp_path)
                return false, restore_error or 'failed to restore interrupted write backup'
            end
            had_original = true
        end
    end

    if had_original then
        local backed_up, backup_error = os.rename(path, backup_path)
        if not backed_up then
            os.remove(temp_path)
            return false, backup_error
        end
    end

    local renamed, rename_error = os.rename(temp_path, path)
    if not renamed then
        os.remove(temp_path)
        if had_original then
            local restored, restore_error = os.rename(backup_path, path)
            if not restored then
                return false, string.format(
                    'failed to replace file: %s (restore failed: %s)',
                    tostring(rename_error),
                    tostring(restore_error)
                )
            end
        end
        return false, rename_error
    end

    if had_original and path_exists(backup_path) then
        os.remove(backup_path)
    end

    return true
end

local function ensure_directory_exists(path)
    if h.is_empty(path) then
        return false, 'empty path'
    end

    if h.is_win() then
        path = path:gsub('/', '\\')
    end

    local info = utils.file_info(path)
    if info and info.is_dir then
        return true
    end

    local result
    if h.is_win() then
        result = h.subprocess({ 'cmd', '/c', 'mkdir', path }, nil, { log_command = false })
    else
        result = h.subprocess({ 'mkdir', '-p', path }, nil, { log_command = false })
    end

    if not result or result.status ~= 0 then
        return false, result and result.stderr or 'mkdir failed'
    end

    info = utils.file_info(path)
    if info and info.is_dir then
        return true
    end

    return false, 'directory was not created'
end

local function remove_file(path)
    if h.is_empty(path) then
        return
    end
    pcall(os.remove, path)
end

local function sanitize_filename_component(value)
    value = tostring(value or '')
    value = value:gsub('[^%w%-%._]+', '_')
    value = value:gsub('_+', '_')
    value = value:gsub('^_+', '')
    value = value:gsub('_+$', '')
    if value == '' then
        return 'clip'
    end
    return value
end

local function normalize_overlap_percent(value)
    value = tonumber(value)
    if not value then
        return 90
    end
    if value < 0 then
        return 0
    end
    if value > 100 then
        return 100
    end
    return value
end

local function bytes_to_mib(bytes)
    local size = tonumber(bytes)
    if not size then
        return nil
    end
    return size / (1024 * 1024)
end

local function local_timezone_offsets()
    local compact_offset = os.date('%z')
    if type(compact_offset) == 'string' and #compact_offset == 5 then
        local display_offset = compact_offset:sub(1, 3) .. ':' .. compact_offset:sub(4, 5)
        return display_offset, compact_offset
    end
    return nil, nil
end

local function local_created_at_timestamp()
    local timestamp = os.date('%Y-%m-%dT%H:%M:%S')
    local display_offset = local_timezone_offsets()
    if display_offset then
        return timestamp .. display_offset
    end
    return timestamp
end

local function local_record_timestamp()
    local timestamp = os.date('%Y-%m-%dT%H-%M-%S')
    local display_offset = local_timezone_offsets()
    if display_offset then
        return timestamp .. display_offset:gsub(':', '-')
    end
    return timestamp
end

local function milliseconds_stamp(seconds)
    local value = tonumber(seconds) or 0
    return tostring(math.floor((value * 1000) + 0.5))
end

local function clip_overlap_seconds(first, second)
    local start_time = math.max(first.start_time, second.start_time)
    local end_time = math.min(first.end_time, second.end_time)
    return math.max(0, end_time - start_time)
end

local function overlap_ratio_percent(overlap_seconds, duration_seconds)
    if not duration_seconds or duration_seconds <= 0 then
        return 0
    end
    return (overlap_seconds / duration_seconds) * 100
end

local function is_duplicate_summary(existing, candidate, overlap_percent)
    if not existing or not candidate then
        return false
    end

    local function normalize_source_path(path)
        path = tostring(path or ''):gsub('/', '\\')
        if h.is_win() then
            path = path:lower()
        end
        return path
    end

    local existing_source_path = normalize_source_path(existing.source_path or ((existing.source or {}).path) or '')
    local candidate_source_path = normalize_source_path(candidate.source_path or ((candidate.source or {}).path) or '')
    if existing_source_path ~= candidate_source_path then
        return false
    end

    local existing_range = {
        start_time = tonumber(existing.clip_start_seconds) or 0,
        end_time = tonumber(existing.clip_end_seconds) or 0,
    }
    local candidate_range = {
        start_time = tonumber(candidate.clip.start_time) or 0,
        end_time = tonumber(candidate.clip.end_time) or 0,
    }

    local existing_duration = existing_range.end_time - existing_range.start_time
    local candidate_duration = candidate_range.end_time - candidate_range.start_time
    if existing_duration <= 0 or candidate_duration <= 0 then
        return math.abs(existing_range.start_time - candidate_range.start_time) < 0.001
            and math.abs(existing_range.end_time - candidate_range.end_time) < 0.001
    end

    local overlap_seconds = clip_overlap_seconds(existing_range, candidate_range)
    if overlap_seconds <= 0 then
        return false
    end

    local existing_overlap = overlap_ratio_percent(overlap_seconds, existing_duration)
    local candidate_overlap = overlap_ratio_percent(overlap_seconds, candidate_duration)
    return existing_overlap >= overlap_percent or candidate_overlap >= overlap_percent
end

local function build_export_fields(job, note_fields)
    local active_fields = job.active_fields or {}
    local text_export_effective = job.subtitles_export_disabled ~= true
        and (job.text_source_kind == 'subtitles' or job.text_source_kind == 'clipboard')

    local fields = {}
    if note_fields and type(note_fields) == 'table' then
        if text_export_effective and not h.is_empty(active_fields.sentence_field) then
            fields.sentence = {
                name = active_fields.sentence_field,
                value = note_fields[active_fields.sentence_field] or '',
            }
        end
        if text_export_effective and not h.is_empty(active_fields.secondary_field) then
            fields.secondary = {
                name = active_fields.secondary_field,
                value = note_fields[active_fields.secondary_field] or '',
            }
        end
        if not h.is_empty(active_fields.video_field) and note_fields[active_fields.video_field] ~= nil then
            fields.video = {
                name = active_fields.video_field,
                value = note_fields[active_fields.video_field],
            }
        end
        if not h.is_empty(active_fields.miscinfo_field) and note_fields[active_fields.miscinfo_field] ~= nil then
            fields.miscinfo = {
                name = active_fields.miscinfo_field,
                value = note_fields[active_fields.miscinfo_field],
            }
        end
    end

    return fields
end

local function build_loudnorm_record(cfg, encode_details)
    local loudnorm = encode_details and encode_details.loudnorm or nil
    if loudnorm then
        return loudnorm
    end

    return {
        target = {
            enabled = cfg.loudnorm_enabled == 'yes',
            i = cfg.loudnorm_I,
            lra = cfg.loudnorm_LRA,
            tp = cfg.loudnorm_TP,
            linear = cfg.loudnorm_enabled == 'yes' and (cfg.loudnorm_linear == 'yes') or nil,
        },
        analyzed = nil,
        warnings = nil,
    }
end

local function build_commands_record(cfg, encode_details)
    local function command_to_list(command)
        if type(command) == 'table' then
            local values = {}
            for _, value in ipairs(command) do
                table.insert(values, tostring(value))
            end
            return values
        end
        if command ~= nil and tostring(command) ~= '' then
            return { tostring(command) }
        end
        return nil
    end

    local commands = {}
    if encode_details and encode_details.commands and encode_details.commands.encode_command then
        commands.encode_command = command_to_list(encode_details.commands.encode_command)
    end
    if cfg.clip_log_advanced_encode_logging == true then
        if encode_details and encode_details.commands and encode_details.commands.loudnorm_measure_command then
            commands.loudnorm_measure_command = command_to_list(encode_details.commands.loudnorm_measure_command)
        end
    end
    return commands
end

local function build_result_record(extra)
    local result = (extra or {}).result or {}
    local replaced_existing_output = result.replaced_existing_output == true
    local previous_output_size_bytes = tonumber(result.previous_output_size_bytes)

    return {
        error = nil,
        final_output_duration_seconds = tonumber(result.final_output_duration_seconds),
        previous_output_size_bytes = previous_output_size_bytes,
        replaced_existing_output = replaced_existing_output,
        encode_output = nil,
        measure_output = nil,
    }
end

local function parse_frame_rate(value)
    local text = tostring(value or '')
    if text == '' or text == '0/0' then
        return nil
    end
    local numerator, denominator = text:match('^([^/]+)/([^/]+)$')
    if numerator then
        numerator = tonumber(numerator)
        denominator = tonumber(denominator)
        return denominator and denominator ~= 0 and numerator / denominator or nil
    end
    return tonumber(text)
end

local function round(value, decimals)
    local factor = 10 ^ decimals
    return math.floor(value * factor + 0.5) / factor
end

local function probe_media_tracks(output_path)
    if h.is_empty(output_path) or not h.safe_file_info(output_path) then
        return nil
    end

    local result = h.subprocess({
        'ffprobe', '-v', 'error',
        '-show_entries', 'stream=codec_type,codec_name,width,height,r_frame_rate,bit_rate,sample_rate,channels,channel_layout:stream_tags=language',
        '-of', 'json', output_path,
    }, nil, { log_command = false })
    if not result or result.status ~= 0 then
        return nil
    end

    local payload = utils.parse_json(result.stdout or '')
    if type(payload) ~= 'table' or type(payload.streams) ~= 'table' then
        return nil
    end

    local tracks = {}
    for _, stream in ipairs(payload.streams) do
        if type(stream) == 'table' then
            local track_type = tostring(stream.codec_type or 'unknown')
            local track = { type = track_type, codec = stream.codec_name }
            local bitrate = tonumber(stream.bit_rate)
            if bitrate and bitrate > 0 then
                track.bitrate_kbps = math.floor((bitrate / 1000) + 0.5)
            end

            if track_type == 'video' then
                if stream.width and stream.height then
                    track.resolution = tostring(stream.width) .. 'x' .. tostring(stream.height)
                end
                local fps = parse_frame_rate(stream.r_frame_rate)
                if fps then
                    track.fps = round(fps, 2)
                end
            elseif track_type == 'audio' then
                track.sample_rate_hz = tonumber(stream.sample_rate)
                track.channel_layout = stream.channel_layout
                if h.is_empty(track.channel_layout) and stream.channels then
                    track.channel_layout = tostring(stream.channels) .. 'ch'
                end
            elseif track_type == 'subtitle' then
                local language = ((stream.tags or {}).language or ''):lower()
                if language ~= '' and language ~= 'und' then
                    track.language = language
                end
            end
            table.insert(tracks, track)
        end
    end
    return tracks
end

local function format_media_track_summary(tracks)
    if type(tracks) ~= 'table' or #tracks == 0 then
        return nil
    end

    local groups = {}
    for _, track in ipairs(tracks) do
        local track_type = track.type or 'unknown'
        groups[track_type] = groups[track_type] or {}
        table.insert(groups[track_type], track)
    end

    local ordered_types = {}
    for _, track_type in ipairs(MEDIA_TRACK_ORDER) do
        if groups[track_type] then
            table.insert(ordered_types, track_type)
        end
    end
    local unknown_types = {}
    for track_type, _ in pairs(groups) do
        if not MEDIA_TRACK_LABELS[track_type] then
            table.insert(unknown_types, track_type)
        end
    end
    table.sort(unknown_types)
    for _, track_type in ipairs(unknown_types) do
        table.insert(ordered_types, track_type)
    end

    local parts = {}
    for _, track_type in ipairs(ordered_types) do
        local details = {}
        for _, track in ipairs(groups[track_type]) do
            local values = {}
            for _, key in ipairs({ 'codec', 'resolution' }) do
                if track[key] then
                    table.insert(values, tostring(track[key]))
                end
            end
            if track.fps then table.insert(values, tostring(track.fps) .. 'fps') end
            if track.sample_rate_hz then table.insert(values, tostring(track.sample_rate_hz) .. 'Hz') end
            if track.channel_layout then table.insert(values, tostring(track.channel_layout)) end
            if track.bitrate_kbps then table.insert(values, tostring(track.bitrate_kbps) .. 'kbps') end
            if track.language then table.insert(values, tostring(track.language)) end
            if #values > 0 then table.insert(details, table.concat(values, ', ')) end
        end
        local label = MEDIA_TRACK_LABELS[track_type] or track_type
        if #details > 0 then
            table.insert(parts, tostring(#groups[track_type]) .. ' ' .. label .. ' (' .. table.concat(details, '; ') .. ')')
        else
            table.insert(parts, tostring(#groups[track_type]) .. ' ' .. label)
        end
    end
    return table.concat(parts, ', ')
end

local function build_anki_sort_field_details(job, extra)
    local details = extra or {}
    return details.note_sort_field_name or job.note_sort_field_name or '',
        details.note_sort_field_value or job.note_sort_field_value or ''
end

local function build_record(job, runtime_sub, output_path, note_fields, extra)
    local cfg = job.config or {}
    local encode_details = (extra or {}).encode or nil
    local source_path = ((job.media_snapshot or {}).source_path)
        or ((job.captured or {}).media_path)
        or ''
    local source_name = source_path:match('[^/\\]+$') or 'clip'
    local clip_start = tonumber((runtime_sub or {}).start) or tonumber((job.sub or {}).start) or 0
    local clip_end = tonumber((runtime_sub or {})['end']) or tonumber((job.sub or {})['end']) or 0
    local created_at = local_created_at_timestamp()
    local timestamp = local_record_timestamp()
    local record_id = table.concat({
        timestamp,
        sanitize_filename_component(source_name),
        milliseconds_stamp(clip_start),
        milliseconds_stamp(clip_end),
    }, '_')
    local source_file_info = h.safe_file_info(source_path)
    local output_file_info = h.safe_file_info(output_path)
    local output_media_tracks = probe_media_tracks(output_path)
    local export_fields = build_export_fields(job, note_fields)
    local note_ids = (extra and extra.note_ids) or job.note_ids or {}
    local note_sort_field_name, note_sort_field_value = build_anki_sort_field_details(job, extra)
    local result_record = build_result_record(extra)

    return {
        schema_version = SCHEMA_VERSION,
        log_type = LOG_TYPE,
        record_id = record_id,
        created_at = created_at,
        job = {
            kind = job.kind,
            profile_name = job.profile_name,
            target_summary = job.target_summary,
            active_field_set_index = job.active_field_set_index,
            update_mode = job.update_mode,
            field_population_state = job.field_population_state,
        },
        source = {
            path = source_path,
            size_bytes = source_file_info and source_file_info.size or nil,
            media_title = (job.captured or {}).media_title,
            media_dir = (job.captured or {}).media_dir,
            working_directory = (job.media_snapshot or {}).working_directory,
        },
        clip = {
            start_time = clip_start,
            end_time = clip_end,
        },
        output = {
            path = output_path,
            size_bytes = output_file_info and output_file_info.size or nil,
            media_tracks = output_media_tracks,
        },
        result = result_record,
        commands = build_commands_record(cfg, encode_details),
        loudnorm = build_loudnorm_record(cfg, encode_details),
        export = {
            subtitles_export_disabled = job.subtitles_export_disabled == true,
            text_source_kind = job.text_source_kind or 'none',
            fields = export_fields,
        },
        anki = {
            deck_name = cfg.deck_name,
            model_name = cfg.model_name,
            note_ids = note_ids,
            added_note_id = extra and extra.added_note_id or nil,
            note_sort_field_name = note_sort_field_name,
            note_sort_field_value = note_sort_field_value,
        },
        replaced_duplicate_record_ids = {},
    }
end

local function build_summary(record, record_relative_path)
    return {
        log_type = record.log_type or '',
        record_id = record.record_id,
        created_at = record.created_at,
        source_path = (record.source or {}).path or '',
        clip_start_seconds = ((record.clip or {}).start_time) or 0,
        clip_end_seconds = ((record.clip or {}).end_time) or 0,
        output_path = ((record.output or {}).path) or '',
        job_kind = ((record.job or {}).kind) or '',
        target_summary = ((record.job or {}).target_summary) or '',
        record_path = record_relative_path,
    }
end

local function sort_records_descending(records)
    table.sort(records, function(left, right)
        local left_created = tostring(left.created_at or '')
        local right_created = tostring(right.created_at or '')
        if left_created ~= right_created then
            return left_created > right_created
        end

        return tostring(left.record_id or '') > tostring(right.record_id or '')
    end)
end

local function malformed_index_backup_path(index_path)
    local timestamp = local_record_timestamp():gsub(':', '-')
    return index_path .. '.malformed-' .. timestamp .. '.bak'
end

local function backup_malformed_index(index_path)
    local backup_path = malformed_index_backup_path(index_path)
    local renamed = os.rename(index_path, backup_path)
    if renamed then
        return backup_path
    end
    return nil
end

local function recover_index_from_records(base_dir)
    local records = {}
    local latest_created_at = nil
    local records_dir = utils.join_path(base_dir, RECORDS_DIRNAME)
    local month_dirs = utils.readdir(records_dir, 'dirs') or {}

    table.sort(month_dirs, function(left, right)
        return tostring(left) > tostring(right)
    end)

    for _, month_dir in ipairs(month_dirs) do
        local month_path = utils.join_path(records_dir, month_dir)
        local record_files = utils.readdir(month_path, 'files') or {}

        table.sort(record_files, function(left, right)
            return tostring(left) > tostring(right)
        end)

        for _, filename in ipairs(record_files) do
            if filename:match('%.json$') then
                local relative_path = utils.join_path(utils.join_path(RECORDS_DIRNAME, month_dir), filename)
                local absolute_path = utils.join_path(month_path, filename)
                local contents = read_all(absolute_path)
                local decoded = contents and utils.parse_json(contents) or nil

                if type(decoded) == 'table' then
                    table.insert(records, build_summary(decoded, relative_path))

                    local created_at = decoded.created_at
                    if type(created_at) == 'string' and (latest_created_at == nil or created_at > latest_created_at) then
                        latest_created_at = created_at
                    end
                else
                    msg.warn('clip_logger: skipping invalid record file during index recovery: ' .. absolute_path)
                end
            end
        end
    end

    sort_records_descending(records)

    return {
        schema_version = SCHEMA_VERSION,
        updated_at = latest_created_at,
        records = records,
    }
end

local function prune_missing_record_summaries(base_dir, records)
    local retained_records = {}

    for _, summary in ipairs(records or {}) do
        local record_path = summary.record_path
        if not h.is_empty(record_path) and utils.file_info(utils.join_path(base_dir, record_path)) then
            table.insert(retained_records, summary)
        end
    end

    return retained_records
end

local function load_index(base_dir)
    local path = utils.join_path(base_dir, INDEX_FILENAME)
    if not path_exists(path) then
        local restored, restore_error = restore_replacement_backup(path)
        if restore_error then
            msg.warn('clip_logger: failed to restore interrupted index backup: ' .. tostring(restore_error))
        end
        if restored then
            msg.warn('clip_logger: restored index.json from interrupted write backup')
        end
    end

    local contents = read_all(path)
    if not contents then
        return {
            schema_version = SCHEMA_VERSION,
            updated_at = nil,
            records = {},
        }
    end

    if contents == '' then
        local backup_path = backup_malformed_index(path)
        if backup_path then
            msg.warn('clip_logger: index.json is empty; attempting recovery from record files, backup saved to ' .. backup_path)
        else
            msg.warn('clip_logger: index.json is empty; attempting recovery from record files')
        end
        return recover_index_from_records(base_dir)
    end

    local decoded = utils.parse_json(contents)
    if type(decoded) ~= 'table' or type(decoded.records) ~= 'table' then
        local backup_path = backup_malformed_index(path)
        if backup_path then
            msg.warn('clip_logger: index.json is invalid; attempting recovery from record files, backup saved to ' .. backup_path)
        else
            msg.warn('clip_logger: index.json is invalid; attempting recovery from record files')
        end
        return recover_index_from_records(base_dir)
    end

    decoded.schema_version = SCHEMA_VERSION
    decoded.records = prune_missing_record_summaries(base_dir, decoded.records)
    return decoded
end

local function save_index(base_dir, index)
    local path = utils.join_path(base_dir, INDEX_FILENAME)
    return safe_write(path, to_pretty_json(index) .. '\n')
end

local function write_record_file(base_dir, record)
    local year_month = os.date('%Y-%m')
    local record_dir = utils.join_path(utils.join_path(base_dir, RECORDS_DIRNAME), year_month)
    local ok, err = ensure_directory_exists(record_dir)
    if not ok then
        return nil, nil, err
    end

    local filename = record.record_id .. '.json'
    local absolute_path = utils.join_path(record_dir, filename)
    local relative_path = utils.join_path(utils.join_path(RECORDS_DIRNAME, year_month), filename)
    local wrote, write_err = safe_write(absolute_path, to_pretty_json(record) .. '\n')
    if not wrote then
        return nil, nil, write_err
    end

    return relative_path, absolute_path, nil
end

function self.log_completed_job(job, runtime_sub, output_path, note_fields, extra)
    local cfg = job and job.config or {}
    if cfg.clip_log_enabled ~= true then
        return true
    end

    local base_dir = cfg.clip_log_save_dir
    if h.is_empty(base_dir) then
        base_dir = utils.join_path(mp.get_script_directory(), 'clip_logs')
    end

    local ok, err = ensure_directory_exists(base_dir)
    if not ok then
        return false, err
    end

    local record = build_record(job, runtime_sub, output_path, note_fields, extra)
    local overlap_percent = ((record.clip or {}).duplicate_overlap_threshold_percent) or 90
    local index = load_index(base_dir)
    local retained_records = {}
    local duplicate_record_paths = {}

    for _, existing in ipairs(index.records or {}) do
        if is_duplicate_summary(existing, record, overlap_percent) then
            if existing.record_id then
                table.insert(record.replaced_duplicate_record_ids, existing.record_id)
            end
            if not h.is_empty(existing.record_path) then
                table.insert(duplicate_record_paths, utils.join_path(base_dir, existing.record_path))
            end
        else
            table.insert(retained_records, existing)
        end
    end

    local record_relative_path, _, write_err = write_record_file(base_dir, record)
    if not record_relative_path then
        return false, write_err
    end

    table.insert(retained_records, 1, build_summary(record, record_relative_path))
    index.updated_at = record.created_at
    index.records = retained_records

    local saved, save_err = save_index(base_dir, index)
    if not saved then
        return false, save_err
    end

    for _, duplicate_path in ipairs(duplicate_record_paths) do
        remove_file(duplicate_path)
    end

    return true, record.record_id
end

return self