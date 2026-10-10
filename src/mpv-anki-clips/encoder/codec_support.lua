--[[
Copyright: Ajatt-Tools and contributors, updated by Grok 3 (beta)
License: GNU GPL, version 3 or later; http://www.gnu.org/licenses/gpl.html
]]

local msg = require('mp.msg')
local utils = require('mp.utils')
local h = require('helpers')
local logger = require('utils.logger')
local ffmpeg_executable = require('encoder.ffmpeg_exec')

local ffmpeg_exec = ffmpeg_executable.resolve()
local ffmpeg_encoders
local codec_support = { ffmpeg = { video = {}, audio = {} } }

local function resolve_ffmpeg_path()
    if ffmpeg_exec:find('/', 1, true) or ffmpeg_exec:find('\\', 1, true) then
        return ffmpeg_exec
    end

    local executable_name = ffmpeg_exec
    if h.is_win() and not executable_name:match('%.exe$') then
        executable_name = executable_name .. '.exe'
    end

    local separator = h.is_win() and ';' or ':'
    for path_entry in (os.getenv('PATH') or ''):gmatch('([^' .. separator .. ']+)') do
        local directory = path_entry:gsub('^"', ''):gsub('"$', '')
        local candidate = utils.join_path(directory, executable_name)
        local info = utils.file_info(candidate)
        if info and info.is_file then
            return candidate
        end
    end

    return ffmpeg_exec
end

local function log_ffmpeg_info()
    if not logger.should_log('ffmpeg_info') then
        return
    end

    local result = h.subprocess({ ffmpeg_exec, '-version' }, nil, { log_command = false })
    local version = (result.stdout or ''):match('([^\r\n]+)')
        or (result.stderr or ''):match('([^\r\n]+)')

    logger.info_cat('ffmpeg_info', string.format("Local FFmpeg path: %s", resolve_ffmpeg_path()))
    if result.status == 0 and version then
        logger.info_cat('ffmpeg_info', string.format("Local FFmpeg build: %s", version))
    else
        logger.warn_cat('ffmpeg_info', string.format(
            "Could not read local FFmpeg build (exit status: %s)",
            tostring(result.status)
        ))
    end
end

-- Check if a codec is supported by FFmpeg

local function is_video_codec_supported_ffmpeg(codec)
    local pattern = '[VA]%.[%.FSDB]*%s+' .. codec:gsub('-', '%%-') .. '[%s%(%[].*'
    return ffmpeg_encoders.status == 0 and ffmpeg_encoders.stdout:find(pattern) ~= nil
end

local function is_audio_codec_supported_ffmpeg(codec)
    local pattern = '[VA]%.[%.FSDB]*%s+' .. codec:gsub('-', '%%-') .. '[%s%(%[].*'
    return ffmpeg_encoders.status == 0 and ffmpeg_encoders.stdout:find(pattern) ~= nil
end

local video_codecs = {
    'libx264', 'libvpx', 'libvpx-vp9', 'libsvtav1', 'librav1e',
    'libaom-av1', 'av1_nvenc', 'av1_amf', 'av1_qsv', 'libx265',
}

local audio_codecs = { 'libopus', 'aac', 'libmp3lame', 'libfdk_aac' }

local function configure(config)
    ffmpeg_exec = ffmpeg_executable.resolve(config and config.ffmpeg_exec)
    ffmpeg_encoders = h.subprocess(
        { ffmpeg_exec, '-encoders', '-hide_banner' },
        nil,
        { log_command = false }
    )

    codec_support.ffmpeg.video = {}
    codec_support.ffmpeg.audio = {}
    for _, codec in ipairs(video_codecs) do
        codec_support.ffmpeg.video[codec] = is_video_codec_supported_ffmpeg(codec)
    end
    for _, codec in ipairs(audio_codecs) do
        codec_support.ffmpeg.audio[codec] = is_audio_codec_supported_ffmpeg(codec)
    end

    if config and type(config.ffmpeg_exec) == 'string' and config.ffmpeg_exec:match('%S')
        and ffmpeg_encoders.status ~= 0 then
        local error_message = (ffmpeg_encoders.stderr or ''):match('([^\r\n]+)')
            or 'could not execute the configured program'
        msg.warn(string.format(
            "Configured local FFmpeg '%s' could not be used: %s",
            config.ffmpeg_exec,
            error_message
        ))
    end
end

configure()

local function log_support()
    log_ffmpeg_info()

    for encoder, types in pairs(codec_support) do
        for type, codecs in pairs(types) do
            for codec, supported in pairs(codecs) do
                logger.info_cat('codec_compat', string.format("%s supports %s codec %s: %s", encoder, type, codec, tostring(supported)))
            end
        end
    end
end

-- Validate codec-container combination with OSD warnings.
-- Video/audio checks are skipped for streams that aren't being encoded.
local function is_valid_combination(video_codec, audio_codec, container, enable_video, enable_audio)
    if enable_video == nil then enable_video = true end
    if enable_audio == nil then enable_audio = true end

    if not enable_video and not enable_audio then
        local warn_msg = "At least one of enable_video or enable_audio must be enabled to encode media."
        msg.warn(warn_msg)
        h.notify(warn_msg, 'warn', 5)
        return false
    end

    local supported = {
        mkv = { video = true, audio = true },
        mp4 = { 
            video = { 
                ['libx264'] = true,
                ['libx265'] = true,
                ['libaom-av1'] = true,
                ['librav1e'] = true,
                ['libsvtav1'] = true,
                ['av1_nvenc'] = true,
                ['av1_amf'] = true,
                ['av1_qsv'] = true
            }, 
            audio = { ['aac'] = true } 
        },
        webm = { 
            video = { 
                ['libvpx'] = true, 
                ['libvpx-vp9'] = true,
                ['libaom-av1'] = true,
                ['librav1e'] = true,
                ['libsvtav1'] = true,
                ['av1_nvenc'] = true,
                ['av1_amf'] = true,
                ['av1_qsv'] = true
            }, 
            audio = { ['libopus'] = true } 
        },
    }

    local video_supported = enable_video and codec_support.ffmpeg.video[video_codec] or true
    local audio_supported = enable_audio and codec_support.ffmpeg.audio[audio_codec] or true

    if enable_video and not video_supported then
        local warn_msg = string.format("Video codec %s not supported by ffmpeg.", video_codec)
        msg.warn(warn_msg)
        h.notify(warn_msg, 'warn', 5)
        return false
    end
    if enable_audio and not audio_supported then
        local warn_msg = string.format("Audio codec %s not supported by ffmpeg.", audio_codec)
        msg.warn(warn_msg)
        h.notify(warn_msg, 'warn', 5)
        return false
    end

    local container_support = supported[container]
    if not container_support then
        local warn_msg = string.format("Container %s not recognized.", container)
        msg.warn(warn_msg)
        h.notify(warn_msg, 'warn', 5)
        return false
    end

    if enable_video and container_support.video ~= true and not container_support.video[video_codec] then
        local warn_msg = string.format("Video codec %s not compatible with %s container.", video_codec, container)
        msg.warn(warn_msg)
        h.notify(warn_msg, 'warn', 5)
        return false
    end
    if enable_audio and container_support.audio ~= true and not container_support.audio[audio_codec] then
        local warn_msg = string.format("Audio codec %s not compatible with %s container.", audio_codec, container)
        msg.warn(warn_msg)
        h.notify(warn_msg, 'warn', 5)
        return false
    end

    return true
end

return {
    codecs = codec_support,
    configure = configure,
    is_valid_combination = is_valid_combination,
    log_support = log_support,
}