local assertx = require('tests.support.assert')
local encoder_loader = require('tests.support.encoder_loader')

local function has_arg(args, target)
    for _, arg in ipairs(args) do
        if arg == target then
            return true
        end
    end
    return false
end

local function index_of_arg(args, target)
    for index, arg in ipairs(args) do
        if arg == target then
            return index
        end
    end
    return nil
end

local function count_arg(args, target)
    local count = 0
    for _, arg in ipairs(args) do
        if arg == target then
            count = count + 1
        end
    end
    return count
end

local function minimal_encode_config(fix_subtitle_duration)
    return {
        enable_video = true,
        enable_audio = true,
        video_container = 'mkv',
        video_codec = 'libx264',
        video_bitrate = '500k',
        video_use_crf = true,
        video_crf = 20,
        video_quality_management = 'enabled',
        video_filter = 'disabled',
        video_preset = 'slow',
        video_custom_args = '',
        audio_codec = 'aac',
        audio_bitrate = '128k',
        audio_use_vbr = true,
        audio_quality_management = 'enabled',
        audio_custom_args = '',
        audio_fade_in = 0,
        audio_fade_out = 0,
        loudnorm_enabled = 'no',
        include_subtitles = true,
        subtitle_lang_priority = 'eng',
        subtitle_track_count = 1,
        include_metadata = true,
        fix_subtitle_duration = fix_subtitle_duration,
    }
end

return {
    {
        name = 'encoder resolves Windows PowerShell executable through the local find_exec helper',
        run = function()
            local encoder = encoder_loader.load_encoder()

            assertx.equals('powershell', encoder._test.windows_powershell_exec(), 'windows powershell exec should resolve without touching a nil global')
        end,
    },
    {
        name = 'encoder preview playback resolves mpv through find_exec instead of a nil global',
        run = function()
            local options = {}
            local encoder = encoder_loader.load_encoder(options)
            encoder.init({ preview_video = 'yes' })
            encoder._test.handle_preview_video_completion([[C:\clips\test.webm]])

            assertx.equals('mpv', encoder._test.mpv_exec(), 'mpv exec should resolve without touching a nil global')
            assertx.equals('mpv', options.last_subprocess_args[1], 'preview playback should invoke the resolved mpv executable')
            assertx.equals('--audio-display=no', options.last_subprocess_args[2], 'preview playback should disable audio display')
            assertx.equals([[C:\clips\test.webm]], options.last_subprocess_args[#options.last_subprocess_args], 'preview playback should pass the output path')
        end,
    },
    {
        name = 'encoder uses the configured Linux FFmpeg executable',
        run = function()
            local encoder = encoder_loader.load_encoder({ is_win = false })
            local config = minimal_encode_config(false)
            config.ffmpeg_exec = '/home/testuser/ffmpeg_build/bin/ffmpeg'
            encoder.init(config)
            encoder.set_media_snapshot({ has_video_track = true, has_audio_track = true, track_list = {} })

            local args = encoder._test.make_ffmpeg_video_args('input.mkv', 'output.mkv', 10, 20)
            assertx.equals(config.ffmpeg_exec, args[1], 'encoding should use the configured Linux FFmpeg executable')
        end,
    },
    {
        name = 'encoder uses the configured Windows FFmpeg executable',
        run = function()
            local encoder = encoder_loader.load_encoder()
            local config = minimal_encode_config(false)
            config.ffmpeg_exec = [[C:\ffmpeg custom\bin\ffmpeg.exe]]
            encoder.init(config)
            encoder.set_media_snapshot({ has_video_track = true, has_audio_track = true, track_list = {} })

            local args = encoder._test.make_ffmpeg_video_args('input.mkv', 'output.mkv', 10, 20)
            assertx.equals(config.ffmpeg_exec, args[1], 'encoding should use the configured Windows FFmpeg executable')
        end,
    },
    {
        name = 'encoder builds a Windows toast script with module path and native fallbacks',
        run = function()
            local encoder = encoder_loader.load_encoder()
            local script = encoder._test.build_windows_toast_powershell_script([[C:\clips\naïve clip's test.mp4]])

            assertx.truthy(script:find('Import%-BurntToastCompat'), 'toast script should probe BurntToast explicitly')
            assertx.truthy(script:find('WindowsPowerShell\\Modules'), 'toast script should probe Windows PowerShell module roots')
            assertx.truthy(script:find('PowerShell\\Modules'), 'toast script should probe PowerShell 7 module roots')
            assertx.truthy(script:find("Get%-ChildItem %-Path %$modulePath %-Filter 'BurntToast%.psd1' %-File %-Recurse"), 'toast script should probe versioned BurntToast manifests')
            assertx.truthy(script:find('Show%-NativeToast'), 'toast script should include a native Windows toast fallback')
            assertx.truthy(script:find('ms%-winsoundevent:Notification%.Default'), 'toast script should request the default toast sound')
            assertx.truthy(script:find('Play%-NotificationFallbackSound'), 'toast script should fall back to an audible notification')
            assertx.falsy(script:find('naïve', 1, true), 'toast script should not inline raw non-ASCII text')
            assertx.falsy(script:find("clip's", 1, true), 'toast script should not inline raw quoted filenames')
        end,
    },
    {
        name = 'encoder does not alter embedded subtitle inputs when duration fixing is enabled',
        run = function()
            local encoder = encoder_loader.load_encoder()
            encoder.set_media_snapshot({
                has_video_track = true,
                has_audio_track = true,
                track_list = {
                    { type = 'sub', lang = 'eng', ff_index = 0, external = false },
                },
            })

            encoder.init(minimal_encode_config(true))
            local enabled_args = encoder._test.make_ffmpeg_video_args('input.mkv', 'output.mkv', 10, 20)
            assertx.falsy(has_arg(enabled_args, '-fix_sub_duration'), 'duration fixing must not add FFmpeg options to embedded subtitle inputs')
            assertx.truthy(has_arg(enabled_args, '0:s:0'), 'the embedded subtitle stream should still be copied')
        end,
    },
    {
        name = 'encoder resolves external subtitle languages by track filename and fallback priority',
        run = function()
            local encoder = encoder_loader.load_encoder()
            local config = minimal_encode_config(false)
            config.external_subtitle_unknown_language = 'ja'
            encoder.init(config)

            assertx.equals('ger', encoder._test.external_subtitle_language('de-DE', 'movie.en.srt'), 'known track language should take priority and normalize to ISO 639-2/B')
            assertx.equals('eng', encoder._test.external_subtitle_language('und', 'movie.en.srt'), 'dot-separated filename language should be detected')
            assertx.equals('jpn', encoder._test.external_subtitle_language(nil, 'movie_jpn.ass'), 'underscore-separated filename language should be detected')
            assertx.equals('jpn', encoder._test.external_subtitle_language('und', 'movie.srt'), 'configured fallback should replace undetermined language')
            assertx.equals('OCR', encoder._test.external_subtitle_track_title('movie_ocr.srt'), 'OCR tracks should retain their special title')
            assertx.equals('speech-to-text', encoder._test.external_subtitle_track_title('movie_stt.srt'), 'STT tracks should retain their special title')
            assertx.equals('subtitle track', encoder._test.external_subtitle_track_title('movie.en.srt'), 'ordinary external subtitles should receive a title')
        end,
    },
    {
        name = 'encoder preserves external track language metadata when trimming subtitles',
        run = function()
            local subtitle_path = 'encoder_language_trim_test.en_ocr.srt'
            local subtitle_file = assert(io.open(subtitle_path, 'wb'))
            subtitle_file:write('1\n00:00:12,000 --> 00:00:13,000\ninside\n')
            subtitle_file:close()

            local encoder = encoder_loader.load_encoder({
                file_info = function()
                    return {}
                end,
                ffprobe_has_subtitles = true,
            })
            encoder.set_media_snapshot({
                source_path = 'input.mkv',
                working_directory = '.',
                has_video_track = true,
                has_audio_track = true,
                track_list = {
                    { type = 'sub', lang = 'jpn', ff_index = 0, external = true, external_filename = subtitle_path, id = 1 },
                },
            })

            local config = minimal_encode_config(true)
            config.include_external_subtitles = true
            config.external_subtitle_unknown_language = 'und'
            encoder.init(config)
            local args = encoder._test.make_ffmpeg_video_args('input.mkv', 'output.mkv', 10, 20)

            assertx.truthy(has_arg(args, 'language=jpn'), 'trimmed subtitle should retain the original track language')
            assertx.falsy(has_arg(args, 'language=eng'), 'temporary trimming must not cause language to be re-derived from a filename')
            assertx.truthy(has_arg(args, 'title=OCR'), 'OCR subtitle should receive both title and language metadata')
            for _, arg in ipairs(args) do
                if type(arg) == 'string' and arg:find('mpv_anki_clips_trimmed_subtitle', 1, true) then
                    os.remove(arg)
                end
            end
            os.remove(subtitle_path)
        end,
    },
    {
        name = 'encoder omits an external subtitle input when no cues overlap the encode range',
        run = function()
            local subtitle_path = 'encoder_empty_range_test.srt'
            local subtitle_file = assert(io.open(subtitle_path, 'wb'))
            subtitle_file:write(table.concat({
                '1',
                '00:00:01,000 --> 00:00:02,000',
                'before',
                '',
                '2',
                '00:00:21,000 --> 00:00:22,000',
                'after',
                '',
            }, '\n'))
            subtitle_file:close()

            local encoder = encoder_loader.load_encoder({
                file_info = function()
                    return {}
                end,
                ffprobe_has_subtitles = true,
            })
            encoder.set_media_snapshot({
                source_path = 'input.mkv',
                working_directory = '.',
                has_video_track = true,
                has_audio_track = true,
                track_list = {
                    { type = 'sub', lang = 'eng', ff_index = 0, external = true, external_filename = subtitle_path, id = 1 },
                },
            })

            local config = minimal_encode_config(true)
            config.include_external_subtitles = true
            encoder.init(config)
            local args = encoder._test.make_ffmpeg_video_args('input.mkv', 'output.mkv', 10, 20)

            assertx.equals(1, count_arg(args, '-i'), 'the encode command should contain only the main media input')
            assertx.falsy(has_arg(args, subtitle_path), 'the out-of-range external subtitle must not be an input')
            assertx.falsy(has_arg(args, '1:s:0'), 'the omitted external subtitle must not be mapped')
            assertx.truthy(has_arg(args, '-sn'), 'subtitle output should be disabled when no other subtitle tracks remain')
            os.remove(subtitle_path)
        end,
    },
    {
        name = 'encoder trims SRT cues outside the encode range and keeps overlapping cues',
        run = function()
            local encoder = encoder_loader.load_encoder()
            local content = table.concat({
                '1',
                '00:00:01,000 --> 00:00:02,000',
                'before',
                '',
                '2',
                '00:00:09,500 --> 00:00:10,500',
                'crosses start',
                '',
                '3',
                '00:00:15,000 --> 00:00:16,000',
                'inside',
                '',
                '4',
                '00:00:19,500 --> 00:00:21,000',
                'crosses end',
                '',
                '5',
                '00:00:21,001 --> 00:00:22,000',
                'after',
                '',
            }, '\r\n')

            local trimmed, cue_count = encoder._test.trim_external_subtitle_content('test.srt', content, 10, 20)
            assertx.equals(3, cue_count, 'only overlapping SRT cues should remain')
            assertx.falsy(trimmed:find('before', 1, true), 'cue ending before the range must be removed')
            assertx.truthy(trimmed:find('crosses start', 1, true), 'cue crossing the start boundary must remain')
            assertx.truthy(trimmed:find('inside', 1, true), 'cue inside the range must remain')
            assertx.truthy(trimmed:find('crosses end', 1, true), 'cue crossing the end boundary must remain')
            assertx.falsy(trimmed:find('after', 1, true), 'cue starting after the range must be removed')
            assertx.truthy(trimmed:find('\r\n', 1, true), 'the original CRLF line endings should be preserved')
        end,
    },
    {
        name = 'encoder trims ASS dialogue cues while preserving script metadata',
        run = function()
            local encoder = encoder_loader.load_encoder()
            local content = table.concat({
                '[Script Info]',
                'Title: Example',
                '[Events]',
                'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
                'Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,before',
                'Dialogue: 0,0:00:09.50,0:00:10.50,Default,,0,0,0,,overlap',
                'Dialogue: 0,0:00:21.00,0:00:22.00,Default,,0,0,0,,after',
            }, '\n')

            local trimmed, cue_count = encoder._test.trim_external_subtitle_content('test.ass', content, 10, 20)
            assertx.equals(1, cue_count, 'only overlapping ASS dialogue cues should remain')
            assertx.truthy(trimmed:find('Title: Example', 1, true), 'ASS metadata must be preserved')
            assertx.truthy(trimmed:find('Format: Layer', 1, true), 'ASS event format must be preserved')
            assertx.truthy(trimmed:find('overlap', 1, true), 'overlapping ASS dialogue must remain')
            assertx.falsy(trimmed:find('before', 1, true), 'early ASS dialogue must be removed')
            assertx.falsy(trimmed:find('after', 1, true), 'late ASS dialogue must be removed')
        end,
    },
    {
        name = 'encoder video job cancels only its active command and finishes once',
        run = function()
            local loader_options = {
                defer_async = true,
                file_info = function()
                    return { is_file = true, size = 1024 }
                end,
                ffprobe_result = {
                    streams = {
                        { codec_type = 'video', codec_name = 'h264', width = 1920, height = 1080 },
                    },
                    format = { duration = '10' },
                },
            }
            local encoder = encoder_loader.load_encoder(loader_options)
            local encode_config = minimal_encode_config(false)
            encode_config.video_field = 'Video'
            encoder.init(encode_config)
            encoder.set_output_dir('.')
            encoder.set_media_snapshot({
                source_path = 'input.mkv',
                has_video_track = true,
                has_audio_track = true,
                track_list = {},
            })

            local finish_count = 0
            local finish_success
            local job = encoder.video.create_job({ start = 0, ['end'] = 10 }, 0)
            job.on_finish(function(success)
                finish_count = finish_count + 1
                finish_success = success
            end).run_async()

            assertx.equals(1, #loader_options.pending_callbacks, 'one ffmpeg command should be active')
            assertx.truthy(job.cancel(), 'first cancellation should abort the job')
            assertx.equals(701, loader_options.aborted_async_ids[1], 'the owned async command should be aborted')
            assertx.equals(1, finish_count, 'cancellation should finish once')
            assertx.falsy(finish_success, 'cancellation should report failure')
            assertx.falsy(job.cancel(), 'second cancellation should be ignored')

            loader_options.pending_callbacks[1](false, { status = -1, stdout = '', stderr = 'aborted' })
            assertx.equals(1, finish_count, 'late subprocess callback must not finish twice')
        end,
    },
    {
        name = 'encoder parses ffmpeg progress clocks, clamps percent, and formats OSD labels',
        run = function()
            local encoder = encoder_loader.load_encoder()
            local parsed = encoder._test.parse_ffmpeg_progress_text(table.concat({
                'out_time=00:00:04.700000',
                'speed=2.1x',
                'progress=continue',
            }, '\n'))
            assertx.equals(4.7, parsed.out_time, 'complete progress blocks should prefer out_time clocks')
            assertx.equals('2.1x', parsed.speed, 'speed should be preserved from the last complete block')
            assertx.falsy(parsed.done, 'continue should not mark the encode as done')

            local incomplete = encoder._test.parse_ffmpeg_progress_text('out_time_us=1230000\nspeed=1.5\n')
            assertx.equals(1.23, incomplete.out_time, 'incomplete blocks should fall back to out_time_us')
            assertx.equals('1.5', incomplete.speed, 'speed without a trailing x should still be parsed')

            local historic_ms = encoder._test.parse_ffmpeg_progress_text('out_time_ms=2500000\nprogress=end\n')
            assertx.equals(2.5, historic_ms.out_time, 'historical out_time_ms values are microseconds')
            assertx.truthy(historic_ms.done, 'progress=end should mark the encode as done')

            assertx.equals(47, encoder._test.encode_progress_percent(4.7, 10), 'percent should round from out_time / duration')
            assertx.equals(0, encoder._test.encode_progress_percent(-1, 10), 'percent should clamp below 0')
            assertx.equals(100, encoder._test.encode_progress_percent(12, 10), 'percent should clamp above 100')
            assertx.equals(nil, encoder._test.encode_progress_percent(1, 0), 'invalid durations should not produce a percent')

            assertx.equals('[Waiting for global queue...]', encoder._test.format_encode_progress_label({ stage = 'global_queue_waiting' }))
            assertx.equals('[Measuring...]', encoder._test.format_encode_progress_label({ stage = 'measuring' }))
            assertx.equals('[Finalizing...]', encoder._test.format_encode_progress_label({ stage = 'finalizing' }))
            assertx.equals('[Pass 1/2 47% 2.1x]', encoder._test.format_encode_progress_label({ stage = 'pass1', percent = 47, speed = '2.1x' }))
            assertx.equals('[Pass 2/2 12%]', encoder._test.format_encode_progress_label({ stage = 'pass2', percent = 12 }))
            assertx.equals('[Encoding 47% 1.8x]', encoder._test.format_encode_progress_label({ stage = 'encoding', percent = 47, speed = '1.8' }))
            assertx.equals('[Encoding...]', encoder._test.format_encode_progress_label({}))
        end,
    },
    {
        name = 'encoder inserts -progress after ffmpeg header args and remaps remote progress paths',
        run = function()
            local encoder = encoder_loader.load_encoder()
            encoder.init({
                remote_ffmpeg_enabled = 'yes',
                remote_encode_staging_dir_local = [[C:\stage]],
                remote_encode_staging_dir_remote = [[D:\stage]],
            })

            local args = { 'ffmpeg', '-hide_banner', '-nostdin', '-y', '-i', 'input.mkv', 'out.mkv' }
            encoder._test.insert_ffmpeg_progress_args(args, [[C:\stage\progress.txt]])
            assertx.equals('-nostats', args[5], '-nostats should follow the ffmpeg header')
            assertx.equals('-progress', args[6], '-progress should follow -nostats')
            assertx.equals([[C:\stage\progress.txt]], args[7], 'progress path should be inserted as the next argument')
            assertx.equals('-i', args[8], 'existing encode args should shift after the progress flags')

            local remapped = encoder._test.remap_ffmpeg_args_for_remote(args)
            assertx.equals([[D:\stage\progress.txt]], remapped[7], 'remote remap should rewrite the -progress path')
        end,
    },
    {
        name = 'encoder omits -progress from loudnorm measure args',
        run = function()
            local encoder = encoder_loader.load_encoder()
            local args = encoder._test.make_ffmpeg_loudnorm_measure_args('input.mkv', 1, 2)
            assertx.falsy(has_arg(args, '-progress'), 'loudnorm measurement must not attach a progress file')
            assertx.falsy(has_arg(args, '-nostats'), 'loudnorm measurement must not disable stats via -nostats')
        end,
    },
}