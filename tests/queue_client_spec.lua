local assertx = require('tests.support.assert')
local loader = require('tests.support.queue_client_loader')

local function success(body, status)
    return {
        status = 0,
        stdout = body,
        stderr = '',
        http_status = status or 200,
    }
end

local function config(host)
    return {
        queue_server_enabled = true,
        queue_server_host = host or '192.168.1.10',
        queue_server_port = 56789,
        queue_server_connect_timeout = 2,
        queue_server_request_timeout = 5,
    }
end

return {
    {
        name = 'queue client submits metadata directly to configured LAN endpoint',
        run = function()
            local client, captured = loader.load(config(), {
                success('{"job_id":"server-job","state":"granted","lease_id":"lease-1"}', 201),
            })
            local response
            local job = {
                kind = 'test_encode',
                profile_name = 'default',
                target_summary = 'target',
                output_dir = 'C:/output',
                media_snapshot = { source_path = 'C:/video.mkv' },
                sub = { start = 1.25, ['end'] = 2.5 },
                config = { remote_ffmpeg_enabled = 'no' },
            }

            client.request(job, function(value) response = value end)

            assertx.equals('http://192.168.1.10:56789/v1/jobs', captured.requests[1].url)
            assertx.equals('POST', captured.requests[1].method)
            assertx.equals('C:/video.mkv', captured.formatted[1].source_path)
            assertx.equals('test-video', captured.formatted[1].client_label)
            assertx.equals('local', captured.formatted[1].encode_mode)
            assertx.equals('granted', response.state)
            assertx.truthy(job.global_queue_id)
        end,
    },
    {
        name = 'queue client brackets an IPv6 host',
        run = function()
            local client, captured = loader.load(config('fd00::10'), {
                success('{"job_id":"job","state":"pending","position":1}'),
            })
            client.get('job', function() end)
            assertx.equals('http://[fd00::10]:56789/v1/jobs/job', captured.requests[1].url)
        end,
    },
    {
        name = 'queue client sends lease ID for heartbeat and completion',
        run = function()
            local client, captured = loader.load(config(), {
                success('{"job_id":"job","state":"granted","lease_id":"lease-1"}'),
                success('{"job_id":"job","state":"completed"}'),
            })
            client.heartbeat('job', 'lease-1', function() end)
            client.complete('job', 'lease-1', function() end)

            assertx.equals('/heartbeat', captured.requests[1].url:sub(-10))
            assertx.equals('lease-1', captured.formatted[1].lease_id)
            assertx.equals('/complete', captured.requests[2].url:sub(-9))
            assertx.equals('lease-1', captured.formatted[2].lease_id)
        end,
    },
    {
        name = 'queue client reports stable HTTP API errors',
        run = function()
            local client = loader.load(config(), {
                success('{"error":{"code":"lease_mismatch","message":"stale lease"}}', 409),
            })
            local response, err, code
            client.complete('job', 'old', function(value, message, error_code)
                response, err, code = value, message, error_code
            end)
            assertx.equals(nil, response)
            assertx.equals('stale lease', err)
            assertx.equals('lease_mismatch', code)
        end,
    },
    {
        name = 'queue client sends no request while disabled',
        run = function()
            local disabled = config()
            disabled.queue_server_enabled = false
            local client, captured = loader.load(disabled, {})
            local err
            client.get('job', function(_, message) err = message end)
            assertx.equals(0, #captured.requests)
            assertx.equals('global queue is disabled', err)
        end,
    },
}