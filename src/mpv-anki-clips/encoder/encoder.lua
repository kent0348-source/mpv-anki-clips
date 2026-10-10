--[[
Copyright: Ren Tatsumoto and contributors
License: GNU GPL, version 3 or later; http://www.gnu.org/licenses/gpl.html

Encoder creates video clips from subtitle timings, with optional subtitle inclusion.
Updated with codec validation, fallback logic, loudnorm (single/two-pass), and audio fade-in/out by Grok 3 (beta).
]]

local mp = require('mp')
local utils = require('mp.utils')
local h = require('helpers')
local filename_factory = require('utils.filename_factory')
local msg = require('mp.msg')
local codec_support = require('encoder.codec_support')
local logger = require('utils.logger')
local platform = require('platform.init')
local base64 = require('utils.base64')
local iso639 = require('utils.iso639')
local ffmpeg_executable = require('encoder.ffmpeg_exec')
local configured_ffmpeg_exec = ffmpeg_executable.resolve()

-- Contains the state of the module
local self = {
    video = {},
    config = nil,
    media_snapshot = nil,
    encoder = nil,
    output_dir_path = nil,
    last_encode_command = nil,
    last_encode_details = nil,
    last_encode_filesize = nil,
    last_encode_duration = nil,
    last_error_tail = nil,
    __passlogfile_prefix = nil,
}

local function clone_table(value)
    if type(value) ~= 'table' then
        return value
    end

    local copy = {}
    for key, item in pairs(value) do
        copy[key] = clone_table(item)
    end
    return copy
end

local function advanced_encode_logging_enabled()
    return self.config and self.config.clip_log_advanced_encode_logging == true
end

local function capture_loudnorm_details(mode, loudnorm_stats, warnings)
    local effective_linear = nil
    if mode == 'two_pass' then
        effective_linear = true
    elseif mode == 'single_pass' then
        effective_linear = self.config.loudnorm_linear == 'yes'
    end

    return {
        mode = mode,
        target = {
            enabled = self.config.loudnorm_enabled == 'yes',
            i = self.config.loudnorm_I,
            lra = self.config.loudnorm_LRA,
            tp = self.config.loudnorm_TP,
            linear = effective_linear,
        },
        analyzed = advanced_encode_logging_enabled() and loudnorm_stats and clone_table(loudnorm_stats) or nil,
        warnings = warnings,
    }
end

local function stream_toggle_enabled(value, default_value)
    if value == nil then
        return default_value
    end
    if value == true or value == false then
        return value
    end
    if type(value) == 'string' then
        local normalized = value:lower()
        if normalized == 'yes' or normalized == 'true' or normalized == 'enabled' then
            return true
        end
        if normalized == 'no' or normalized == 'false' or normalized == 'disabled' then
            return false
        end
    end
    return default_value
end

local function encode_video_enabled()
    return stream_toggle_enabled(self.config and self.config.enable_video, true)
end

local function encode_audio_enabled()
    return stream_toggle_enabled(self.config and self.config.enable_audio, true)
end

local ps_single_quote
local ps_encoded_command
local find_exec

local function windows_powershell_exec()
    return find_exec('powershell')
end

local function mpv_exec()
    return find_exec('mpv')
end

local function preview_video_mode()
    local value = self.config and self.config.preview_video
    if value == true then
        return 'yes'
    end
    if value == false or value == nil then
        return 'no'
    end
    if type(value) == 'string' then
        local normalized = value:lower()
        if normalized == 'yes' or normalized == 'true' or normalized == 'enabled' then
            return 'yes'
        end
        if normalized == 'notify' then
            return 'notify'
        end
        if normalized == 'toast' then
            return 'toast'
        end
    end
    return 'no'
end

local function play_export_finished_sound()
    if platform.windows then
        local script = table.concat({
            "$ErrorActionPreference = 'Stop'",
            "try { [System.Media.SystemSounds]::Asterisk.Play() | Out-Null } catch { exit 0 }"
        }, '; ')

        h.subprocess({
            windows_powershell_exec(), '-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
            '-ExecutionPolicy', 'Bypass', '-EncodedCommand', ps_encoded_command(script)
        }, function()
        end)
        return
    end

    if h.is_mac() then
        h.subprocess_detached({ 'afplay', '/System/Library/Sounds/Glass.aiff' }, function()
        end)
        return
    end

    h.subprocess_detached({
        'sh', '-c',
        "if command -v canberra-gtk-play >/dev/null 2>&1; then canberra-gtk-play -i complete; " ..
        "elif command -v paplay >/dev/null 2>&1 && [ -f /usr/share/sounds/freedesktop/stereo/complete.oga ]; then paplay /usr/share/sounds/freedesktop/stereo/complete.oga; " ..
        "else printf '\\a'; fi"
    }, function()
    end)
end

local function toast_notification_lines(output_path)
    local filename = tostring(output_path or ''):match('[^/\\]+$') or 'Clip ready'
    local duration = self.last_encode_duration
    local body = 'Created clip: ' .. filename
    local details = type(duration) == 'number' and duration > 0
        and ('Length: ' .. h.human_readable_time_no_ms(duration))
        or 'Export finished successfully'

    return 'MPV Anki Clips export finished', body, details
end

local function build_windows_toast_powershell_script(output_path)
    local title, body, details = toast_notification_lines(output_path)
    local lines = {
        "$ErrorActionPreference = 'Stop'",
        "$ProgressPreference = 'SilentlyContinue'",
        "function Decode-Utf8([string]$value) { if ([string]::IsNullOrEmpty($value)) { return '' }; return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value)) }",
        "function Play-NotificationFallbackSound { try { [System.Media.SystemSounds]::Asterisk.Play() | Out-Null; return $true } catch { return $false } }",
        "$title = Decode-Utf8('" .. base64.enc(title) .. "')",
        "$body = Decode-Utf8('" .. base64.enc(body) .. "')",
        "$details = Decode-Utf8('" .. base64.enc(details) .. "')",
        "$text = @($title, $body, $details)",
        "function Import-BurntToastCompat {",
        "  $moduleRoots = New-Object System.Collections.Generic.List[string]",
        "  $documents = [Environment]::GetFolderPath('MyDocuments')",
        "  if ($documents) {",
        "    [void]$moduleRoots.Add((Join-Path $documents 'WindowsPowerShell\\Modules'))",
        "    [void]$moduleRoots.Add((Join-Path $documents 'PowerShell\\Modules'))",
        "  }",
        "  foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {",
        "    if ($root) {",
        "      [void]$moduleRoots.Add((Join-Path $root 'WindowsPowerShell\\Modules'))",
        "      [void]$moduleRoots.Add((Join-Path $root 'PowerShell\\Modules'))",
        "    }",
        "  }",
        "  $moduleDirs = @()",
        "  foreach ($root in $moduleRoots) {",
        "    if ($root -and (Test-Path $root)) { $moduleDirs += $root }",
        "  }",
        "  if ($moduleDirs.Count -gt 0) {",
        "    $existing = @()",
        "    if ($env:PSModulePath) { $existing = @($env:PSModulePath -split [IO.Path]::PathSeparator) }",
        "    foreach ($dir in $moduleDirs) {",
        "      if ($dir -and ($existing -notcontains $dir)) { $existing = @($dir) + $existing }",
        "    }",
        "    if ($existing.Count -gt 0) {",
        "      $env:PSModulePath = ($existing | Where-Object { $_ } | Select-Object -Unique) -join [IO.Path]::PathSeparator",
        "    }",
        "  }",
        "  try { Import-Module BurntToast -ErrorAction Stop; return $true } catch {}",
        "  $moduleManifests = @()",
        "  foreach ($root in $moduleDirs) {",
        "    $modulePath = Join-Path $root 'BurntToast'",
        "    if (Test-Path $modulePath) {",
        "      $moduleManifests += Get-ChildItem -Path $modulePath -Filter 'BurntToast.psd1' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName",
        "    }",
        "  }",
        "  foreach ($manifest in ($moduleManifests | Select-Object -Unique)) {",
        "    if ($manifest -and (Test-Path $manifest) -and -not (Get-Item $manifest).PSIsContainer) {",
        "      try { Import-Module $manifest -ErrorAction Stop; return $true } catch {}",
        "    }",
        "  }",
        "  return $false",
        "}",
        "function Escape-ToastXml([string]$value) { return [System.Security.SecurityElement]::Escape($value) }",
        "function Show-NativeToast([string]$appId, [string[]]$textLines) {",
        "  try { Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop | Out-Null } catch {}",
        "  try {",
        "    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]",
        "    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]",
        "  } catch {",
        "    return $false",
        "  }",
        "  $xml = \"<toast><visual><binding template='ToastGeneric'><text>\" + (Escape-ToastXml($textLines[0])) + \"</text><text>\" + (Escape-ToastXml($textLines[1])) + \"</text><text>\" + (Escape-ToastXml($textLines[2])) + \"</text></binding></visual><audio src='ms-winsoundevent:Notification.Default'/></toast>\"",
        "  try {",
        "    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument",
        "    $doc.LoadXml($xml)",
        "    $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)",
        "    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId)",
        "    $notifier.Show($toast)",
        "    return $true",
        "  } catch {",
        "    return $false",
        "  }",
        "}",
        "if (Import-BurntToastCompat) {",
        "  try { New-BurntToastNotification -Text $text | Out-Null; exit 0 } catch {}",
        "}",
        "$nativeToastAppIds = @('PowerShell', 'Windows PowerShell', 'Microsoft.PowerShell', 'Microsoft.WindowsPowerShell')",
        "foreach ($appId in $nativeToastAppIds) {",
        "  if (Show-NativeToast $appId $text) { exit 0 }",
        "}",
        "Play-NotificationFallbackSound | Out-Null",
        "exit 0"
    }

    return table.concat(lines, '; ')
end

local function show_windows_toast_notification(output_path)
    h.subprocess({
        windows_powershell_exec(), '-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass', '-EncodedCommand', ps_encoded_command(build_windows_toast_powershell_script(output_path))
    }, function()
    end)
end

local function handle_preview_video_completion(output_path)
    local mode = preview_video_mode()
    if mode == 'yes' then
        h.subprocess(
            { mpv_exec(), '--audio-display=no', '--force-window=no', '--keep-open=no', '--really-quiet', output_path },
            function() print('Played video: ' .. output_path) end
        )
    elseif mode == 'notify' then
        play_export_finished_sound()
    elseif mode == 'toast' then
        if platform.windows then
            show_windows_toast_notification(output_path)
        else
            play_export_finished_sound()
        end
    end
end

local function current_track_list_from_mpv()
    local track_list = {}
    local count = mp.get_property_number("track-list/count") or 0
    for i = 0, count - 1 do
        table.insert(track_list, {
            type = mp.get_property("track-list/" .. i .. "/type"),
            lang = mp.get_property("track-list/" .. i .. "/lang") or "und",
            ff_index = mp.get_property_number("track-list/" .. i .. "/ff-index"),
            external = mp.get_property_bool("track-list/" .. i .. "/external"),
            external_filename = mp.get_property("track-list/" .. i .. "/external-filename"),
            id = mp.get_property_number("track-list/" .. i .. "/id"),
            codec = mp.get_property("track-list/" .. i .. "/codec"),
        })
    end
    return track_list
end

local function track_list_snapshot()
    if self.media_snapshot and self.media_snapshot.track_list then
        return self.media_snapshot.track_list
    end
    return current_track_list_from_mpv()
end

local function source_path_snapshot()
    if self.media_snapshot and self.media_snapshot.source_path then
        return self.media_snapshot.source_path
    end
    return mp.get_property("path")
end

local function working_directory_snapshot()
    if self.media_snapshot and self.media_snapshot.working_directory then
        return self.media_snapshot.working_directory
    end
    return mp.get_property("working-directory")
end

local function current_sub_id_snapshot()
    if self.media_snapshot and self.media_snapshot.current_sub_id ~= nil then
        return self.media_snapshot.current_sub_id
    end
    return mp.get_property("current-tracks/sub/id")
end

local trim_ws

local function normalize_lang_code(lang)
    if type(lang) ~= 'string' then return 'und' end
    local lowered = lang:lower()
    local base = lowered:match('^([a-z]+)') or lowered
    local aliases = {
        eng = 'en', en = 'en',
        ger = 'de', deu = 'de', de = 'de',
        jpn = 'ja', jp = 'ja', ja = 'ja',
    }
    return aliases[base] or base
end

local function parse_priority_csv(csv, fallback_csv)
    local out = {}
    local source = csv
    if type(source) ~= 'string' or trim_ws(source) == '' then
        source = fallback_csv or ''
    end
    for token in tostring(source):gmatch('[^,]+') do
        local value = trim_ws(token):lower()
        if value ~= '' then
            table.insert(out, value)
        end
    end
    return out
end

local function preferred_audio_maps_from_snapshot()
    local track_list = track_list_snapshot()
    local audio_tracks = {}
    local first_audio_ff_index = nil

    for _, track in ipairs(track_list) do
        if track.type == 'audio' and not track.external and track.ff_index ~= nil then
            if first_audio_ff_index == nil then
                first_audio_ff_index = track.ff_index
            end
            table.insert(audio_tracks, {
                lang = track.lang or 'und',
                ff_index = track.ff_index,
            })
        end
    end

    if #audio_tracks == 0 or first_audio_ff_index == nil then
        return { '0:a:0?' }
    end

    local lang_priority = parse_priority_csv(self.config and self.config.audio_lang_priority, 'jp,jpn,ja,eng,en,und')
    local normalized_priority = {}
    for i, lang in ipairs(lang_priority) do
        normalized_priority[i] = normalize_lang_code(lang)
    end

    local function lang_rank(lang)
        local lowered = tostring(lang or 'und'):lower()
        local normalized = normalize_lang_code(lowered)
        for i = 1, #lang_priority do
            if lowered == lang_priority[i] or normalized == normalized_priority[i] then
                return i
            end
        end
        return #lang_priority + 1
    end

    table.sort(audio_tracks, function(a, b)
        local ra = lang_rank(a.lang)
        local rb = lang_rank(b.lang)
        if ra ~= rb then
            return ra < rb
        end
        return a.ff_index < b.ff_index
    end)

    local wanted = tonumber(self.config and self.config.audio_track_count) or 1
    if wanted < 1 then wanted = 1 end
    wanted = math.floor(wanted)

    local maps = {}
    for i = 1, #audio_tracks do
        if #maps >= wanted then
            break
        end
        local adjusted_index = audio_tracks[i].ff_index - first_audio_ff_index
        if adjusted_index >= 0 then
            table.insert(maps, '0:a:' .. tostring(adjusted_index) .. '?')
        end
    end

    if #maps == 0 then
        return { '0:a:0?' }
    end

    return maps
end

local function output_has_video_stream()
    local has_video_track = self.media_snapshot and self.media_snapshot.has_video_track
    if has_video_track == nil then
        has_video_track = h.has_video_track()
    end
    return encode_video_enabled() and has_video_track
end

local function output_has_audio_stream()
    local has_audio_track = self.media_snapshot and self.media_snapshot.has_audio_track
    if has_audio_track == nil then
        has_audio_track = h.has_audio_track()
    end
    return encode_audio_enabled() and has_audio_track
end

local function pad_timings(padding, start_time, end_time)
    local video_duration = mp.get_property_number('duration')
    start_time = start_time - padding
    end_time = end_time + padding

    if start_time < 0 then
        start_time = 0
    end

    if end_time > video_duration then
        end_time = video_duration
    end

    return start_time, end_time
end

find_exec = function(name)
    return ffmpeg_executable.find(name)
end

-- Remote FFmpeg over SSH helpers

local function is_remote_ffmpeg_enabled()
    local v = self.config and self.config.remote_ffmpeg_enabled
    return v == true or v == 'yes' or v == 'enabled'
end

local function remote_staging_dir_local()
    return self.config and self.config.remote_encode_staging_dir_local or ''
end

local function remote_staging_dir_remote()
    return self.config and self.config.remote_encode_staging_dir_remote or ''
end

local function local_dir_exists(path)
    if h.is_empty(path) then return false end
    local info = utils.file_info(path)
    return info and info.is_dir or false
end

local function is_remote_staging_local_available()
    return local_dir_exists(remote_staging_dir_local())
end

ps_single_quote = function(s)
    -- PowerShell single-quoted string escaping: ' -> ''
    s = tostring(s or '')
    return s:gsub("'", "''")
end

ps_encoded_command = function(script)
    -- PowerShell -EncodedCommand expects UTF-16LE bytes encoded as base64.
    -- Our scripts are ASCII-safe (base64/JSON), so a simple UTF-16LE encoding is sufficient.
    script = tostring(script or '')
    local bytes = {}
    for i = 1, #script do
        bytes[#bytes + 1] = script:sub(i, i)
        bytes[#bytes + 1] = '\0'
    end
    return base64.enc(table.concat(bytes))
end

local function json_escape_string(s)
    s = tostring(s or '')
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\t', '\\t')
    return s
end

local function json_string_array(arr)
    local parts = { '[' }
    for i, v in ipairs(arr or {}) do
        if i > 1 then table.insert(parts, ',') end
        table.insert(parts, '"' .. json_escape_string(v) .. '"')
    end
    table.insert(parts, ']')
    return table.concat(parts)
end

local function make_unique_staging_filename(prefix, ext)
    local t = tostring(os.time())
    local r = tostring(math.random(1000, 9999))
    ext = ext or ''
    return string.format('%s_%s_%s%s', prefix or 'MPV Anki Clips', t, r, ext)
end

local ENCODE_PROGRESS_POLL_INTERVAL = 1.0

local function make_unique_progress_path()
    local filename = make_unique_staging_filename('MPV Anki Clips_progress', '.txt')
    if is_remote_ffmpeg_enabled() and not h.is_empty(remote_staging_dir_local()) then
        return utils.join_path(remote_staging_dir_local(), filename)
    end
    local tmpdir = platform.tmp_dir() or mp.get_property("working-directory") or "."
    return utils.join_path(tmpdir, filename)
end

local function parse_ffmpeg_clock(value)
    if type(value) ~= 'string' or value == '' or value == 'N/A' then
        return nil
    end
    local hours, minutes, seconds = value:match('^(%d+):(%d%d):(%d%d%.?%d*)$')
    if not hours then
        return nil
    end
    return tonumber(hours) * 3600 + tonumber(minutes) * 60 + tonumber(seconds)
end

local function parse_ffmpeg_progress_text(text)
    if type(text) ~= 'string' or text == '' then
        return nil
    end

    local fields = {}
    local last_complete = nil
    for line in (text .. '\n'):gmatch('(.-)\r?\n') do
        local key, value = line:match('^([^=]+)=(.*)$')
        if key then
            fields[key] = value
            if key == 'progress' then
                last_complete = fields
                fields = {}
            end
        end
    end

    local parsed = last_complete
    if not parsed then
        parsed = fields
        if next(parsed) == nil then
            return nil
        end
    end

    local out_time = parse_ffmpeg_clock(parsed.out_time)
    if not out_time then
        local us = tonumber(parsed.out_time_us)
        if us then
            out_time = us / 1000000
        else
            local ms = tonumber(parsed.out_time_ms)
            if ms then
                -- FFmpeg historically reports out_time_ms in microseconds.
                out_time = ms / 1000000
            end
        end
    end

    local speed = parsed.speed
    if type(speed) == 'string' then
        speed = speed:gsub('%s+$', '')
        if speed == '' or speed == 'N/A' then
            speed = nil
        end
    end

    return {
        out_time = out_time,
        speed = speed,
        done = parsed.progress == 'end',
    }
end

local function encode_progress_percent(out_time, duration)
    duration = tonumber(duration)
    if not duration or duration <= 0 then
        return nil
    end
    out_time = tonumber(out_time) or 0
    local percent = math.floor((out_time / duration) * 100 + 0.5)
    if percent < 0 then
        return 0
    end
    if percent > 100 then
        return 100
    end
    return percent
end

local function format_encode_progress_speed(speed)
    if type(speed) ~= 'string' or speed == '' then
        return nil
    end
    if speed:sub(-1) == 'x' then
        return speed
    end
    return speed .. 'x'
end

local function format_encode_progress_label(info)
    info = info or {}
    local stage = info.stage
    if stage == 'global_queue_waiting' then
        return '[Waiting for global queue...]'
    end
    if stage == 'measuring' then
        return '[Measuring...]'
    end
    if stage == 'finalizing' then
        return '[Finalizing...]'
    end

    local percent = tonumber(info.percent)
    local speed = format_encode_progress_speed(info.speed)
    if stage == 'pass1' or stage == 'pass2' then
        local pass_n = stage == 'pass1' and 1 or 2
        if percent ~= nil then
            if speed then
                return string.format('[Pass %d/2 %d%% %s]', pass_n, percent, speed)
            end
            return string.format('[Pass %d/2 %d%%]', pass_n, percent)
        end
        return string.format('[Pass %d/2...]', pass_n)
    end

    if percent ~= nil then
        if speed then
            return string.format('[Encoding %d%% %s]', percent, speed)
        end
        return string.format('[Encoding %d%%]', percent)
    end
    return '[Encoding...]'
end

local function read_file_contents(path)
    if type(path) ~= 'string' or path == '' then
        return nil
    end
    local handle = io.open(path, 'rb')
    if not handle then
        return nil
    end
    local contents = handle:read('*a')
    handle:close()
    return contents
end

local function insert_ffmpeg_progress_args(args, progress_path)
    if type(args) ~= 'table' or h.is_empty(progress_path) then
        return args
    end
    local insert_at = 5
    if args[1] ~= nil then
        table.insert(args, insert_at, '-nostats')
        table.insert(args, insert_at + 1, '-progress')
        table.insert(args, insert_at + 2, progress_path)
    end
    return args
end

local function attach_ffmpeg_progress(args, duration, on_progress_fn)
    if type(on_progress_fn) ~= 'function' then
        return function() end
    end

    local progress_path = make_unique_progress_path()
    insert_ffmpeg_progress_args(args, progress_path)

    local stopped = false
    local last_percent = nil
    local last_speed = nil
    local timer = mp.add_periodic_timer(ENCODE_PROGRESS_POLL_INTERVAL, function()
        if stopped then
            return
        end
        local parsed = parse_ffmpeg_progress_text(read_file_contents(progress_path))
        if not parsed then
            return
        end
        local percent = encode_progress_percent(parsed.out_time, duration)
        if parsed.done then
            percent = 100
        end
        if percent == nil and parsed.speed == nil then
            return
        end
        if percent == last_percent and parsed.speed == last_speed then
            return
        end
        last_percent = percent
        last_speed = parsed.speed
        on_progress_fn({
            percent = percent,
            speed = parsed.speed,
        })
    end)

    return function()
        if stopped then
            return
        end
        stopped = true
        if timer and timer.kill then
            timer:kill()
        end
        os.remove(progress_path)
    end
end

trim_ws = function(s)
    if type(s) ~= 'string' then return '' end
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function strip_non_ascii(s)
    if type(s) ~= 'string' then return s end
    -- Remove any non-ASCII bytes (helps avoid Windows/SMB path issues)
    local stripped = s:gsub('[\128-\255]', '')
    if stripped == '' then
        return 'clip'
    end
    return stripped
end

local function parse_path_map_rules(s)
    if not s or s == '' then return {} end
    local rules = {}
    for part in tostring(s):gmatch('[^;]+') do
        local from, to = part:match('^(.-)=>%s*(.-)$')
        from = trim_ws(from)
        to = trim_ws(to)
        if from ~= '' and to ~= '' then
            table.insert(rules, { from = from, to = to, from_lc = from:lower(), len = #from })
        end
    end
    table.sort(rules, function(a, b) return a.len > b.len end)
    return rules
end

local function remap_path(p, rules)
    if type(p) ~= 'string' or p == '' then return p end
    local plc = p:lower()
    for _, r in ipairs(rules or {}) do
        if plc:sub(1, r.len) == r.from_lc then
            return r.to .. p:sub(r.len + 1)
        end
    end
    return p
end

local function remap_ffmpeg_args_for_remote(args)
    local rules = parse_path_map_rules(self.config and self.config.remote_path_map or '')
    local local_stage = remote_staging_dir_local()
    local remote_stage = remote_staging_dir_remote()
    if not h.is_empty(local_stage) and not h.is_empty(remote_stage) and local_stage:lower() ~= remote_stage:lower() then
        table.insert(rules, {
            from = local_stage,
            to = remote_stage,
            from_lc = local_stage:lower(),
            len = #local_stage,
        })
        table.sort(rules, function(a, b) return a.len > b.len end)
    end

    local function looks_like_output_path_here(token)
        if type(token) ~= 'string' then return false end
        if token == 'NUL' or token == '-' then return true end
        if token:match('^%a:[\\/]') then return true end
        if token:find('/') or token:find('\\') then return true end
        if token:match('%.[%w%d]+$') then return true end
        return false
    end

    local out = {}
    local i = 1
    while i <= #args do
        local tok = args[i]
        table.insert(out, tok)
        if tok == '-i' and args[i + 1] then
            out[#out] = tok
            table.insert(out, remap_path(args[i + 1], rules))
            i = i + 2
        elseif tok == '-passlogfile' and args[i + 1] then
            out[#out] = tok
            table.insert(out, remap_path(args[i + 1], rules))
            i = i + 2
        elseif tok == '-progress' and args[i + 1] then
            out[#out] = tok
            table.insert(out, remap_path(args[i + 1], rules))
            i = i + 2
        else
            i = i + 1
        end
    end
    -- Remap final output path
    if #out > 0 and looks_like_output_path_here(out[#out]) then
        out[#out] = remap_path(out[#out], rules)
    end
    return out
end

local function build_ssh_args(remote_cmd)
    local ssh_exec = find_exec('ssh')
    local host = self.config.remote_ssh_host
    local user = self.config.remote_ssh_user
    local port = tonumber(self.config.remote_ssh_port) or 22
    local hostspec = (user and user ~= '') and (user .. '@' .. host) or host

    local args = { ssh_exec }
    if port and port ~= 22 then
        table.insert(args, '-p')
        table.insert(args, tostring(port))
    end
    if self.config.remote_ssh_identity_file and self.config.remote_ssh_identity_file ~= '' then
        local key_path = self.config.remote_ssh_identity_file
        local info = utils.file_info(key_path)
        if info and info.is_file then
            table.insert(args, '-i')
            table.insert(args, key_path)
        else
            msg.warn("remote_ssh_identity_file is set but not accessible: " .. tostring(key_path) .. ". Ignoring -i.")
        end
    end
    if self.config.remote_ssh_extra_args and self.config.remote_ssh_extra_args ~= '' then
        local extra = h.parse_shell_like_args(self.config.remote_ssh_extra_args)
        for _, a in ipairs(extra) do table.insert(args, a) end
    end
    table.insert(args, hostspec)
    -- IMPORTANT: pass the entire remote command line as ONE argument to avoid ssh splitting.
    table.insert(args, remote_cmd)
    return args
end

local function run_ffmpeg_subprocess(ffmpeg_args, completion_fn, override_settings, track_async_fn)
    local function track(result)
        if type(completion_fn) == 'function' and type(track_async_fn) == 'function' then
            track_async_fn(result)
        end
        return result
    end
    if not is_remote_ffmpeg_enabled() then
        return track(h.subprocess(ffmpeg_args, completion_fn, override_settings))
    end
    if h.is_empty(remote_staging_dir_local()) then
        msg.warn('Remote FFmpeg enabled but remote_encode_staging_dir_local is empty. Falling back to local FFmpeg.')
        return track(h.subprocess(ffmpeg_args, completion_fn, override_settings))
    end
    if not is_remote_staging_local_available() then
        msg.warn('Remote FFmpeg enabled but remote_encode_staging_dir_local is not available. Falling back to local FFmpeg.')
        return track(h.subprocess(ffmpeg_args, completion_fn, override_settings))
    end

    local remote_exec = (self.config.remote_ffmpeg_exec and self.config.remote_ffmpeg_exec ~= '') and self.config.remote_ffmpeg_exec or 'ffmpeg'
    local remote_args = {}
    for i, v in ipairs(ffmpeg_args) do
        if i == 1 then
            table.insert(remote_args, remote_exec)
        else
            table.insert(remote_args, v)
        end
    end
    remote_args = remap_ffmpeg_args_for_remote(remote_args)

    -- Encode args as JSON, then base64.
    -- IMPORTANT: On Windows OpenSSH servers, very long ssh exec commands can fail to spawn and emit
    -- "exec request failed on channel 0". To avoid command-length limits (especially with long codec params),
    -- write the base64 payload into the shared staging dir and have the remote PowerShell read it.
    local json = json_string_array(remote_args)
    local b64 = base64.enc(json)

    local local_stage = remote_staging_dir_local()
    local remote_stage = remote_staging_dir_remote()
    if h.is_empty(remote_stage) then
        -- If unset, assume both machines see the same path.
        remote_stage = local_stage
    end

    local payload_filename = make_unique_staging_filename('MPV Anki Clips_args', '.b64')
    local payload_local_path = utils.join_path(local_stage, payload_filename)
    local payload_remote_path = utils.join_path(remote_stage, payload_filename)

    local wrote_payload = false
    local f = io.open(payload_local_path, 'wb')
    if f then
        f:write(b64)
        f:close()
        wrote_payload = true
    else
        msg.warn('Remote FFmpeg: failed to write args payload to staging dir: ' .. tostring(payload_local_path) .. '. Falling back to inline payload.')
    end

    local remote_cmd
    if wrote_payload then
        local ps = "$ProgressPreference='SilentlyContinue'; $p='" .. ps_single_quote(payload_remote_path) .. "'; $b=[IO.File]::ReadAllText($p); $j=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)); $a=ConvertFrom-Json $j; if ($a.Length -gt 1) { & $a[0] @($a[1..($a.Length-1)]) } else { & $a[0] }"
        remote_cmd = 'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' .. ps_encoded_command(ps)
    else
        -- Inline fallback (may hit command length limits on some SSH servers)
        local ps = "$ProgressPreference='SilentlyContinue'; $b='" .. ps_single_quote(b64) .. "'; $j=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)); $a=ConvertFrom-Json $j; if ($a.Length -gt 1) { & $a[0] @($a[1..($a.Length-1)]) } else { & $a[0] }"
        remote_cmd = 'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' .. ps_encoded_command(ps)
    end

    local ssh_args = build_ssh_args(remote_cmd)

    -- Store a human-readable command for the UI
    self.last_encode_command = string.format('REMOTE(%s): %s', tostring(self.config.remote_ssh_host), table.concat(remote_args, ' '))
    self.last_encode_filesize = nil
    self.last_encode_duration = nil

    local function cleanup_payload_file()
        if wrote_payload and self.config and self.config.remote_encode_cleanup then
            os.remove(payload_local_path)
        end
    end

    if type(completion_fn) == 'function' then
        return track(h.subprocess(ssh_args, function(success, result)
            cleanup_payload_file()
            return completion_fn(success, result)
        end, override_settings))
    else
        local res = h.subprocess(ssh_args, nil, override_settings)
        cleanup_payload_file()
        return res
    end
end

local function toms(timestamp)
    return string.format("%.3f", timestamp or 0) -- Default to 0 if nil
end

local function make_scale_filter(width, height)
    local flags = self.config.video_sc_method or "lanczos"
    return string.format(
        "scale='min(%d,iw)':'min(%d,ih)':flags=%s+accurate_rnd",
        width, height, flags
    )
end

local function video_scale_filter()
    return make_scale_filter(self.config.video_width, self.config.video_height)
end

-- Parse loudnorm stats from FFmpeg output (JSON format)
local function parse_loudnorm_stats(output)
    local json_start = output:find("{")
    local json_end = output:find("}.-$")
    if json_start and json_end then
        local json_str = output:sub(json_start, json_end)
        local json = utils.parse_json(json_str)
        if json then
            local stats = {
                input_i = json.input_i or "-23",
                input_tp = json.input_tp or "-2",
                input_lra = json.input_lra or "7",
                input_thresh = json.input_thresh,
                output_i = json.output_i,
                output_tp = json.output_tp,
                output_lra = json.output_lra,
                output_thresh = json.output_thresh,
                normalization_type = json.normalization_type,
                target_offset = json.target_offset,
            }
            return stats
        else
            msg.error("Failed to parse JSON from extracted string: " .. json_str)
            return nil
        end
    else
        msg.error("No valid JSON found in loudnorm output")
        return nil
    end
end

-- Build a null sink appropriate for the platform for ffmpeg two-pass first run
local function ffmpeg_null_sink()
    if h.is_win() then
        return 'NUL'
    else
        return '-'
    end
end

-- Escape ':' in values for colon-delimited ffmpeg options (e.g., -svtav1-params)
-- Needed on Windows where paths contain a drive letter like C:\ which breaks parsing.
-- Only apply to the VALUE portion (do not pass a whole k=v list here).
local function escape_ffmpeg_param_value(value)
    if not value or type(value) ~= 'string' then return value end
    -- Avoid backslash being treated as an escape by codec param parser:
    -- convert backslashes to forward slashes (Windows accepts '/')
    local normalized = value:gsub('\\', '/')
    -- Escape colon separators inside the value so ffmpeg doesn't split them
    -- Example: C:/path -> C\:/path
    normalized = normalized:gsub(':', '\\:')
    return normalized
end

-- Build an x265 stats path value safe for -x265-params (no spaces, escaped drive colon)
local function x265_stats_value_from_prefix(prefix_path)
    -- Ensure .log suffix for consistency
    local path = prefix_path
    if not path:lower():match('%.log$') then
        path = path .. '.log'
    end
    return escape_ffmpeg_param_value(path)
end

-- Convert an escaped param path back to a normal filesystem path for logging/probing
local function param_value_to_fs_path(value)
    if not value or type(value) ~= 'string' then return value end
    -- Undo drive-colon escaping and keep forward slashes (Windows accepts both)
    local unescaped = value:gsub('\\:', ':')
    return unescaped
end

-- Determine whether a custom ffmpeg arg token is applicable for the selected codec.
-- Filters out obviously codec-specific flags when the active codec differs (helps during fallbacks).
local function allow_custom_arg_for_codec(token, codec)
    if type(token) ~= 'string' then return true end
    local t = token
    -- Normalize to leading key if passed as key=value
    local key = t:match('^([^=]+)=') or t
    key = key:lower()
    -- libsvtav1 specific
    if key:find('%-svtav1%-%w+') or key:find('svtav1%-params') then
        return codec == 'libsvtav1'
    end
    -- libx265 specific
    if key:find('%-x265%-%w+') or key == '-x265-params' then
        return codec == 'libx265'
    end
    -- librav1e specific
    if key:find('%-rav1e%-%w+') then
        return codec == 'librav1e'
    end
    -- libaom-av1 specific common flags
    if key == '-cpu-used' then
        return codec == 'libaom-av1'
    end
    -- libvpx/libvpx-vp9 specific
    if key == '-row-mt' or key == '-tile-columns' or key == '-tile-rows' then
        return codec == 'libvpx' or codec == 'libvpx-vp9'
    end
    -- Otherwise unknown or generic flag; allow
    return true
end

-- Build a stable, persistent two-pass prefix in the system temp dir.
-- This will be overwritten each encode and left on disk for inspection.
local function persistent_pass_prefix()
    -- When remote ffmpeg is enabled we must write passlog files into the shared staging directory
    -- so the remote machine can create them and this machine can clean them up.
    if is_remote_ffmpeg_enabled() and not h.is_empty(remote_staging_dir_remote()) then
        return utils.join_path(remote_staging_dir_remote(), make_unique_staging_filename('MPV Anki Clips_twopass_stats', ''))
    end
    local tmpdir = platform.tmp_dir() or mp.get_property("working-directory") or "."
    return utils.join_path(tmpdir, "MPV Anki Clips_twopass_stats")
end

local generated_subtitle_files = {}

local function subtitle_timestamp_seconds(value)
    local text = tostring(value or '')
    local hours, minutes, seconds, fraction = text:match('^(%d+):(%d%d):(%d%d)[,.](%d+)$')
    if not hours then
        minutes, seconds, fraction = text:match('^(%d+):(%d%d)[,.](%d+)$')
        hours = minutes and '0' or nil
    end
    if not hours then
        hours, minutes, seconds = text:match('^(%d+):(%d%d):(%d%d)$')
        fraction = '0'
    end
    if not hours then return nil end
    return tonumber(hours) * 3600 + tonumber(minutes) * 60 + tonumber(seconds) + tonumber(fraction) / (10 ^ #fraction)
end

local function subtitle_cue_overlaps(cue_start, cue_end, range_start, range_end)
    return cue_start <= range_end and cue_end >= range_start
end

local function trim_block_subtitles(content, range_start, range_end)
    local newline = content:find('\r\n', 1, true) and '\r\n' or '\n'
    local normalized = content:gsub('\r\n', '\n'):gsub('\r', '\n')
    local trailing_newline = normalized:sub(-1) == '\n'
    local kept = {}
    local cue_count = 0

    for block in (normalized .. '\n\n'):gmatch('(.-)\n\n+') do
        if block ~= '' then
            local cue_start, cue_end
            for line in (block .. '\n'):gmatch('(.-)\n') do
                local start_value, end_value = line:match('^%s*(%d+:%d%d:%d%d[,.]%d+)%s+%-%->%s+(%d+:%d%d:%d%d[,.]%d+)')
                if not start_value then
                    start_value, end_value = line:match('^%s*(%d+:%d%d[,.]%d+)%s+%-%->%s+(%d+:%d%d[,.]%d+)')
                end
                if start_value then
                    cue_start = subtitle_timestamp_seconds(start_value)
                    cue_end = subtitle_timestamp_seconds(end_value)
                    break
                end
            end
            if not cue_start or subtitle_cue_overlaps(cue_start, cue_end, range_start, range_end) then
                table.insert(kept, block)
                if cue_start then cue_count = cue_count + 1 end
            end
        end
    end

    local result = table.concat(kept, '\n\n')
    if trailing_newline and result ~= '' then result = result .. '\n' end
    return result:gsub('\n', newline), cue_count
end

local function trim_ass_subtitles(content, range_start, range_end)
    local newline = content:find('\r\n', 1, true) and '\r\n' or '\n'
    local normalized = content:gsub('\r\n', '\n'):gsub('\r', '\n')
    local trailing_newline = normalized:sub(-1) == '\n'
    local kept = {}
    local cue_count = 0

    for line in (normalized .. '\n'):gmatch('(.-)\n') do
        local prefix, first_field, start_value, end_value = line:match('^(Dialogue:%s*)([^,]*),([^,]*),([^,]*)')
        if not prefix then
            table.insert(kept, line)
        else
            local cue_start = subtitle_timestamp_seconds(start_value)
            local cue_end = subtitle_timestamp_seconds(end_value)
            if not cue_start or subtitle_cue_overlaps(cue_start, cue_end, range_start, range_end) then
                table.insert(kept, line)
                if cue_start then cue_count = cue_count + 1 end
            end
        end
    end

    local result = table.concat(kept, '\n')
    if trailing_newline then result = result .. '\n' end
    return result:gsub('\n', newline), cue_count
end

local function trim_external_subtitle_content(path, content, range_start, range_end)
    local extension = tostring(path or ''):lower():match('(%.[^%.\\/]+)$')
    if extension == '.srt' or extension == '.vtt' then
        return trim_block_subtitles(content, range_start, range_end)
    end
    if extension == '.ass' or extension == '.ssa' then
        return trim_ass_subtitles(content, range_start, range_end)
    end
    return nil, nil
end

local function prepare_external_subtitle_path(path, range_start, range_end)
    if self.config.fix_subtitle_duration ~= true and self.config.fix_subtitle_duration ~= 'yes' then
        return path
    end

    local input = io.open(path, 'rb')
    if not input then
        msg.warn('Could not read external subtitle for trimming: ' .. tostring(path))
        return path
    end
    local content = input:read('*a')
    input:close()

    local trimmed, cue_count = trim_external_subtitle_content(path, content, range_start, range_end)
    if not trimmed then
        msg.warn('Subtitle duration fixing supports SRT, WebVTT, ASS, and SSA external subtitles; using original file: ' .. tostring(path))
        return path
    end
    if cue_count == 0 then
        return nil, 0
    end

    local extension = tostring(path):match('(%.[^%.\\/]+)$') or '.srt'
    local temp_dir = is_remote_ffmpeg_enabled() and remote_staging_dir_local() or platform.tmp_dir()
    temp_dir = h.is_empty(temp_dir) and (working_directory_snapshot() or '.') or temp_dir
    local temp_path = utils.join_path(temp_dir, make_unique_staging_filename('mpv_anki_clips_trimmed_subtitle', extension))
    local output = io.open(temp_path, 'wb')
    if not output then
        msg.warn('Could not create trimmed external subtitle; using original file: ' .. tostring(path))
        return path
    end
    output:write(trimmed)
    output:close()
    generated_subtitle_files[temp_path] = true
    msg.info(string.format('Trimmed external subtitle to encode range (%d cues kept): %s', cue_count, temp_path))
    return temp_path, cue_count
end

local function cleanup_external_subtitle_files(args)
    for _, arg in ipairs(args or {}) do
        if generated_subtitle_files[arg] then
            os.remove(arg)
            generated_subtitle_files[arg] = nil
        end
    end
end

local function external_subtitle_language(track_lang, path)
    if not iso639.is_undetermined(track_lang) then
        return iso639.to_ffmpeg(track_lang)
    end

    local filename = tostring(path or ''):gsub('\\', '/'):match('([^/]+)$') or ''
    local stem = filename:match('^(.*)%.[^%.]+$') or filename
    local filename_lang = stem:match('[%._%-]([%a][%a][%a]?)$')
    if iso639.is_known(filename_lang) then
        return iso639.to_ffmpeg(filename_lang)
    end

    return iso639.to_ffmpeg(self.config and self.config.external_subtitle_unknown_language or iso639.unknown)
end

local function external_subtitle_track_title(path)
    local filename = tostring(path or ''):gsub('\\', '/')
    filename = filename:match('([^/]+)$') or filename
    filename = filename:match('^(.*)%.[^%.]+$') or filename
    filename = filename:lower()
    if filename:match('_ocr$') then return 'OCR' end
    if filename:match('_stt$') then return 'speech-to-text' end
    return 'subtitle track'
end

local function append_external_subtitle_metadata(args, output_index, language, title)
    local metadata_key = '-metadata:s:s:' .. tostring(output_index)
    if title then
        table.insert(args, metadata_key)
        table.insert(args, 'title=' .. title)
    end
    table.insert(args, metadata_key)
    table.insert(args, 'language=' .. language)
end

-- Merge one or more occurrences of a codec params switch (e.g., -x265-params, -x264-params, -svtav1-params, -rav1e-params)
-- into a single option. If extra_params is provided (string like "k=v:k2=v2"), it will be merged/overridden.
-- IMPORTANT: split on unescaped ':' so values like Windows drive letters escaped as 'C\:/path' are preserved.
local function split_unescaped_colon(s)
    if not s or s == '' then return {} end
    local parts = {}
    local buf = {}
    local i, len = 1, #s
    while i <= len do
        local c = s:sub(i, i)
        if c == ':' then
            -- Count preceding backslashes to determine if this ':' is escaped
            local j, bs = i - 1, 0
            while j >= 1 and s:sub(j, j) == '\\' do
                bs = bs + 1
                j = j - 1
            end
            if bs % 2 == 1 then
                table.insert(buf, c) -- escaped ':' stays in token
            else
                table.insert(parts, table.concat(buf))
                buf = {}
            end
        else
            table.insert(buf, c)
        end
        i = i + 1
    end
    table.insert(parts, table.concat(buf))
    return parts
end

local function trim(s)
    if type(s) ~= 'string' then return s end
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function looks_like_output_path(token)
    if type(token) ~= 'string' then return false end
    if token == 'NUL' or token == '-' then return true end
    if token:match('^%a:[\\/]') then return true end
    if token:find('/') or token:find('\\') then return true end
    if token:match('%.[%w%d]+$') then return true end
    return false
end

local function merge_codec_params(args, param_key, extra_params)
    if not args or type(args) ~= 'table' then return end
    if not param_key or type(param_key) ~= 'string' then return end
    -- Collect all existing -x265-params values and indices
    local indices = {}
    local first_index = nil
    local merged = {}
    local function ingest(param_str)
        if not param_str or param_str == '' then return end
        for _, token in ipairs(split_unescaped_colon(tostring(param_str))) do
            token = trim(token)
            local k, v = token:match("^%-%-?([^=]+)=(.+)$")
            if not k then k, v = token:match("^([^=]+)=(.+)$") end
            if k and v then
                -- normalize keys like "--bitrate" -> "bitrate"
                k = k:gsub("^%-%-?", "")
                merged[k] = v
            end
        end
    end
    for i = 1, #args do
        if args[i] == param_key and args[i+1] then
            table.insert(indices, i)
            if not first_index or i < first_index then first_index = i end
            ingest(args[i+1])
        end
    end
    -- Ingest extra params last so they take precedence
    if extra_params and extra_params ~= '' then ingest(extra_params) end
    if #indices == 0 and not extra_params then return end
    -- Build combined string
    local parts = {}
    for k, v in pairs(merged) do
        table.insert(parts, string.format("%s=%s", k, v))
    end
    table.sort(parts) -- deterministic output
    local combined = table.concat(parts, ":")
    -- Remove all old occurrences (from last to first to keep indices valid)
    for n = #indices, 1, -1 do
        local idx = indices[n]
        table.remove(args, idx)      -- remove param key
        table.remove(args, idx)      -- remove its value (now at the same index)
    end
    -- Decide insertion point:
    -- 1) If param existed before, re-insert at the first occurrence index to preserve ordering
    -- 2) Else, if the last token looks like an output path/sink, insert before it
    -- 3) Else, append at the end
    local insert_pos
    if first_index then
        insert_pos = math.min(first_index, #args + 1)
    elseif looks_like_output_path(args[#args]) then
        insert_pos = #args
    else
        insert_pos = #args + 1
    end
    table.insert(args, insert_pos, param_key)
    table.insert(args, insert_pos + 1, combined)
end

-- Legacy encoder backend (unused)
local function validate_file_integrity(file_path, expected_duration, is_input)
    local file_type = is_input and "input" or "output"
    logger.info_cat('file_integrity', "Validating " .. file_type .. " file integrity: " .. file_path)

    -- Check if file exists and has non-zero size
    local file_info = h.safe_file_info(file_path)
    if not file_info or not file_info.is_file then
        local error_msg = file_type .. " file does not exist: " .. file_path
        msg.error(error_msg)
        mp.osd_message("File integrity error: " .. error_msg, 5)
        return false, error_msg
    end

    if file_info.size == 0 then
        local error_msg = file_type .. " file is empty (0 bytes): " .. file_path
        msg.error(error_msg)
        mp.osd_message("File integrity error: " .. error_msg, 5)
        return false, error_msg
    end

    logger.info_cat('file_integrity', file_type .. " file size: " .. tostring(file_info.size) .. " bytes")

    -- Use ffprobe to validate file structure and get metadata
    local ffprobe_exec = find_exec("ffprobe")

    local probe_args = {
        ffprobe_exec,
        "-v", "quiet",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        "-i", file_path
    }

    logger.info_cat('file_integrity', "Running ffprobe validation: " .. table.concat(probe_args, " "))
    local probe_result = h.subprocess(probe_args, nil, { capture_stdout = true, capture_stderr = true, log_category = 'file_integrity' })
    if not probe_result or probe_result.status ~= 0 then
        local error_msg = "Failed to probe " .. file_type .. " file with ffprobe: " .. file_path
        -- Check if this is likely a "command not found" error
        local is_command_not_found = false
        if probe_result and probe_result.stderr then
            is_command_not_found = probe_result.stderr:lower():find("not found") or
                                   probe_result.stderr:lower():find("no such file") or
                                   probe_result.stderr:lower():find("command not found")
            msg.error("ffprobe stderr: " .. probe_result.stderr)
        end

        if is_command_not_found then
            msg.warn("ffprobe not available, skipping detailed validation")
            logger.info_cat('file_integrity', file_type .. " file basic validation passed (ffprobe not available)")
            return true, nil
        else
            msg.error(error_msg)
            mp.osd_message("File corruption detected: Invalid " .. file_type .. " file format", 5)
            return false, error_msg
        end
    end

    -- Parse ffprobe output
    local probe_data = utils.parse_json(probe_result.stdout)
    if not probe_data then
        local error_msg = "Failed to parse ffprobe JSON output for " .. file_type .. " file"
        msg.error(error_msg)
        mp.osd_message("File corruption detected: Unable to read " .. file_type .. " file metadata", 5)
        return false, error_msg
    end

    -- Check format information
    if not probe_data.format then
        local error_msg = file_type .. " file has no format information"
        msg.error(error_msg)
        mp.osd_message("File corruption detected: Missing format info in " .. file_type .. " file", 5)
        return false, error_msg
    end

    local duration = tonumber(probe_data.format.duration)
    logger.info_cat('file_integrity', file_type .. " file duration: " .. tostring(duration) .. " seconds")

    -- For output files, check video stream duration specifically (not affected by subtitle streams)
    if not is_input and expected_duration and probe_data.streams then
        local video_duration = nil
        local video_dimensions_ok = true
        for _, stream in ipairs(probe_data.streams) do
            if stream.codec_type == "video" and stream.duration then
                video_duration = tonumber(stream.duration)
                if (tonumber(stream.width) or 0) == 0 or (tonumber(stream.height) or 0) == 0 then
                    video_dimensions_ok = false
                end
                break
            end
        end

        if video_duration then
            local duration_diff = math.abs(video_duration - expected_duration)
            -- Dynamic tolerance: tighter for short clips
            local tolerance = math.max(0.2, math.min(2.0, expected_duration * 0.10))
            if duration_diff > tolerance then
                local error_msg = string.format("Output file video duration mismatch: expected %.2f, got %.2f seconds", expected_duration, video_duration)
                msg.error(error_msg)
                mp.osd_message("File corruption detected: Video duration mismatch in output file", 5)
                return false, error_msg
            end
            if not video_dimensions_ok then
                local error_msg = "Output file video stream has invalid dimensions (0x0)"
                msg.error(error_msg)
                mp.osd_message("File corruption detected: Invalid video dimensions", 5)
                return false, error_msg
            end
            logger.info_cat('file_integrity', "Video duration validation passed (diff: " .. tostring(duration_diff) .. "s)")
        else
            -- Fallback strategies: try derive duration from nb_frames/fps or format.duration
            local derived_duration = nil
            for _, stream in ipairs(probe_data.streams) do
                if stream.codec_type == "video" then
                    local nb_frames = tonumber(stream.nb_frames)
                    local avg_rate = stream.avg_frame_rate -- like "30000/1001"
                    if nb_frames and avg_rate and avg_rate ~= "0/0" then
                        local num, den = avg_rate:match("^(%d+)%/(%d+)$")
                        num, den = tonumber(num), tonumber(den)
                        if num and den and den ~= 0 then
                            derived_duration = nb_frames / (num/den)
                            break
                        end
                    end
                end
            end
            if not derived_duration and probe_data.format and probe_data.format.duration then
                derived_duration = tonumber(probe_data.format.duration)
            end
            if derived_duration then
                local duration_diff = math.abs(derived_duration - expected_duration)
                local tolerance = math.max(0.3, math.min(2.5, expected_duration * 0.12))
                if duration_diff <= tolerance then
                    logger.info_cat('file_integrity', "Video duration approx validation passed via fallback (diff: " .. string.format("%.3f", duration_diff) .. "s)")
                else
                    msg.warn("Video duration could not be confirmed precisely (diff: " .. string.format("%.3f", duration_diff) .. "s). Proceeding.")
                end
            else
                logger.info_cat('file_integrity', "Could not determine video stream duration; skipping duration validation")
            end
        end
    end

    -- Check for video and audio streams
    local has_video = false
    local has_audio = false
    if probe_data.streams then
        for _, stream in ipairs(probe_data.streams) do
            if stream.codec_type == "video" then
                has_video = true
                logger.info_cat('file_integrity', "Video stream: " .. stream.codec_name .. ", " .. tostring(stream.width) .. "x" .. tostring(stream.height))
            elseif stream.codec_type == "audio" then
                has_audio = true
                logger.info_cat('file_integrity', "Audio stream: " .. stream.codec_name .. ", " .. tostring(stream.sample_rate) .. "Hz")
            end
        end
    end

    if not has_video and not has_audio then
        local error_msg = file_type .. " file has no video or audio streams"
        msg.error(error_msg)
        mp.osd_message("File corruption detected: No media streams in " .. file_type .. " file", 5)
        return false, error_msg
    end

    logger.info_cat('file_integrity', file_type .. " file integrity validation passed")
    return true, nil
end

local function check_input_file_integrity(source_path, start_time, end_time)
    local expected_duration = end_time - start_time
    logger.info_cat('file_integrity', "Checking input file integrity for clip: " .. tostring(start_time) .. " - " .. tostring(end_time) ..
             " (expected duration: " .. tostring(expected_duration) .. "s)")

    local success, error_msg = validate_file_integrity(source_path, nil, true)
    if not success then
        return false, error_msg
    end

    -- Additional check: verify we can seek to the timestamps
    local ffprobe_exec = find_exec("ffprobe")
    local seek_args = {
        ffprobe_exec,
        "-v", "quiet",
        "-ss", toms(start_time),
        "-i", source_path,
        "-frames:v", "1",
        "-f", "null",
        "-"
    }

    logger.info_cat('file_integrity', "Testing seek capability: " .. table.concat(seek_args, " "))
    local seek_result = h.subprocess(seek_args, nil, { capture_stdout = true, capture_stderr = true, log_category = 'file_integrity' })
    if not seek_result or seek_result.status ~= 0 then
        -- Check if this is a "command not found" error
        local is_command_not_found = false
        if seek_result and seek_result.stderr then
            is_command_not_found = seek_result.stderr:lower():find("not found") or
                                   seek_result.stderr:lower():find("no such file") or
                                   seek_result.stderr:lower():find("command not found")
            msg.debug("Seek test stderr: " .. seek_result.stderr)
        end

        if is_command_not_found then
            logger.info_cat('file_integrity', "Skipping seek validation (ffprobe not available)")
        else
            -- Seek test failed, but main validation passed, so this might not be corruption
            -- Log as warning but don't fail the integrity check
            msg.warn("Seek test failed for timestamps " .. tostring(start_time) .. " - " .. tostring(end_time) ..
                    ", but file appears valid. Continuing with encoding.")
            if seek_result and seek_result.stderr and seek_result.stderr ~= "" then
                msg.debug("Seek test stderr: " .. seek_result.stderr)
            end
        end
    else
    logger.info_cat('file_integrity', "Input file seek validation passed")
    end

    return true, nil
end

local function check_output_file_integrity(output_path, expected_duration)
    logger.info_cat('file_integrity', "Checking output file integrity (expected duration: " .. tostring(expected_duration) .. "s)")
        local finfo = h.safe_file_info(output_path)
        if finfo and finfo.size then self.last_encode_filesize = finfo.size end
        self.last_encode_duration = expected_duration
        if finfo and finfo.size and finfo.size > 0 then
            local probe_args = { 'ffprobe','-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1', output_path }
            local pres = h.subprocess(probe_args, nil, { log_command = false, capture_stdout = true, capture_stderr = true })
            if pres and pres.status == 0 and pres.stdout and pres.stdout ~= '' then
                local val = tonumber((pres.stdout:gsub('\r',''):gsub('\n','')))
                if val and val > 0 then self.last_encode_duration = val end
            end
        end
        return validate_file_integrity(output_path, expected_duration, false)
end

------------------------------------------------------------
-- ffmpeg encoder

local ffmpeg = {}

ffmpeg.exec = configured_ffmpeg_exec

ffmpeg.prepend = function(...)
    ffmpeg.exec = configured_ffmpeg_exec
    return {
        ffmpeg.exec, "-hide_banner", "-nostdin", "-y",
        ...,
    }
end

ffmpeg.make_loudnorm_measure_args = function(source_path, start_timestamp, end_timestamp)
    local args = ffmpeg.prepend(
        '-ss', toms(start_timestamp),
        '-to', toms(end_timestamp),
        '-i', source_path,
        '-af', 'loudnorm=print_format=json',
        '-f', 'null',
        '-'
    )
    return args
end

ffmpeg.make_video_args = function(source_path, output_path, start_timestamp, end_timestamp, loudnorm_stats)
    local video_encoder_args, audio_encoder_args, subtitle_args = {}, {}, {}
    local input_args = { '-i', source_path }
    local map_args = {}
    local extra_inputs = {}
    local input_index = 1
    local include_video_stream = output_has_video_stream()
    local include_audio_stream = output_has_audio_stream()

    if include_video_stream then
        table.insert(map_args, '-map')
        table.insert(map_args, '0:v:0')
    else
        table.insert(map_args, '-vn')
    end

    if include_audio_stream then
        local preferred_audio_maps = preferred_audio_maps_from_snapshot()
        for _, audio_map in ipairs(preferred_audio_maps) do
            table.insert(map_args, '-map')
            table.insert(map_args, audio_map)
        end
    else
        table.insert(map_args, '-an')
    end

    local vbitrate = self.config.video_bitrate or "200k"
    local abitrate = self.config.audio_bitrate or "64k"
    local fade_in = tonumber(self.config.audio_fade_in) or 0
    local fade_out = tonumber(self.config.audio_fade_out) or 0
    local clip_duration = end_timestamp - start_timestamp
    local vqm = self.config.video_quality_management or ((self.config.allow_combined_crf_bitrate == true or self.config.allow_combined_crf_bitrate == "yes") and 'allow_combined_crf_bitrate' or 'enabled')
    local aqm = self.config.audio_quality_management or ((self.config.allow_combined_vbr_bitrate == true or self.config.allow_combined_vbr_bitrate == "yes") and 'allow_combined_vbr_bitrate' or 'enabled')
    local disable_video_q = (vqm == 'disabled')
    local allow_combined_video = (vqm == 'allow_combined_crf_bitrate')
    local disable_audio_q = (aqm == 'disabled')
    local allow_combined_audio = (aqm == 'allow_combined_vbr_bitrate')

    if include_video_stream then
        if not disable_video_q then
            if self.config.video_use_crf then
                if allow_combined_video then
                    msg.info("Using video CRF + bitrate: CRF=" .. tostring(self.config.video_crf) .. ", b:v=" .. vbitrate)
                else
                    msg.info("Using video CRF: " .. tostring(self.config.video_crf))
                end
            else
                msg.info("Using video bitrate: " .. vbitrate)
            end
        else
            msg.info("Video quality management disabled: not passing -crf/-b:v")
        end
    else
        msg.info("Video stream disabled or unavailable: skipping video encoding")
    end

    if include_audio_stream then
        if not disable_audio_q then
            if self.config.audio_use_vbr then
                if allow_combined_audio then
                    msg.info("Using audio VBR + bitrate: VBR + b:a=" .. abitrate)
                else
                    msg.info("Using audio VBR (codec default)")
                end
            else
                msg.info("Using audio bitrate: " .. abitrate)
            end
        else
            msg.info("Audio quality management disabled: not passing -vbr/-b:a")
        end
    else
        msg.info("Audio stream disabled or unavailable: skipping audio encoding")
    end

    msg.info("Audio fade-in: " .. fade_in .. "s")
    msg.info("Audio fade-out: " .. fade_out .. "s")
    msg.info("Clip duration: " .. clip_duration .. "s")
    msg.info("Start timestamp: " .. tostring(start_timestamp))
    msg.info("End timestamp: " .. tostring(end_timestamp))
    msg.info("Source path: " .. tostring(source_path))

    if fade_in > clip_duration / 2 then
        fade_in = clip_duration / 2
        msg.warn("Fade-in duration capped to " .. fade_in .. "s to fit clip duration")
    end
    if fade_out > clip_duration / 2 then
        fade_out = clip_duration / 2
        msg.warn("Fade-out duration capped to " .. fade_out .. "s to fit clip duration")
    end

    if source_path and not source_path:match('^[/\\]') and not source_path:match('^[a-zA-Z]:') then
        local working_dir = mp.get_property("working-directory")
        if working_dir then
            source_path = utils.join_path(working_dir, source_path)
        else
            msg.error("Cannot resolve relative source path without working directory")
        end
    end
    msg.info("Resolved source path: " .. tostring(source_path))

    if include_video_stream then
        video_encoder_args = { '-c:v', self.config.video_codec }

        if self.config.video_codec == 'libx264' or self.config.video_codec == 'libx265' then
            if not disable_video_q then
                if self.config.video_use_crf then
                    table.insert(video_encoder_args, '-crf')
                    table.insert(video_encoder_args, tostring(self.config.video_crf or 23))
                    if allow_combined_video then
                        table.insert(video_encoder_args, '-b:v')
                        table.insert(video_encoder_args, vbitrate)
                    end
                else
                    table.insert(video_encoder_args, '-b:v')
                    table.insert(video_encoder_args, vbitrate)
                end
            end
            if self.config.video_preset then
                table.insert(video_encoder_args, '-preset')
                table.insert(video_encoder_args, self.config.video_preset)
            end
        elseif self.config.video_codec == 'libvpx' or self.config.video_codec == 'libvpx-vp9' then
            if not disable_video_q then
                if self.config.video_use_crf then
                    table.insert(video_encoder_args, '-crf')
                    table.insert(video_encoder_args, tostring(self.config.video_crf or 30))
                    table.insert(video_encoder_args, '-b:v')
                    table.insert(video_encoder_args, allow_combined_video and vbitrate or '0')
                else
                    table.insert(video_encoder_args, '-b:v')
                    table.insert(video_encoder_args, vbitrate)
                end
            end
        elseif self.config.video_codec == 'libsvtav1' then
            if not disable_video_q then
                if self.config.video_use_crf then
                    table.insert(video_encoder_args, '-crf')
                    table.insert(video_encoder_args, tostring(self.config.video_crf or 30))
                    if allow_combined_video then
                        table.insert(video_encoder_args, '-b:v')
                        table.insert(video_encoder_args, vbitrate)
                    end
                else
                    table.insert(video_encoder_args, '-b:v')
                    table.insert(video_encoder_args, vbitrate)
                end
            end
            if self.config.video_preset then
                table.insert(video_encoder_args, '-preset')
                table.insert(video_encoder_args, self.config.video_preset)
            end
        elseif self.config.video_codec == 'librav1e' then
            if not disable_video_q then
                if self.config.video_use_crf then
                    table.insert(video_encoder_args, '-rav1e-params')
                    table.insert(video_encoder_args, 'qp=' .. tostring(self.config.video_crf or 100))
                    if allow_combined_video then
                        table.insert(video_encoder_args, '-b:v')
                        table.insert(video_encoder_args, vbitrate)
                    end
                else
                    table.insert(video_encoder_args, '-b:v')
                    table.insert(video_encoder_args, vbitrate)
                end
            end
            if self.config.video_preset then
                table.insert(video_encoder_args, '-speed')
                table.insert(video_encoder_args, self.config.video_preset)
            end
        elseif self.config.video_codec == 'libaom-av1' then
            if not disable_video_q then
                if self.config.video_use_crf then
                    table.insert(video_encoder_args, '-crf')
                    table.insert(video_encoder_args, tostring(self.config.video_crf or 30))
                    if allow_combined_video then
                        table.insert(video_encoder_args, '-b:v')
                        table.insert(video_encoder_args, vbitrate)
                    end
                else
                    table.insert(video_encoder_args, '-b:v')
                    table.insert(video_encoder_args, vbitrate)
                end
            end
            if self.config.video_preset then
                table.insert(video_encoder_args, '-cpu-used')
                table.insert(video_encoder_args, self.config.video_preset)
            end
        elseif self.config.video_codec == 'av1_nvenc' then
            if not disable_video_q then
                table.insert(video_encoder_args, '-b:v')
                table.insert(video_encoder_args, vbitrate)
            end
            if self.config.video_preset then
                table.insert(video_encoder_args, '-preset')
                table.insert(video_encoder_args, self.config.video_preset)
            end
        elseif self.config.video_codec == 'av1_amf' then
            if not disable_video_q then
                table.insert(video_encoder_args, '-b:v')
                table.insert(video_encoder_args, vbitrate)
            end
            if self.config.video_preset then
                table.insert(video_encoder_args, '-quality')
                table.insert(video_encoder_args, self.config.video_preset)
            end
        elseif self.config.video_codec == 'av1_qsv' then
            if not disable_video_q then
                table.insert(video_encoder_args, '-b:v')
                table.insert(video_encoder_args, vbitrate)
            end
            if self.config.video_preset then
                table.insert(video_encoder_args, '-preset')
                table.insert(video_encoder_args, self.config.video_preset)
            end
        else
            if not disable_video_q then
                table.insert(video_encoder_args, '-b:v')
                table.insert(video_encoder_args, vbitrate)
            end
        end

        if self.config.video_custom_args and self.config.video_custom_args ~= "" then
            local custom_args = h.parse_shell_like_args(self.config.video_custom_args)
            local drop_next_value = false
            for _, arg in ipairs(custom_args) do
                if drop_next_value then
                    drop_next_value = false
                else
                    local key, val = arg:match('^%-(svtav1%-params|x265%-params|rav1e%-params)=(.+)$')
                    if key and val then
                        local opt = '-' .. key
                        if allow_custom_arg_for_codec(opt, self.config.video_codec) then
                            table.insert(video_encoder_args, opt)
                            table.insert(video_encoder_args, val)
                        end
                    else
                        local allowed = allow_custom_arg_for_codec(arg, self.config.video_codec)
                        if allowed then
                            table.insert(video_encoder_args, arg)
                        elseif not arg:find('=') then
                            drop_next_value = true
                        end
                    end
                end
            end
        end
    end

    if include_audio_stream then
        audio_encoder_args = { '-c:a', self.config.audio_codec }

        if self.config.audio_codec == 'libopus' then
            if not disable_audio_q then
                if self.config.audio_use_vbr then
                    table.insert(audio_encoder_args, '-vbr')
                    table.insert(audio_encoder_args, 'on')
                    if allow_combined_audio then
                        table.insert(audio_encoder_args, '-b:a')
                        table.insert(audio_encoder_args, abitrate)
                    end
                else
                    table.insert(audio_encoder_args, '-b:a')
                    table.insert(audio_encoder_args, abitrate)
                end
            end
        elseif self.config.audio_codec == 'aac' or self.config.audio_codec == 'libmp3lame' or self.config.audio_codec == 'libfdk_aac' then
            if not disable_audio_q and ((not self.config.audio_use_vbr) or allow_combined_audio) then
                table.insert(audio_encoder_args, '-b:a')
                table.insert(audio_encoder_args, abitrate)
            end
        else
            if not disable_audio_q then
                table.insert(audio_encoder_args, '-b:a')
                table.insert(audio_encoder_args, abitrate)
            end
        end

        if self.config.audio_custom_args and self.config.audio_custom_args ~= "" then
            local custom_args = h.parse_shell_like_args(self.config.audio_custom_args)
            for _, arg in ipairs(custom_args) do
                table.insert(audio_encoder_args, arg)
            end
        end

        local audio_filters = {}
        if fade_in > 0 then
            table.insert(audio_filters, string.format("afade=t=in:st=0:d=%.3f", fade_in))
        end
        if fade_out > 0 then
            table.insert(audio_filters, string.format("afade=t=out:st=%.3f:d=%.3f", end_timestamp - start_timestamp - fade_out, fade_out))
        end
        if self.config.loudnorm_enabled == "yes" then
            local loudnorm_filter = "loudnorm"
            loudnorm_filter = loudnorm_filter .. "=I=" .. (self.config.loudnorm_I or "-23")
            loudnorm_filter = loudnorm_filter .. ":LRA=" .. (self.config.loudnorm_LRA or "7")
            loudnorm_filter = loudnorm_filter .. ":TP=" .. (self.config.loudnorm_TP or "-2")
            if self.config.loudnorm_two_pass == "yes" and loudnorm_stats then
                loudnorm_filter = loudnorm_filter .. ":measured_I=" .. loudnorm_stats.input_i
                loudnorm_filter = loudnorm_filter .. ":measured_LRA=" .. loudnorm_stats.input_lra
                loudnorm_filter = loudnorm_filter .. ":measured_TP=" .. loudnorm_stats.input_tp
                loudnorm_filter = loudnorm_filter .. ":linear=true"
                msg.info("Applying two-pass loudnorm filter: " .. loudnorm_filter)
            else
                if self.config.loudnorm_linear == "yes" then
                    loudnorm_filter = loudnorm_filter .. ":linear=true"
                else
                    loudnorm_filter = loudnorm_filter .. ":linear=false"
                end
                msg.info("Applying single-pass loudnorm filter: " .. loudnorm_filter)
            end
            table.insert(audio_filters, loudnorm_filter)
        end
        if #audio_filters > 0 then
            table.insert(audio_encoder_args, '-af')
            table.insert(audio_encoder_args, table.concat(audio_filters, ','))
        end
    end

    -- Subtitle handling (FFmpeg only)
    if self.config.include_subtitles and self.config.video_container == 'mkv' then
        local lang_priority = {}
        for lang in self.config.subtitle_lang_priority:gmatch('[^,]+') do
            table.insert(lang_priority, lang)
        end

        -- Normalize language codes for matching (e.g., 'eng' -> 'en', 'ger' -> 'de')
        local normalized_lang_priority = {}
        for _, lang in ipairs(lang_priority) do
            if lang == 'eng' then
                table.insert(normalized_lang_priority, 'en')
            elseif lang == 'ger' then
                table.insert(normalized_lang_priority, 'de')
            else
                table.insert(normalized_lang_priority, lang)
            end
        end

        local sub_tracks = {}
        local first_sub_index = nil
        for _, track in ipairs(track_list_snapshot()) do
            if track.type == "sub" then
                local lang = track.lang or "und"
                local ff_index = track.ff_index
                local is_external = track.external
                if not first_sub_index and not is_external then first_sub_index = ff_index end
                table.insert(sub_tracks, { lang = lang, index = ff_index, external = is_external, path = is_external and track.external_filename or nil })
            end
        end

        table.sort(sub_tracks, function(a, b)
            local a_priority = #lang_priority + 1
            local b_priority = #lang_priority + 1
            local a_lang = (a.lang or ""):lower()
            local b_lang = (b.lang or ""):lower()
            local a_base = a_lang:match('^([a-z]+)')
            local b_base = b_lang:match('^([a-z]+)')
            for i, norm_lang in ipairs(normalized_lang_priority) do
                if (a_base and a_base == norm_lang) or a_lang == (lang_priority[i] or ""):lower() then a_priority = i break end
            end
            for i, norm_lang in ipairs(normalized_lang_priority) do
                if (b_base and b_base == norm_lang) or b_lang == (lang_priority[i] or ""):lower() then b_priority = i break end
            end
            return a_priority < b_priority
        end)

        subtitle_args = {}
        local output_sub_stream_index = 0
        local embedded_external_ocr = false
        local embedded_external_stt = false
        local sub_count = 0
        for i = 1, #sub_tracks do
            if sub_count < self.config.subtitle_track_count and not sub_tracks[i].external then
                local sub_index = sub_tracks[i].index - first_sub_index
                if sub_index >= 0 then
                    table.insert(subtitle_args, '-map')
                    table.insert(subtitle_args, '0:s:' .. sub_index)
                    sub_count = sub_count + 1
                    output_sub_stream_index = output_sub_stream_index + 1
                end
            end
        end

    if self.config.include_external_subtitles then
            for i = 1, #sub_tracks do
                if sub_tracks[i].external and sub_tracks[i].path then
                    local ext_path = sub_tracks[i].path
                    local ext_language = external_subtitle_language(sub_tracks[i].lang, ext_path)
                    if not source_path then
                        msg.error("Source path is nil, cannot process external subtitles")
                        break
                    end
                    if not ext_path:match('^[/\\]') and not ext_path:match('^[a-zA-Z]:') then
                        local working_dir = working_directory_snapshot()
                        if working_dir then
                            ext_path = utils.join_path(working_dir, ext_path)
                        else
                            msg.error("Cannot resolve relative external subtitle path without working directory")
                            break
                        end
                    end
                    msg.info("External subtitle path: " .. tostring(ext_path))
                    if utils.file_info(ext_path) then
                        local ext_title = external_subtitle_track_title(ext_path)
                        if ext_title == 'OCR' and embedded_external_ocr then
                            msg.info("Skipping duplicate OCR external subtitle: " .. tostring(ext_path))
                        elseif ext_title == 'speech-to-text' and embedded_external_stt then
                            msg.info("Skipping duplicate speech-to-text external subtitle: " .. tostring(ext_path))
                        else
                        -- Probe to ensure there is at least one subtitle stream
                        local ffprobe_exec = find_exec("ffprobe")
                        local probe_args = { ffprobe_exec, '-v', 'error', '-select_streams', 's', '-show_entries', 'stream=index,codec_name', '-of', 'json', ext_path }
                        local probe_res = h.subprocess(probe_args, nil, { capture_stdout = true, capture_stderr = true })
                        local has_sub_stream = false
                        if probe_res and probe_res.status == 0 then
                            local data = utils.parse_json(probe_res.stdout or '{}')
                            if data and data.streams and #data.streams > 0 then
                                has_sub_stream = true
                            end
                        end
                        if not has_sub_stream then
                            msg.warn("No subtitle stream in external file, skipping: " .. ext_path)
                        else
                        local prepared_ext_path, cue_count = prepare_external_subtitle_path(ext_path, start_timestamp, end_timestamp)
                        if cue_count == 0 then
                            msg.info("No external subtitle cues overlap the encode range, skipping: " .. ext_path)
                        else
                        table.insert(extra_inputs, '-ss')
                        table.insert(extra_inputs, toms(start_timestamp))
                        table.insert(extra_inputs, '-to')
                        table.insert(extra_inputs, toms(end_timestamp))
                        table.insert(extra_inputs, '-i')
                        table.insert(extra_inputs, prepared_ext_path)

                        table.insert(subtitle_args, '-map')
                        table.insert(subtitle_args, input_index .. ':s:0')
                        append_external_subtitle_metadata(subtitle_args, output_sub_stream_index, ext_language, ext_title)
                        if ext_title then
                            if ext_title == 'OCR' then
                                embedded_external_ocr = true
                            elseif ext_title == 'speech-to-text' then
                                embedded_external_stt = true
                            end
                        end

                        input_index = input_index + 1
                        sub_count = sub_count + 1
                        output_sub_stream_index = output_sub_stream_index + 1
                        end
                        end
                        end
                    else
                        msg.warn("External subtitle file not found: " .. ext_path)
                    end
                end
            end
        end

        if #subtitle_args > 0 then
            table.insert(subtitle_args, '-c:s')
            if self.config.video_container == 'mp4' then
                table.insert(subtitle_args, 'mov_text')
            else
                table.insert(subtitle_args, 'copy')
            end
        else
            subtitle_args = { '-sn' }
        end
    elseif self.config.include_subtitles then
        local sid = current_sub_id_snapshot()
        if sid and sid ~= "no" then
            local sub_index = nil
            local first_sub_index = nil
            local is_external = false
            local ext_path = nil
            local ext_track_lang = nil
            for _, track in ipairs(track_list_snapshot()) do
                if track.type == "sub" then
                    if not first_sub_index and not track.external then
                        first_sub_index = track.ff_index
                    end
                    if track.id == tonumber(sid) then
                        sub_index = track.ff_index
                        is_external = track.external
                        ext_path = is_external and track.external_filename or nil
                        ext_track_lang = is_external and track.lang or nil
                        break
                    end
                end
            end
            if sub_index then
                if is_external and self.config.include_external_subtitles then
                    if ext_path then
                        if not source_path then
                            msg.error("Source path is nil, cannot process external subtitles")
                            subtitle_args = { '-sn' }
                        elseif not ext_path:match('^[/\\]') and not ext_path:match('^[a-zA-Z]:') then
                            local working_dir = working_directory_snapshot()
                            if working_dir then
                                ext_path = utils.join_path(working_dir, ext_path)
                                if utils.file_info(ext_path) then
                                    local prepared_ext_path, cue_count = prepare_external_subtitle_path(ext_path, start_timestamp, end_timestamp)
                                    if cue_count == 0 then
                                        msg.info("No external subtitle cues overlap the encode range, skipping: " .. ext_path)
                                        subtitle_args = { '-sn' }
                                    else
                                    table.insert(extra_inputs, '-ss')
                                    table.insert(extra_inputs, toms(start_timestamp))
                                    table.insert(extra_inputs, '-to')
                                    table.insert(extra_inputs, toms(end_timestamp))
                                    table.insert(extra_inputs, '-i')
                                    table.insert(extra_inputs, prepared_ext_path)
                                    subtitle_args = { '-map', '1:s:0' }
                                    local ext_title = external_subtitle_track_title(ext_path)
                                    local ext_language = external_subtitle_language(ext_track_lang, ext_path)
                                    append_external_subtitle_metadata(subtitle_args, 0, ext_language, ext_title)
                                    table.insert(subtitle_args, '-c:s')
                                    table.insert(subtitle_args, 'copy')
                                    end
                                else
                                    msg.warn("External subtitle file not found: " .. ext_path)
                                    subtitle_args = { '-sn' }
                                end
                            else
                                msg.error("Cannot resolve relative external subtitle path without working directory")
                                subtitle_args = { '-sn' }
                            end
                        else
                            if utils.file_info(ext_path) then
                                local prepared_ext_path, cue_count = prepare_external_subtitle_path(ext_path, start_timestamp, end_timestamp)
                                if cue_count == 0 then
                                    msg.info("No external subtitle cues overlap the encode range, skipping: " .. ext_path)
                                    subtitle_args = { '-sn' }
                                else
                                table.insert(extra_inputs, '-ss')
                                table.insert(extra_inputs, toms(start_timestamp))
                                table.insert(extra_inputs, '-to')
                                table.insert(extra_inputs, toms(end_timestamp))
                                table.insert(extra_inputs, '-i')
                                table.insert(extra_inputs, prepared_ext_path)
                                subtitle_args = { '-map', '1:s:0' }
                                local ext_title = external_subtitle_track_title(ext_path)
                                local ext_language = external_subtitle_language(ext_track_lang, ext_path)
                                append_external_subtitle_metadata(subtitle_args, 0, ext_language, ext_title)
                                table.insert(subtitle_args, '-c:s')
                                table.insert(subtitle_args, 'copy')
                                end
                            else
                                msg.warn("External subtitle file not found: " .. ext_path)
                                subtitle_args = { '-sn' }
                            end
                        end
                    else
                        subtitle_args = { '-sn' }
                    end
                else
                    local adjusted_index = sub_index - first_sub_index
                    if adjusted_index >= 0 then
                        subtitle_args = { '-map', '0:s:' .. adjusted_index, '-c:s', 'copy' }
                    else
                        subtitle_args = { '-sn' }
                    end
                end
            else
                subtitle_args = { '-sn' }
            end
        else
            subtitle_args = { '-sn' }
        end
    else
        subtitle_args = { '-sn' }
    end

    local args = ffmpeg.prepend(
        '-ss', toms(start_timestamp),
        '-to', toms(end_timestamp)
    )

    for _, arg in ipairs(input_args) do table.insert(args, arg) end
    for _, arg in ipairs(extra_inputs) do table.insert(args, arg) end
    for _, arg in ipairs(map_args) do table.insert(args, arg) end
    if not self.config.include_metadata then
        table.insert(args, '-map_metadata')
        table.insert(args, '-1')
        table.insert(args, '-map_chapters')
        table.insert(args, '-1')
    end
    if include_video_stream and self.config.video_filter ~= 'disabled' then
        local vf_filters = {}
        if self.config.video_fps and self.config.video_fps > 0 then
            table.insert(vf_filters, string.format('fps=%d', self.config.video_fps))
        end
        table.insert(vf_filters, video_scale_filter())
        table.insert(args, '-vf')
        table.insert(args, table.concat(vf_filters, ','))
    elseif include_video_stream then
        msg.info("video_filter disabled: skipping -vf (fps/scale) filters")
    end
    for _, arg in ipairs(video_encoder_args) do table.insert(args, arg) end
    for _, arg in ipairs(audio_encoder_args) do table.insert(args, arg) end
    for _, arg in ipairs(subtitle_args) do table.insert(args, arg) end
    table.insert(args, output_path)

    -- Deduplicate/merge repeated codec param flags across families
    merge_codec_params(args, '-x265-params')
    merge_codec_params(args, '-x264-params')
    merge_codec_params(args, '-svtav1-params')
    merge_codec_params(args, '-rav1e-params')

    -- Store the last encode command (raw ffmpeg invocation)
    self.last_encode_command = table.concat(args, ' ')
    -- Reset last encode metadata; populated post-encode in video.on_finish
    self.last_encode_filesize = nil
    self.last_encode_duration = nil

    return args
end

------------------------------------------------------------
-- Legacy encoder backend (unused)

local mpv = {}

mpv.exec = find_exec("mpv")

mpv.prepend_common_args = function(source_path, ...)
    local args = {
        mpv.exec,
        source_path,
        '--no-config',
        '--loop-file=no',
        '--keep-open=no',
    }
    if not self.config.include_metadata then
        table.insert(args, '--no-ocopy-metadata')
    end
    for _, arg in ipairs({...}) do
        table.insert(args, arg)
    end
    return args
end

mpv.make_video_args = function(source_path, output_path, start_timestamp, end_timestamp)
    local video_encoder_args, audio_encoder_args, subtitle_args = {}, {}, {}

    -- Ensure config values have defaults
    local vbitrate = self.config.video_bitrate or "200k"
    local abitrate = self.config.audio_bitrate or "64k"
    local fade_in = tonumber(self.config.audio_fade_in) or 0
    local fade_out = tonumber(self.config.audio_fade_out) or 0
    local clip_duration = end_timestamp - start_timestamp
    if self.config.video_use_crf then
        msg.info("Using video CRF: " .. tostring(self.config.video_crf))
    else
        msg.info("Using video bitrate: " .. vbitrate)
    end
    if self.config.audio_use_vbr then
        msg.info("Using audio VBR")
    else
        msg.info("Using audio bitrate: " .. abitrate)
    end
    msg.info("Audio fade-in: " .. fade_in .. "s")
    msg.info("Audio fade-out: " .. fade_out .. "s")
    msg.info("Clip duration: " .. clip_duration .. "s")
    msg.info("Start timestamp: " .. tostring(start_timestamp))
    msg.info("End timestamp: " .. tostring(end_timestamp))
    msg.info("Source path: " .. tostring(source_path))

    -- Cap fade durations to avoid exceeding clip duration
    if fade_in > clip_duration / 2 then
        fade_in = clip_duration / 2
        msg.warn("Fade-in duration capped to " .. fade_in .. "s to fit clip duration")
    end
    if fade_out > clip_duration / 2 then
        fade_out = clip_duration / 2
        msg.warn("Fade-out duration capped to " .. fade_out .. "s to fit clip duration")
    end

    -- Resolve source_path to absolute if relative
    if source_path and not source_path:match('^[/\\]') and not source_path:match('^[a-zA-Z]:') then
        local working_dir = mp.get_property("working-directory")
        if working_dir then
            source_path = utils.join_path(working_dir, source_path)
        else
            msg.error("Cannot resolve relative source path without working directory")
        end
    end
    msg.info("Resolved source path: " .. tostring(source_path))

    -- Video codec settings
    if self.config.video_codec == 'libx264' then
        video_encoder_args = { '--ovc=libx264', '--ovcopts-add=preset=medium', '--ovcopts-add=b=' .. vbitrate }
    elseif self.config.video_codec == 'libx265' then
        video_encoder_args = { '--ovc=libx265', '--ovcopts-add=preset=medium', '--ovcopts-add=b=' .. vbitrate }
    elseif self.config.video_codec == 'libvpx' then
        video_encoder_args = { '--ovc=libvpx', '--ovcopts-add=b=' .. vbitrate }
    elseif self.config.video_codec == 'libvpx-vp9' then
        video_encoder_args = { '--ovc=libvpx-vp9', '--ovcopts-add=b=' .. vbitrate }
    elseif self.config.video_codec == 'libsvtav1' then
        video_encoder_args = { '--ovc=libsvtav1', '--ovcopts-add=preset=' .. self.config.video_preset, '--ovcopts-add=b=' .. vbitrate }
    elseif self.config.video_codec == 'librav1e' then
        video_encoder_args = { '--ovc=librav1e', '--ovcopts-add=speed=' .. self.config.video_preset, '--ovcopts-add=b=' .. vbitrate }
    elseif self.config.video_codec == 'libaom-av1' then
        video_encoder_args = { '--ovc=libaom-av1', '--ovcopts-add=cpu-used=' .. self.config.video_preset, '--ovcopts-add=b=' .. vbitrate }
    elseif self.config.video_codec == 'av1_nvenc' then
        video_encoder_args = { '--ovc=av1_nvenc', '--ovcopts-add=preset=' .. self.config.video_preset, '--ovcopts-add=b=' .. vbitrate }
    elseif self.config.video_codec == 'av1_amf' then
        video_encoder_args = { '--ovc=av1_amf', '--ovcopts-add=quality=' .. self.config.video_preset, '--ovcopts-add=b=' .. vbitrate }
    elseif self.config.video_codec == 'av1_qsv' then
        video_encoder_args = { '--ovc=av1_qsv', '--ovcopts-add=preset=' .. self.config.video_preset, '--ovcopts-add=b=' .. vbitrate }
    end

    -- Audio codec settings with optional single-pass loudnorm and fades
    audio_encoder_args = { '--oac=' .. (self.config.audio_codec == 'libopus' and 'libopus' or 'aac'), '--oacopts-add=b=' .. abitrate }
    local audio_filters = {}
    if fade_in > 0 then
        table.insert(audio_filters, string.format("afade=t=in:st=0:d=%.3f", fade_in))
    end
    if fade_out > 0 then
        table.insert(audio_filters, string.format("afade=t=out:st=%.3f:d=%.3f", end_timestamp - start_timestamp - fade_out, fade_out))
    end
    if self.config.loudnorm_enabled == "yes" then
        -- Two-pass loudnorm is only implemented for the FFmpeg backend.
        local loudnorm_filter = "loudnorm"
        loudnorm_filter = loudnorm_filter .. "=I=" .. (self.config.loudnorm_I or "-23")
        loudnorm_filter = loudnorm_filter .. ":LRA=" .. (self.config.loudnorm_LRA or "7")
        loudnorm_filter = loudnorm_filter .. ":TP=" .. (self.config.loudnorm_TP or "-2")
        if self.config.loudnorm_linear == "yes" then
            loudnorm_filter = loudnorm_filter .. ":linear=true"
        else
            loudnorm_filter = loudnorm_filter .. ":linear=false"
        end
        table.insert(audio_filters, loudnorm_filter)
        msg.info("Applying single-pass loudnorm filter: " .. loudnorm_filter)
    end
    if #audio_filters > 0 then
        table.insert(audio_encoder_args, '--af-add=lavfi=[' .. table.concat(audio_filters, ',') .. ']')
    end

    -- Enhanced subtitle handling with error checking and format validation
    if self.config.include_subtitles then
        local sid = mp.get_property("current-tracks/sub/id")
        subtitle_args = {}
        if sid and sid ~= "no" then
            local is_external = false
            local ext_path = nil
            local sub_codec = nil
            for i = 0, mp.get_property_number("track-list/count") - 1 do
                if mp.get_property("track-list/" .. i .. "/type") == "sub" and 
                   mp.get_property_number("track-list/" .. i .. "/id") == tonumber(sid) then
                    is_external = mp.get_property_bool("track-list/" .. i .. "/external")
                    ext_path = is_external and mp.get_property("track-list/" .. i .. "/external-filename") or nil
                    sub_codec = mp.get_property("track-list/" .. i .. "/codec")
                    break
                end
            end

            local supported_sub_codecs = { "ass", "srt", "subrip", "text" }
            local is_compatible = false
            if sub_codec then
                for _, codec in ipairs(supported_sub_codecs) do
                    if sub_codec:lower():find(codec) then
                        is_compatible = true
                        break
                    end
                end
            end

            if not is_compatible then
                msg.warn("Subtitle format (" .. (sub_codec or "unknown") .. ") may not be compatible with mpv hardcoding. Falling back to no subtitles.")
                table.insert(subtitle_args, '--no-sub')
            elseif is_external and self.config.include_external_subtitles then
                if ext_path then
                    if not source_path then
                        msg.error("Source path is nil, cannot process external subtitles")
                        table.insert(subtitle_args, '--no-sub')
                    elseif not ext_path:match('^[/\\]') and not ext_path:match('^[a-zA-Z]:') then
                        local working_dir = mp.get_property("working-directory")
                        if working_dir then
                            ext_path = utils.join_path(working_dir, ext_path)
                            msg.info("External subtitle path: " .. tostring(ext_path))
                            if utils.file_info(ext_path) then
                                table.insert(subtitle_args, '--sub-file=' .. ext_path)
                                table.insert(subtitle_args, '--sid=1')
                                table.insert(subtitle_args, '--embeddedfonts')
                            else
                                msg.warn("External subtitle file not found: " .. ext_path)
                                table.insert(subtitle_args, '--no-sub')
                                mp.osd_message("External subtitle file not found: " .. ext_path, 5)
                            end
                        else
                            msg.error("Cannot resolve relative external subtitle path without working directory")
                            table.insert(subtitle_args, '--no-sub')
                        end
                    else
                        msg.info("External subtitle path: " .. tostring(ext_path))
                        if utils.file_info(ext_path) then
                            table.insert(subtitle_args, '--sub-file=' .. ext_path)
                            table.insert(subtitle_args, '--sid=1')
                            table.insert(subtitle_args, '--embeddedfonts')
                        else
                            msg.warn("External subtitle file not found: " .. ext_path)
                            table.insert(subtitle_args, '--no-sub')
                            mp.osd_message("External subtitle file not found: " .. ext_path, 5)
                        end
                    end
                else
                    msg.warn("No external subtitle path available.")
                    table.insert(subtitle_args, '--no-sub')
                end
            else
                table.insert(subtitle_args, '--sid=' .. sid)
                table.insert(subtitle_args, '--embeddedfonts')
            end
        else
            table.insert(subtitle_args, '--no-sub')
            msg.warn("No subtitle track selected. Video will be created without subtitles.")
        end
    else
        subtitle_args = { '--no-sub' }
    end

    local args = mpv.prepend_common_args(source_path, '--start=' .. toms(start_timestamp), '--end=' .. toms(end_timestamp))
    if self.config.video_filter ~= 'disabled' then
        if self.config.video_fps and self.config.video_fps > 0 then
            table.insert(args, string.format('--vf-add=fps=%d', self.config.video_fps))
        end
        table.insert(args, string.format('--vf-add=lavfi=[%s]', video_scale_filter()))
    else
        msg.info("video_filter disabled: skipping --vf-add filters")
    end
    table.insert(args, '-o=' .. output_path)
    for _, arg in ipairs(video_encoder_args) do table.insert(args, arg) end
    for _, arg in ipairs(audio_encoder_args) do table.insert(args, arg) end
    for _, arg in ipairs(subtitle_args) do table.insert(args, arg) end

    -- Store the last encode command (raw mpv invocation)
    self.last_encode_command = table.concat(args, ' ')
    self.last_encode_filesize = nil
    self.last_encode_duration = nil

    return args
end

------------------------------------------------------------
-- main interface

local create_video = function(start_timestamp, end_timestamp, job, padding, on_finish_fn, track_async_fn, on_progress_fn)
    if h.is_empty(self.output_dir_path) then
        return msg.error("Output directory wasn't provided. Video file will not be created.")
    end

    if not h.is_empty(self.config.video_field) then
        local requested_video_stream = encode_video_enabled()
        local requested_audio_stream = encode_audio_enabled()
        local include_video_stream = output_has_video_stream()
        local include_audio_stream = output_has_audio_stream()

        if requested_video_stream and not include_video_stream then
            msg.warn("Video stream requested, but the source has no video track. Encoding without video.")
        end
        if requested_audio_stream and not include_audio_stream then
            msg.warn("Audio stream requested, but the source has no audio track. Encoding without audio.")
        end
        if not include_video_stream and not include_audio_stream then
            msg.error("Encoding requires at least one available video or audio stream. Subtitle-only output is not supported.")
            mp.osd_message("Encoding failed: no enabled video/audio stream available", 5)
            if type(on_finish_fn) == 'function' then on_finish_fn(false) end
            return
        end

        local source_path = source_path_snapshot()
        local local_output_path = utils.join_path(self.output_dir_path, job.filename)
        local output_path = local_output_path

        -- Pre-encoding integrity check
        local expected_duration = end_timestamp - start_timestamp
        local input_valid, input_error = check_input_file_integrity(source_path, start_timestamp, end_timestamp)
        if not input_valid then
            msg.error("Input file integrity check failed: " .. (input_error or "Unknown error"))
            mp.osd_message("Video creation failed: Input file corruption detected", 5)
            if type(on_finish_fn) == 'function' then on_finish_fn(false) end
            return
        end

        local function try_encode(_, attempt_final_fallback)
            self.encoder = ffmpeg
            self.last_encode_details = nil
            local is_valid = codec_support.is_valid_combination(self.config.video_codec, self.config.audio_codec, self.config.video_container, include_video_stream, include_audio_stream)

            local remote_enabled = is_remote_ffmpeg_enabled()
            if remote_enabled and not is_remote_staging_local_available() then
                msg.warn('Remote FFmpeg enabled but remote_encode_staging_dir_local is not available. Falling back to local FFmpeg.')
                remote_enabled = false
            end
            local local_staged_path = nil
            local function remote_safe_filename(local_filename)
                if not remote_enabled then
                    return local_filename
                end
                local rf = strip_non_ascii(local_filename)
                -- If stripping removes the base name but leaves the timestamp suffix, avoid leading '_'
                if type(rf) == 'string' and rf:sub(1, 1) == '_' then
                    rf = 'clip' .. rf
                end
                return rf
            end

            local function refresh_output_paths(local_filename)
                local_output_path = utils.join_path(self.output_dir_path, local_filename)
                if remote_enabled then
                    local local_stage = remote_staging_dir_local()
                    local remote_stage = remote_staging_dir_remote()
                    -- If remote staging dir is unset, assume both machines see the same path (e.g. UNC share).
                    if h.is_empty(remote_stage) then
                        remote_stage = local_stage
                    end
                    local rf = remote_safe_filename(local_filename)
                    local_staged_path = utils.join_path(local_stage, rf)
                    output_path = utils.join_path(remote_stage, rf)
                else
                    output_path = local_output_path
                    local_staged_path = nil
                end
            end

            refresh_output_paths(job.filename)

            if not is_valid or attempt_final_fallback then
                local final_fallback_msg = "Using final fallback: libvpx-vp9 + libopus + webm (no subtitles)"
                self.config.video_codec = 'libvpx-vp9'
                self.config.audio_codec = 'libopus'
                self.config.video_container = 'webm'
                self.encoder = ffmpeg
                refresh_output_paths(job.filename:gsub("%.%w+$", ".webm"))
                self.config.include_subtitles = false
                msg.info(final_fallback_msg)
                mp.osd_message(final_fallback_msg, 5)
            end

            -- Enforce mutual exclusivity between CRF and two-pass
            local two_pass_requested = (self.config.video_two_pass == true or self.config.video_two_pass == "yes")
            local crf_requested = (self.config.video_use_crf == true or self.config.video_use_crf == "yes")
            if two_pass_requested and crf_requested then
                -- Prefer two-pass; disable CRF for this encoding session
                msg.warn("Both video_two_pass and video_use_crf are enabled. Ignoring CRF in favor of two-pass.")
                crf_requested = false
            end
            if two_pass_requested and not include_video_stream then
                msg.warn("video_two_pass is enabled, but no video stream will be encoded. Ignoring two-pass.")
            end

            -- For downstream logic
            local vqm_mode = self.config.video_quality_management or ((self.config.allow_combined_crf_bitrate == true or self.config.allow_combined_crf_bitrate == "yes") and 'allow_combined_crf_bitrate' or 'enabled')
            -- Two-pass can run regardless of quality management mode; when disabled, the user must specify bitrate via custom args/codec params.
            local two_pass_active = include_video_stream and two_pass_requested and not crf_requested

            local loudnorm_stats = nil
            local loudnorm_mode = 'disabled'
            local loudnorm_warnings = {}
            local loudnorm_measure_command = nil
            local loudnorm_measure_args = nil
            if self.config.loudnorm_enabled == "yes" and self.config.loudnorm_two_pass == "yes" then
                if type(on_progress_fn) == 'function' then
                    on_progress_fn({ stage = 'measuring' })
                end
                local measure_args = ffmpeg.make_loudnorm_measure_args(source_path, start_timestamp, end_timestamp)
                loudnorm_measure_args = measure_args
                if advanced_encode_logging_enabled() then
                    loudnorm_measure_command = table.concat(measure_args, ' ')
                end
                logger.info_cat('loudnorm_detail', "Executing loudnorm measurement pass: " .. table.concat(measure_args, " "))
                local result = run_ffmpeg_subprocess(measure_args, nil, { capture_stdout = true, capture_stderr = true, summarize_on_error = true, stderr_tail_lines = 60, on_error = function(_, res, tail) self.last_error_tail = tail end, log_category = 'loudnorm_detail', log_command = false })
                if result then
                    if result.stdout then logger.info_cat('loudnorm_detail', "Measurement stdout:\n" .. result.stdout) end
                    if result.stderr then logger.info_cat('loudnorm_detail', "Measurement stderr: " .. result.stderr) end
                    if result.status ~= 0 then
                        table.insert(loudnorm_warnings, "Measurement pass failed with status: " .. tostring(result.status))
                        msg.warn("Measurement pass failed with status: " .. tostring(result.status))
                    end
                    loudnorm_stats = parse_loudnorm_stats(result.stderr or result.stdout or "")
                    if loudnorm_stats then
                        loudnorm_mode = 'two_pass'
                        msg.info("Loudnorm stats - I: " .. loudnorm_stats.input_i .. ", LRA: " .. loudnorm_stats.input_lra .. ", TP: " .. loudnorm_stats.input_tp)
                    else
                        loudnorm_mode = 'single_pass'
                        table.insert(loudnorm_warnings, 'Failed to retrieve loudnorm stats, falling back to single-pass')
                        msg.warn("Failed to retrieve loudnorm stats, falling back to single-pass")
                    end
                else
                    loudnorm_mode = 'single_pass'
                    table.insert(loudnorm_warnings, 'Loudnorm measurement pass failed (no result), falling back to single-pass')
                    msg.warn("Loudnorm measurement pass failed (no result), falling back to single-pass")
                end
            elseif self.config.loudnorm_enabled == "yes" then
                loudnorm_mode = 'single_pass'
            end

            local function arg_list_has(args, key)
                for i = 1, #args do if args[i] == key then return true end end
                return false
            end

            local function codec_params_contain(args, param_key, pattern)
                for i = 1, #args - 1 do
                    if args[i] == param_key then
                        local v = args[i + 1]
                        if type(v) == 'string' and v:find(pattern) then return true end
                    end
                end
                return false
            end

            local function run_second_pass()
                local args2 = ffmpeg.make_video_args(source_path, output_path, start_timestamp, end_timestamp, loudnorm_stats)
                if two_pass_active then
                    -- insert second-pass flags before output path
                    local out = table.remove(args2) -- last element is output
                    -- Ensure a bitrate is set for true two-pass only when quality management is not disabled.
                    -- When disabled, rely entirely on custom args / codec params (e.g., -x265-params bitrate=...).
                    local vbitrate = self.config.video_bitrate or "200k"
                    local vqm = self.config.video_quality_management or ((self.config.allow_combined_crf_bitrate == true or self.config.allow_combined_crf_bitrate == "yes") and 'allow_combined_crf_bitrate' or 'enabled')
                    local has_bv = arg_list_has(args2, '-b:v')
                    local has_crf = arg_list_has(args2, '-crf') or codec_params_contain(args2, '-x265-params', 'crf=')
                    local has_codec_bitrate = codec_params_contain(args2, '-x265-params', 'bitrate=') or codec_params_contain(args2, '-svtav1-params', 'mbr=') or codec_params_contain(args2, '-rav1e-params', 'bitrate=')
                    if vqm ~= 'disabled' and not has_bv and not has_crf and not has_codec_bitrate then
                        table.insert(args2, '-b:v')
                        table.insert(args2, vbitrate)
                    end
                    if self.config.video_codec == 'libx265' then
                        -- Use x265-native two-pass flags, merged with any existing -x265-params
                        local stats_value = x265_stats_value_from_prefix(self.__passlogfile_prefix)
                        local stats_fs = param_value_to_fs_path(stats_value)
                        msg.info("Two-pass (x265) pass 2 using stats file: " .. tostring(stats_fs))
                        merge_codec_params(args2, '-x265-params', 'pass=2:stats=' .. stats_value)
                    else
                        table.insert(args2, '-pass')
                        table.insert(args2, '2')
                        table.insert(args2, '-passlogfile')
                        table.insert(args2, self.__passlogfile_prefix)
                    end
                    table.insert(args2, out)
                end
                self.last_encode_command = table.concat(args2, ' ')
                self.last_encode_details = {
                    commands = {
                        encode_command = clone_table(args2),
                    },
                    loudnorm = capture_loudnorm_details(
                        loudnorm_mode,
                        loudnorm_stats,
                        #loudnorm_warnings > 0 and clone_table(loudnorm_warnings) or nil
                    ),
                }
                if advanced_encode_logging_enabled() then
                    self.last_encode_details.commands.loudnorm_measure_command = loudnorm_measure_command and clone_table(loudnorm_measure_args) or nil
                end
                local stop_progress = function() end
                if type(on_progress_fn) == 'function' then
                    on_progress_fn({ stage = 'pass2' })
                    stop_progress = attach_ffmpeg_progress(args2, expected_duration, function(p)
                        on_progress_fn({
                            stage = 'pass2',
                            percent = p.percent,
                            speed = p.speed,
                        })
                    end)
                    job.stop_progress = stop_progress
                end
                self.last_encode_command = table.concat(args2, ' ')
                logger.info_cat('ffmpeg_encode_output', "Executing: " .. table.concat(args2, " "))
                run_ffmpeg_subprocess(args2, function(success, result)
                    stop_progress()
                    cleanup_external_subtitle_files(args2)
                    -- Print full FFmpeg outputs when enabled
                    if result then
                        if result.stdout and result.stdout ~= '' then logger.info_cat('ffmpeg_encode_output', result.stdout) end
                        if result.stderr and result.stderr ~= '' then logger.info_cat('ffmpeg_encode_output', result.stderr) end
                    end
                    if two_pass_active then
                        -- On completion, remove pass stats/log files
                        local prefix = self.__passlogfile_prefix
                        if success and (result == nil or result.status == 0) then
                            if remote_enabled then
                                msg.info("Two-pass: remote mode; leaving stats/log cleanup to remote or share")
                            else
                                msg.info("Two-pass: cleaning up stats/log files")
                                local candidates = {
                                    prefix,
                                    prefix .. "-0.log",
                                    prefix .. "-0.log.cutree",
                                    prefix .. "-0.log.mbtree",
                                    prefix .. ".log",
                                    prefix .. ".log.mbtree",
                                    -- x265 native stats path (.log)
                                    x265_stats_value_from_prefix(prefix):gsub('\\:', ':')
                                }
                                for _, f in ipairs(candidates) do
                                    local info = utils.file_info(f)
                                    if info and info.is_file then
                                        os.remove(f)
                                        msg.info("  deleted: " .. f)
                                    end
                                end
                            end
                        else
                            msg.warn("Two-pass: keeping stats/log files due to failure")
                        end
                        self.__passlogfile_prefix = nil
                    end

                    local function staged_output_path()
                        if remote_enabled and local_staged_path and local_staged_path ~= '' then
                            return local_staged_path
                        end
                        return output_path
                    end

                    local function finalize_success()
                        self.last_error_tail = nil

                        -- If remote-encoded, copy staged output into the local output dir
                        if remote_enabled and local_staged_path and local_staged_path ~= '' then
                            local ok = h.copy_file(local_staged_path, local_output_path)
                            if not ok then
                                msg.error("Failed to copy staged clip to local output: " .. tostring(local_output_path))
                                mp.osd_message("Video creation failed: couldn't copy clip locally", 5)
                                if type(on_finish_fn) == 'function' then on_finish_fn(false) end
                                return
                            end
                            if self.config.remote_encode_cleanup then
                                os.remove(local_staged_path)
                            end
                            output_path = local_output_path
                        end

                        -- Post-encoding integrity check
                        local output_valid, output_error = check_output_file_integrity(output_path, expected_duration)
                        if not output_valid then
                            msg.error("Output file integrity check failed: " .. (output_error or "Unknown error"))
                            mp.osd_message("Video creation failed: Output file corruption detected", 5)
                            -- Clean up corrupted file
                            os.remove(output_path)
                            if type(on_finish_fn) == 'function' then on_finish_fn(false) end
                            return
                        end

                        job.filename = output_path:match("[^/\\]+$")
                        msg.info(string.format("Created video: %s", output_path))
                        handle_preview_video_completion(output_path)
                        if type(on_finish_fn) == 'function' then on_finish_fn(true) end
                    end

                    local function finalize_failure()
                        msg.error(string.format("Couldn't create video: %s", output_path))
                        if result then
                            if result.stdout and result.stdout ~= "" then msg.error("Subprocess stdout: " .. result.stdout) end
                            if result.stderr and result.stderr ~= "" then msg.error("Subprocess stderr: " .. result.stderr) end
                            if result.status then msg.error("Subprocess exit status: " .. tostring(result.status)) end
                            self.last_error_tail = (result.stderr and result.stderr:sub(-4000)) or result.stdout
                        else
                            msg.error("No result returned from subprocess.")
                        end
                        if not attempt_final_fallback then
                            local retry_msg = "Encoding failed. Retrying with final fallback: libvpx-vp9 + libopus + webm"
                            msg.warn(retry_msg)
                            mp.osd_message(retry_msg, 5)
                            try_encode(true, true)
                        elseif type(on_finish_fn) == 'function' then
                            on_finish_fn(false)
                        end
                    end

                    local function wait_for_staged_output(retries_left)
                        local p = staged_output_path()
                        if h.file_exists(p) then
                            finalize_success()
                            return
                        end
                        if retries_left <= 0 then
                            finalize_failure()
                            return
                        end
                        -- Network shares (SMB/UNC) can lag a bit before the file becomes visible/non-zero.
                        mp.add_timeout(0.25, function() wait_for_staged_output(retries_left - 1) end)
                    end

                    if success and (result == nil or result.status == 0) then
                        wait_for_staged_output(8)
                    else
                        finalize_failure()
                    end
                end, { capture_stderr = true, capture_stdout = true, summarize_on_error = true, stderr_tail_lines = 60, on_error = function(_, res, tail) self.last_error_tail = tail end, log_category = 'ffmpeg_encode_output', log_command = false }, track_async_fn)
            end

            if two_pass_active then
                -- Build first pass (video-only to null sink) with persistent passlogfile in TEMP directory
                local pass_prefix = persistent_pass_prefix()
                self.__passlogfile_prefix = pass_prefix

                -- Recompute video encoder args similarly to main path for pass1
                local vbitrate = self.config.video_bitrate or "200k"
                local vqm = self.config.video_quality_management or ((self.config.allow_combined_crf_bitrate == true or self.config.allow_combined_crf_bitrate == "yes") and 'allow_combined_crf_bitrate' or 'enabled')
                local disable_video_q = (vqm == 'disabled')
                -- For two-pass, force a bitrate only when quality management is enabled; when disabled, rely on user-specified custom args/codec params
                if two_pass_active and vqm ~= 'disabled' then disable_video_q = false end
                local video_encoder_args = { '-c:v', self.config.video_codec }
                if self.config.video_codec == 'libx264' or self.config.video_codec == 'libx265' then
                    if not disable_video_q then table.insert(video_encoder_args, '-b:v'); table.insert(video_encoder_args, vbitrate) end
                    if self.config.video_preset then table.insert(video_encoder_args, '-preset'); table.insert(video_encoder_args, self.config.video_preset) end
                elseif self.config.video_codec == 'libvpx' or self.config.video_codec == 'libvpx-vp9' then
                    if not disable_video_q then table.insert(video_encoder_args, '-b:v'); table.insert(video_encoder_args, vbitrate) end
                elseif self.config.video_codec == 'libsvtav1' then
                    if not disable_video_q then table.insert(video_encoder_args, '-b:v'); table.insert(video_encoder_args, vbitrate) end
                    if self.config.video_preset then table.insert(video_encoder_args, '-preset'); table.insert(video_encoder_args, self.config.video_preset) end
                elseif self.config.video_codec == 'librav1e' then
                    if not disable_video_q then table.insert(video_encoder_args, '-b:v'); table.insert(video_encoder_args, vbitrate) end
                    if self.config.video_preset then table.insert(video_encoder_args, '-speed'); table.insert(video_encoder_args, self.config.video_preset) end
                elseif self.config.video_codec == 'libaom-av1' then
                    if not disable_video_q then table.insert(video_encoder_args, '-b:v'); table.insert(video_encoder_args, vbitrate) end
                    if self.config.video_preset then table.insert(video_encoder_args, '-cpu-used'); table.insert(video_encoder_args, self.config.video_preset) end
                else
                    if not disable_video_q then table.insert(video_encoder_args, '-b:v'); table.insert(video_encoder_args, vbitrate) end
                end
                if self.config.video_custom_args and self.config.video_custom_args ~= '' then
                    local custom_args = h.parse_shell_like_args(self.config.video_custom_args)
                    local drop_next_value = false
                    for _, arg in ipairs(custom_args) do
                        if drop_next_value then
                            drop_next_value = false
                        else
                            local key, val = arg:match('^%-(svtav1%-params|x265%-params|rav1e%-params)=(.+)$')
                            if key and val then
                                local opt = '-' .. key
                                if allow_custom_arg_for_codec(opt, self.config.video_codec) then
                                    table.insert(video_encoder_args, opt)
                                    table.insert(video_encoder_args, val)
                                end
                            else
                                local allowed = allow_custom_arg_for_codec(arg, self.config.video_codec)
                                if allowed then
                                    table.insert(video_encoder_args, arg)
                                else
                                    if not arg:find('=') then drop_next_value = true end
                                end
                            end
                        end
                    end
                end

                local vf_filters = nil
                if self.config.video_filter ~= 'disabled' then
                    vf_filters = {}
                    if self.config.video_fps and self.config.video_fps > 0 then
                        table.insert(vf_filters, string.format('fps=%d', self.config.video_fps))
                    end
                    table.insert(vf_filters, video_scale_filter())
                else
                    msg.info("video_filter disabled: two-pass pass1 without -vf")
                end

                -- Build args ensuring encoder flags and pass flags appear BEFORE the output sink
                local args1 = ffmpeg.prepend(
                    '-ss', toms(start_timestamp),
                    '-to', toms(end_timestamp),
                    '-i', source_path,
                    '-an',
                    '-map', '0:v:0'
                )
                if vf_filters then
                    table.insert(args1, '-vf')
                    table.insert(args1, table.concat(vf_filters, ','))
                end
                -- Encoder flags (codec/bitrate/preset/custom) must precede the output url
                for _, arg in ipairs(video_encoder_args) do table.insert(args1, arg) end
                -- Codec-specific pass flags
                if self.config.video_codec == 'libx265' then
                    -- Use x265-native two-pass flags (merged with any existing -x265-params)
                    local stats_value = x265_stats_value_from_prefix(pass_prefix)
                    local stats_fs = param_value_to_fs_path(stats_value)
                    msg.info("Two-pass (x265) pass 1 writing stats to: " .. tostring(stats_fs))
                    merge_codec_params(args1, '-x265-params', 'pass=1:stats=' .. stats_value)
                else
                    -- Generic two-pass flags
                    msg.info("Two-pass (generic) pass 1 using prefix: " .. tostring(pass_prefix))
                    table.insert(args1, '-pass')
                    table.insert(args1, '1')
                    table.insert(args1, '-passlogfile')
                    table.insert(args1, pass_prefix)
                end
                -- Finally choose the null muxer sink
                table.insert(args1, '-f')
                table.insert(args1, 'null')
                table.insert(args1, ffmpeg_null_sink())

                local stop_progress = function() end
                if type(on_progress_fn) == 'function' then
                    on_progress_fn({ stage = 'pass1' })
                    stop_progress = attach_ffmpeg_progress(args1, expected_duration, function(p)
                        on_progress_fn({
                            stage = 'pass1',
                            percent = p.percent,
                            speed = p.speed,
                        })
                    end)
                    job.stop_progress = stop_progress
                end
                logger.info_cat('ffmpeg_encode_output', "Executing (pass 1/2): " .. table.concat(args1, ' '))
                run_ffmpeg_subprocess(args1, function(success, result)
                    stop_progress()
                    -- Print full FFmpeg outputs for pass 1 when enabled
                    if result then
                        if result.stdout and result.stdout ~= '' then logger.info_cat('ffmpeg_encode_output', result.stdout) end
                        if result.stderr and result.stderr ~= '' then logger.info_cat('ffmpeg_encode_output', result.stderr) end
                    end
                    if not success or (result and result.status ~= 0) then
                        msg.error("First pass failed; aborting two-pass encoding.")
                        if result and result.stderr and result.stderr ~= '' then msg.error("stderr: " .. result.stderr) end
                        if type(on_finish_fn) == 'function' then on_finish_fn(false) end
                        return
                    end
                    -- Validate passlog file is present and non-empty (best-effort only)
                    -- Report detailed findings for debugging
                    local pass_ok = false
                    local candidates = {
                        self.__passlogfile_prefix,
                        self.__passlogfile_prefix .. "-0.log",
                        self.__passlogfile_prefix .. "-0.log.cutree",
                        self.__passlogfile_prefix .. "-0.log.mbtree",
                        self.__passlogfile_prefix .. ".log",
                        self.__passlogfile_prefix .. ".log.mbtree",
                        -- x265 native stats path (.log)
                        x265_stats_value_from_prefix(self.__passlogfile_prefix):gsub('\\:', ':'),
                    }
                    if remote_enabled then
                        msg.info("Two-pass: remote mode; skipping local passlog scan")
                    else
                        msg.info("Two-pass: scanning for pass-1 logs/stat files...")
                        local found_any = false
                        for _, f in ipairs(candidates) do
                            local info = utils.file_info(f)
                            if info and info.is_file and (info.size or 0) > 0 then
                                pass_ok = true
                                found_any = true
                                msg.info(string.format("  found: %s (%d bytes)", f, info.size or -1))
                            elseif info and info.is_file then
                                found_any = true
                                msg.warn(string.format("  found empty: %s (0 bytes)", f))
                            end
                        end
                        if not found_any then msg.warn("  no candidate files found") end
                        if not pass_ok then msg.warn("Two-pass: did not confirm a non-empty stats/log file; proceeding to pass 2 anyway.") end
                        if pass_ok then msg.info("Two-pass: pass-1 produced a usable stats/log file.") end
                    end
                    -- Run second pass regardless; failure will be caught and handled
                    run_second_pass()
                end, { capture_stderr = true, capture_stdout = true, summarize_on_error = true, stderr_tail_lines = 60, on_error = function(_, res, tail) self.last_error_tail = tail end, log_category = 'ffmpeg_encode_output', log_command = false }, track_async_fn)
                return -- Don't fall through; second pass will handle completion
            end

            -- Single-pass
            local args = self.encoder.make_video_args(source_path, output_path, start_timestamp, end_timestamp, loudnorm_stats)
            self.last_encode_command = table.concat(args, ' ')
            self.last_encode_details = {
                commands = {
                    encode_command = clone_table(args),
                },
                loudnorm = capture_loudnorm_details(
                    loudnorm_mode,
                    loudnorm_stats,
                    #loudnorm_warnings > 0 and clone_table(loudnorm_warnings) or nil
                ),
            }
            if advanced_encode_logging_enabled() then
                self.last_encode_details.commands.loudnorm_measure_command = loudnorm_measure_command and clone_table(loudnorm_measure_args) or nil
            end
            local stop_progress = function() end
            if type(on_progress_fn) == 'function' then
                on_progress_fn({ stage = 'encoding' })
                stop_progress = attach_ffmpeg_progress(args, expected_duration, function(p)
                    on_progress_fn({
                        stage = 'encoding',
                        percent = p.percent,
                        speed = p.speed,
                    })
                end)
                job.stop_progress = stop_progress
            end
            self.last_encode_command = table.concat(args, ' ')
            logger.info_cat('ffmpeg_encode_output', "Executing: " .. table.concat(args, " "))
            run_ffmpeg_subprocess(args, function(success, result)
                stop_progress()
                cleanup_external_subtitle_files(args)
                -- Print full FFmpeg outputs when enabled
                if result then
                    if result.stdout and result.stdout ~= '' then logger.info_cat('ffmpeg_encode_output', result.stdout) end
                    if result.stderr and result.stderr ~= '' then logger.info_cat('ffmpeg_encode_output', result.stderr) end
                end

                local function staged_output_path()
                    if remote_enabled and local_staged_path and local_staged_path ~= '' then
                        return local_staged_path
                    end
                    return output_path
                end

                local function finalize_success()
                    self.last_error_tail = nil

                    -- If remote-encoded, copy staged output into the local output dir
                    if remote_enabled and local_staged_path and local_staged_path ~= '' then
                        local ok = h.copy_file(local_staged_path, local_output_path)
                        if not ok then
                            msg.error("Failed to copy staged clip to local output: " .. tostring(local_output_path))
                            mp.osd_message("Video creation failed: couldn't copy clip locally", 5)
                            if type(on_finish_fn) == 'function' then on_finish_fn(false) end
                            return
                        end
                        if self.config.remote_encode_cleanup then
                            os.remove(local_staged_path)
                        end
                        output_path = local_output_path
                    end

                    -- Post-encoding integrity check
                    local output_valid, output_error = check_output_file_integrity(output_path, expected_duration)
                    if not output_valid then
                        msg.error("Output file integrity check failed: " .. (output_error or "Unknown error"))
                        mp.osd_message("Video creation failed: Output file corruption detected", 5)
                        -- Clean up corrupted file
                        os.remove(output_path)
                        if type(on_finish_fn) == 'function' then on_finish_fn(false) end
                        return
                    end

                    job.filename = output_path:match("[^/\\]+$")
                    msg.info(string.format("Created video: %s", output_path))
                    handle_preview_video_completion(output_path)
                    if type(on_finish_fn) == 'function' then on_finish_fn(true) end
                end

                local function finalize_failure()
                    msg.error(string.format("Couldn't create video: %s", output_path))
                    if result then
                        if result.stdout and result.stdout ~= "" then msg.error("Subprocess stdout: " .. result.stdout) end
                        if result.stderr and result.stderr ~= "" then msg.error("Subprocess stderr: " .. result.stderr) end
                        if result.status then msg.error("Subprocess exit status: " .. tostring(result.status)) end
                        self.last_error_tail = (result.stderr and result.stderr:sub(-4000)) or result.stdout
                    else
                        msg.error("No result returned from subprocess.")
                    end
                    if not attempt_final_fallback then
                        local retry_msg = "Encoding failed. Retrying with final fallback: libvpx-vp9 + libopus + webm"
                        msg.warn(retry_msg)
                        mp.osd_message(retry_msg, 5)
                        try_encode(true, true)
                    elseif type(on_finish_fn) == 'function' then
                        on_finish_fn(false)
                    end
                end

                local function wait_for_staged_output(retries_left)
                    local p = staged_output_path()
                    if h.file_exists(p) then
                        finalize_success()
                        return
                    end
                    if retries_left <= 0 then
                        finalize_failure()
                        return
                    end
                    mp.add_timeout(0.25, function() wait_for_staged_output(retries_left - 1) end)
                end

                if success and (result == nil or result.status == 0) then
                    wait_for_staged_output(8)
                else
                    finalize_failure()
                end
            end, { capture_stderr = true, capture_stdout = true, summarize_on_error = true, stderr_tail_lines = 60, on_error = function(_, res, tail) self.last_error_tail = tail end, log_category = 'ffmpeg_encode_output', log_command = false }, track_async_fn)
        end

        try_encode(false, false)
    else
        print("Video will not be created.")
    end
end

local make_video_filename = function(start_time, end_time)
    local source_filename = nil
    if self.media_snapshot and type(self.media_snapshot.source_path) == 'string' then
        local normalized_path = self.media_snapshot.source_path:gsub('\\', '/')
        source_filename = normalized_path:match('([^/]+)$')
    end

    local name
    if source_filename and source_filename ~= '' then
        name = filename_factory.make_filename_for_media_name(source_filename, start_time, end_time, "." .. self.config.video_container)
    else
        name = filename_factory.make_filename(start_time, end_time, "." .. self.config.video_container)
    end

    -- Safety net: if the base name ends up empty, avoid saving as "_...".
    if type(name) == 'string' and name:sub(1, 1) == '_' then
        local src = source_filename or (mp.get_property("filename") or '')
        local base = src
        if base ~= '' then
            base = h.remove_extension(base)
            base = h.remove_filename_text_in_parentheses(base)
            base = h.remove_text_in_brackets(base)
            base = h.remove_special_characters(base)
            base = h.remove_newlines(base)
            base = h.remove_leading_trailing_spaces(base)
            base = h.remove_leading_trailing_dashes(base)
        end
        if base == '' then
            base = 'mpv-anki-clips_' .. tostring(os.time())
        end
        msg.warn("Empty clip basename detected; prefixing with '" .. tostring(base) .. "'.")
        name = string.lower(base .. name)
    end

    return name
end

local init = function(config)
    self.config = config
    configured_ffmpeg_exec = ffmpeg_executable.resolve(config and config.ffmpeg_exec)
end

local set_media_snapshot = function(snapshot)
    self.media_snapshot = snapshot
end

local set_output_dir = function(dir_path)
    self.output_dir_path = dir_path
end

local create_job = function(job_type, sub, video_padding)
    local on_finish_fn
    local on_progress_fn
    local active_async_ids = {}
    local finished = false
    local job = {}
    local function finish_once(success)
        if finished then return end
        finished = true
        if type(job.stop_progress) == 'function' then
            job.stop_progress()
            job.stop_progress = nil
        end
        active_async_ids = {}
        if type(on_finish_fn) == 'function' then on_finish_fn(success) end
    end
    local function track_async(async_id)
        if not finished and type(async_id) == 'number' then
            active_async_ids[async_id] = true
        end
    end
    if job_type == 'video' and (output_has_video_stream() or output_has_audio_stream()) then
        job.filename = make_video_filename(sub['start'], sub['end'])
        job.run_async = function()
            if finished then return nil end
            return create_video(sub['start'], sub['end'], job, video_padding, finish_once, track_async, on_progress_fn)
        end
    else
        job.filename = nil
        job.run_async = function()
            if finished then return nil end
            print("Video will not be created.")
            finish_once()
        end
    end
    job.cancel = function()
        if finished then return false end
        for async_id, _ in pairs(active_async_ids) do
            pcall(mp.abort_async_command, async_id)
        end
        finish_once(false)
        return true
    end
    job.on_finish = function(fn)
        on_finish_fn = fn
        return job
    end
    job.on_progress = function(fn)
        on_progress_fn = fn
        return job
    end
    return job
end

return {
    init = init,
    set_media_snapshot = set_media_snapshot,
    set_output_dir = set_output_dir,
    get_last_encode_command = function()
        return self.last_encode_command
    end,
    get_last_encode_details = function()
        return clone_table(self.last_encode_details)
    end,
    get_last_encode_filesize = function()
        return self.last_encode_filesize
    end,
    get_last_encode_duration = function()
        return self.last_encode_duration
    end,
    get_last_error_tail = function()
        return self.last_error_tail
    end,
    format_encode_progress_label = format_encode_progress_label,
    video = {
        create_job = function(sub, padding)
            return create_job('video', sub, padding)
        end,
    },
    _test = {
        build_windows_toast_powershell_script = build_windows_toast_powershell_script,
        windows_powershell_exec = windows_powershell_exec,
        mpv_exec = mpv_exec,
        handle_preview_video_completion = handle_preview_video_completion,
        make_ffmpeg_video_args = ffmpeg.make_video_args,
        make_ffmpeg_loudnorm_measure_args = ffmpeg.make_loudnorm_measure_args,
        trim_external_subtitle_content = trim_external_subtitle_content,
        external_subtitle_language = external_subtitle_language,
        external_subtitle_track_title = external_subtitle_track_title,
        parse_ffmpeg_progress_text = parse_ffmpeg_progress_text,
        encode_progress_percent = encode_progress_percent,
        format_encode_progress_label = format_encode_progress_label,
        insert_ffmpeg_progress_args = insert_ffmpeg_progress_args,
        remap_ffmpeg_args_for_remote = remap_ffmpeg_args_for_remote,
    },
}