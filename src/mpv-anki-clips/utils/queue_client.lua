local mp = require('mp')
local utils = require('mp.utils')
local platform = require('platform.init')

local self = {}
local config = nil
local sequence = 0

local function enabled()
    return config and config.queue_server_enabled == true
end

local function host()
    local value = config and config.queue_server_host or ''
    if value:find(':', 1, true) and value:sub(1, 1) ~= '[' then
        return '[' .. value .. ']'
    end
    return value
end

local function base_url()
    return string.format('http://%s:%d', host(), config.queue_server_port)
end

local function parse_response(result)
    if not result or result.status ~= 0 then
        return nil, (result and (result.stderr or result.stdout)) or 'queue server did not return a result'
    end
    if not result.http_status then
        return nil, 'queue server response did not include an HTTP status'
    end

    local decoded = utils.parse_json(result.stdout or '')
    if type(decoded) ~= 'table' then
        return nil, string.format('queue server returned invalid JSON (HTTP %s)', tostring(result.http_status))
    end
    if result.http_status < 200 or result.http_status >= 300 then
        local api_error = type(decoded.error) == 'table' and decoded.error or {}
        return nil, tostring(api_error.message or decoded.error or ('HTTP ' .. tostring(result.http_status))), api_error.code
    end
    return decoded
end

local function invoke(method, path, payload, callback)
    if not enabled() then
        callback(nil, 'global queue is disabled')
        return
    end
    platform.http_request({
        url = base_url() .. path,
        method = method,
        body = payload and utils.format_json(payload) or nil,
        connect_timeout = config.queue_server_connect_timeout,
        timeout = config.queue_server_request_timeout,
    }, function(_, result)
        callback(parse_response(result))
    end)
end

function self.init(new_config)
    config = new_config
end

function self.is_enabled()
    return enabled()
end

function self.request(job, callback)
    sequence = sequence + 1
    local source_path = ((job.media_snapshot or {}).source_path) or ((job.captured or {}).media_path) or ''
    local clip = job.sub or {}
    local queue_id = string.format('%s-%s-%s', tostring(os.time()), tostring(mp.get_property_native('pid') or 'mpv'), tostring(sequence))
    job.global_queue_id = queue_id

    invoke('POST', '/v1/jobs', {
        job_id = queue_id,
        source_path = source_path,
        target_summary = job.target_summary or '',
        job_kind = job.kind or '',
        profile_name = job.profile_name or '',
        encode_mode = (job.config or {}).remote_ffmpeg_enabled == 'yes' and 'ssh' or 'local',
        clip_start_seconds = tonumber(clip.start) or 0,
        clip_end_seconds = tonumber(clip['end']) or 0,
        output_path = job.output_dir or '',
        client_label = mp.get_property('filename/no-ext') or 'mpv',
    }, callback)
end

function self.get(job_id, callback)
    invoke('GET', '/v1/jobs/' .. job_id, nil, callback)
end

function self.heartbeat(job_id, lease_id, callback)
    invoke('POST', '/v1/jobs/' .. job_id .. '/heartbeat', { lease_id = lease_id }, callback)
end

function self.complete(job_id, lease_id, callback)
    if not job_id or not lease_id then
        if callback then callback(nil, 'missing queue job or lease id') end
        return
    end
    invoke('POST', '/v1/jobs/' .. job_id .. '/complete', { lease_id = lease_id }, callback or function() end)
end

function self.cancel(job_id, lease_id, callback)
    if not job_id then
        if callback then callback(nil, 'missing queue job id') end
        return
    end
    invoke('POST', '/v1/jobs/' .. job_id .. '/cancel', { lease_id = lease_id }, callback or function() end)
end

return self