local assertx = require('tests.support.assert')
local fake_env = require('tests.support.fake_clip_logger_env')
local json = require('tests.support.json')

local function make_job(base_dir, source_path, output_path)
    return {
        kind = 'create',
        profile_name = 'default',
        report_prefix = 'test',
        target_summary = 'new note',
        active_field_set_index = 1,
        update_mode = 'create',
        field_population_state = '1/4 fields populated',
        subtitles_export_disabled = false,
        text_source_kind = 'subtitles',
        media_snapshot = {
            source_path = source_path,
            working_directory = 'workdir',
        },
        captured = {
            raw_filename = 'source.mkv',
            media_title = 'Source',
            media_dir = 'media',
        },
        sub = {
            start = 10,
            ['end'] = 14,
        },
        output_dir = base_dir,
        note_ids = { 12345 },
        config = {
            clip_log_enabled = true,
            clip_log_save_dir = base_dir,
            clip_log_duplicate_overlap_percent = 90,
            deck_name = 'Deck',
            model_name = 'Model',
            loudnorm_enabled = 'no',
            clip_log_advanced_encode_logging = false,
        },
    }
end

local function parse_file(env, path)
    local contents = env:read_file(path)
    assertx.truthy(contents, 'missing file at ' .. path)
    local decoded = json.decode(contents)
    assertx.truthy(decoded, 'failed to decode json at ' .. path)
    return decoded
end

return {
  {
    name = 'clip_logger records output media tracks and summary',
    run = function()
      local env = fake_env.new()
      env:set_ffprobe_result([[{
  "streams": [
    { "codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080, "r_frame_rate": "30000/1001", "bit_rate": "2500000" },
    { "codec_type": "audio", "codec_name": "opus", "sample_rate": "48000", "channels": 2, "bit_rate": "128000" },
    { "codec_type": "subtitle", "codec_name": "webvtt", "tags": { "language": "eng" } }
  ]
}]])
      local clip_logger = env:load_clip_logger()
      local base_dir = 'logs'
      local source_path = 'video/source.mkv'
      local output_path = 'logs/new-clip.mp4'

      env:ensure_dir(base_dir)
      env:write_file(output_path, 'new-video')
      local ok = env:with_patched_os(function()
        return clip_logger.log_completed_job(make_job(base_dir, source_path, output_path), nil, output_path, nil, nil)
      end)

      assertx.truthy(ok, 'log write should succeed')
      local index = parse_file(env, 'logs/index.json')
      local record = parse_file(env, 'logs/' .. index.records[1].record_path)
      assertx.falsy(record.job.overwrite_requested, 'overwrite requested should not be persisted')
      assertx.falsy(record.job.report_prefix, 'report prefix should not be persisted')
      assertx.equals('create', record.job.update_mode, 'update mode should remain persisted')
      assertx.falsy(record.clip.duplicate_overlap_threshold_percent, 'duplicate overlap threshold should not be persisted')
            assertx.equals(source_path, record.source.path, 'source path should remain the canonical source identifier')
            assertx.falsy(record.source.raw_filename, 'derived raw filename should not be emitted')
      assertx.equals('1920x1080', record.output.media_tracks[1].resolution, 'video resolution should be recorded')
      assertx.equals(29.97, record.output.media_tracks[1].fps, 'video frame rate should be recorded')
      assertx.equals('2ch', record.output.media_tracks[2].channel_layout, 'audio channel count should be recorded')
      assertx.equals('eng', record.output.media_tracks[3].language, 'subtitle language should be recorded')
      assertx.falsy(record.output.media_summary, 'media summary should not be emitted')
      assertx.falsy(record.loudnorm.mode, 'loudnorm mode should not be emitted')
      assertx.falsy(record.result.status, 'result status should not be emitted')
    end,
  },
  {
    name = 'clip_logger records replaced output metadata',
    run = function()
      local env = fake_env.new()
      local clip_logger = env:load_clip_logger()
      local base_dir = 'logs'
      local source_path = 'video/source.mkv'
      local output_path = 'logs/new-clip.mp4'
      local old_output = 'previous-video-bytes'
      local source_media = 'source-video-bytes'

      env:ensure_dir(base_dir)
      env:write_file(source_path, source_media)
      env:write_file(output_path, 'new-video')

      local job = make_job(base_dir, source_path, output_path)
      local ok, record_id = env:with_patched_os(function()
        return clip_logger.log_completed_job(job, nil, output_path, nil, {
          result = {
            final_output_duration_seconds = 5.99,
            previous_output_size_bytes = #old_output,
            replaced_existing_output = true,
          },
        })
      end)

      assertx.truthy(ok, 'log write should succeed')
      assertx.truthy(record_id, 'record id should be returned')

      local index = parse_file(env, 'logs/index.json')
      local record = parse_file(env, 'logs/' .. index.records[1].record_path)
      assertx.equals(#source_media, record.source.size_bytes, 'source media size should be recorded')
      assertx.falsy(record.source.size_mib, 'source media size MiB should not be recorded')
      assertx.equals(5.99, record.result.final_output_duration_seconds, 'final output duration should be recorded')
      assertx.equals(#old_output, record.result.previous_output_size_bytes, 'previous output size should be recorded')
      assertx.falsy(record.result.previous_output_size_mib, 'previous output size MiB should not be recorded')
      assertx.truthy(record.result.replaced_existing_output, 'replaced output flag should be recorded')
    end,
  },
    {
        name = 'clip_logger populates anki sort field data and previous clip filename when available',
        run = function()
            local env = fake_env.new()
            local clip_logger = env:load_clip_logger()
            local base_dir = 'logs'
            local source_path = 'video/source.mkv'
            local output_path = 'logs/new-clip.mp4'

            env:ensure_dir(base_dir)
            env:write_file(source_path, 'source-video')
            env:write_file(output_path, 'new-video')

            local job = make_job(base_dir, source_path, output_path)
            job.active_fields = {
                sentence_field = 'example-sentence-mpv-anki-clips',
                secondary_field = 'example-sentence-translation-mpv-anki-clips',
                video_field = 'picture-mpv-anki-clips',
                miscinfo_field = 'notes',
            }
            local note_fields = {
                ['example-sentence-mpv-anki-clips'] = '有り',
                ['example-sentence-translation-mpv-anki-clips'] = 'Exists',
                ['picture-mpv-anki-clips'] = 'clip.jpg',
                ['notes'] = 'note',
            }

            local ok, record_id = env:with_patched_os(function()
                return clip_logger.log_completed_job(job, nil, output_path, note_fields, {
                note_sort_field_name = 'expression',
                note_sort_field_value = '皆',
                    result = {
                        replaced_existing_output = true,
                    },
                })
            end)

            assertx.truthy(ok, 'log write should succeed')
            assertx.truthy(record_id, 'record id should be returned')

            local index = parse_file(env, 'logs/index.json')
            local record = parse_file(env, 'logs/' .. index.records[1].record_path)
            assertx.equals('expression', record.anki.note_sort_field_name, 'sort field name should come from Anki note metadata')
            assertx.equals('皆', record.anki.note_sort_field_value, 'sort field value should come from Anki note metadata')
            assertx.falsy(record.anki.previous_clip_filename, 'MPV Anki Clips should not emit clip_encode-only previous filename metadata')
            assertx.equals(1, #record.anki.note_ids, 'Anki note IDs should remain available')
            assertx.falsy(record.anki.note_id, 'single-note convenience ID should not be emitted')
            assertx.falsy(record.anki.updated_fields, 'derived updated field names should not be emitted')
            assertx.falsy(record.job.field_group_label, 'derived field group label should not be emitted')
            assertx.falsy(record.output.filename, 'derived output filename should not be emitted')
            assertx.falsy(record.clip.duration_seconds, 'derived clip duration should not be emitted')
        end,
    },
    {
        name = 'clip_logger restores prior index when replacement fails',
        run = function()
            local env = fake_env.new()
            local clip_logger = env:load_clip_logger()
            local base_dir = 'logs'
            local source_path = 'video/source.mkv'
            local output_path = 'logs/new-clip.mp4'

            env:ensure_dir(base_dir)
            env:write_file('logs/index.json', '{\n  "schema_version": 2,\n  "updated_at": "old",\n  "records": []\n}\n')
            env:write_file(output_path, 'video-bytes')
            env:add_rename_failure(function(source, destination)
                if source == 'logs/index.json.tmp' and destination == 'logs/index.json' then
                    return false, 'injected rename failure'
                end
                return true
            end)

            local job = make_job(base_dir, source_path, output_path)
            local ok, err = env:with_patched_os(function()
                return clip_logger.log_completed_job(job, nil, output_path, nil, nil)
            end)

            assertx.falsy(ok, 'index write should fail')
            assertx.equals('injected rename failure', err, 'unexpected write failure')
            assertx.equals('{\n  "schema_version": 2,\n  "updated_at": "old",\n  "records": []\n}\n', env:read_file('logs/index.json'), 'previous index should be restored')
            assertx.falsy(env:file_exists('logs/index.json.bak'), 'backup file should not remain after restore')
        end,
    },
    {
        name = 'clip_logger keeps duplicate record file when index update fails',
        run = function()
            local env = fake_env.new()
            local clip_logger = env:load_clip_logger()
            local base_dir = 'logs'
            local source_path = 'video/source.mkv'
            local output_path = 'logs/new-clip.mp4'
            local old_record_path = 'logs/records/2026-04/original.json'

            env:ensure_dir('logs/records/2026-04')
            env:write_file(output_path, 'new-video')
            env:write_file(old_record_path, [[{
  "schema_version": 2,
  "log_type": "mpv_anki_clips",
  "record_id": "original",
  "created_at": "2026-04-20T09:00:00+02:00",
  "source": {
    "path": "video/source.mkv"
  },
  "clip": {
    "start_time": 10,
    "end_time": 14
  },
  "output": {
    "path": "logs/original.mp4"
  },
  "job": {
    "kind": "create",
    "target_summary": "old note"
  }
}
]])
            env:write_file('logs/index.json', [[{
  "schema_version": 2,
  "updated_at": "2026-04-20T09:00:00+02:00",
  "records": [
    {
      "log_type": "mpv_anki_clips",
      "record_id": "original",
      "created_at": "2026-04-20T09:00:00+02:00",
      "source_path": "video/source.mkv",
      "clip_start_seconds": 10,
      "clip_end_seconds": 14,
      "output_path": "logs/original.mp4",
      "job_kind": "create",
      "target_summary": "old note",
      "record_path": "records/2026-04/original.json"
    }
  ]
}
]])
            env:add_rename_failure(function(source, destination)
                if source == 'logs/index.json.tmp' and destination == 'logs/index.json' then
                    return false, 'injected rename failure'
                end
                return true
            end)

            local job = make_job(base_dir, source_path, output_path)
            local ok = env:with_patched_os(function()
                return clip_logger.log_completed_job(job, nil, output_path, nil, nil)
            end)

            assertx.falsy(ok, 'index write should fail')
            assertx.truthy(env:file_exists(old_record_path), 'duplicate record file should not be deleted before index save succeeds')
        end,
    },
    {
        name = 'clip_logger recovers from empty index file using record files',
        run = function()
            local env = fake_env.new()
            local clip_logger = env:load_clip_logger()
            local base_dir = 'logs'
            local source_path = 'video/source.mkv'
            local output_path = 'logs/new-clip.mp4'
            local old_record_path = 'logs/records/2026-04/original.json'

            env:ensure_dir('logs/records/2026-04')
            env:write_file(output_path, 'new-video')
            env:write_file(old_record_path, [[{
  "schema_version": 2,
  "log_type": "mpv_anki_clips",
  "record_id": "original",
  "created_at": "2026-04-20T09:00:00+02:00",
  "source": {
    "path": "video/other-source.mkv"
  },
  "clip": {
    "start_time": 1,
    "end_time": 3
  },
  "output": {
    "path": "logs/original.mp4"
  },
  "job": {
    "kind": "create",
    "target_summary": "old note"
  }
}
]])
            env:write_file('logs/index.json', '')

            local job = make_job(base_dir, source_path, output_path)
            local ok, record_id = env:with_patched_os(function()
                return clip_logger.log_completed_job(job, nil, output_path, nil, nil)
            end)

            assertx.truthy(ok, 'log write should succeed')
            assertx.truthy(record_id, 'record id should be returned')
            local index = parse_file(env, 'logs/index.json')
            assertx.equals(2, #index.records, 'recovered index should keep prior record and add the new one')
            assertx.equals('original', index.records[2].record_id, 'recovered record should still be present')
            assertx.truthy(env:file_exists('logs/index.json.malformed-2026-04-23T12-34-56+02-00.bak'), 'empty index backup should be preserved')
        end,
    },
    {
        name = 'clip_logger prunes summaries whose record files are missing',
        run = function()
            local env = fake_env.new()
            local clip_logger = env:load_clip_logger()
            local base_dir = 'logs'
            local source_path = 'video/source.mkv'
            local output_path = 'logs/new-clip.mp4'

            env:ensure_dir(base_dir)
            env:write_file(output_path, 'new-video')
            env:write_file('logs/index.json', [[{
  "schema_version": 2,
  "updated_at": "2026-04-20T09:00:00+02:00",
  "records": [
    {
      "log_type": "mpv_anki_clips",
      "record_id": "missing-record",
      "created_at": "2026-04-20T09:00:00+02:00",
      "source_path": "video/missing-source.mkv",
      "clip_start_seconds": 1,
      "clip_end_seconds": 3,
      "output_path": "logs/missing.mp4",
      "job_kind": "create",
      "target_summary": "missing note",
      "record_path": "records/2026-04/missing-record.json"
    }
  ]
}
]])

            local job = make_job(base_dir, source_path, output_path)
            local ok = env:with_patched_os(function()
                return clip_logger.log_completed_job(job, nil, output_path, nil, nil)
            end)

            assertx.truthy(ok, 'log write should succeed')
            local index = parse_file(env, 'logs/index.json')
            assertx.equals(1, #index.records, 'missing summaries should be pruned from the saved index')
            assertx.equals('2026-04-23T12-34-56+02-00_source.mkv_10000_14000', index.records[1].record_id, 'new summary should remain in the index')
        end,
    },
}