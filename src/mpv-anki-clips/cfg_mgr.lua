--[[
Copyright: Ren Tatsumoto and contributors
License: GNU GPL, version 3 or later; http://www.gnu.org/licenses/gpl.html

Config management, validation, loading.
]]

local mp = require('mp')
local mpopt = require('mp.options')
local msg = require('mp.msg')
local this = require('helpers')
local logger = require('utils.logger')
local utils = require('mp.utils')

local min_side_px = 42
local max_side_px = 1080
local default_height_px = 200

-- This constant should be used in place of width and/or height in the config file.
-- It tells the encoder to preserve aspect ratio when downscaling videos.
local preserve_aspect_ratio = -2

local self = {
    config = nil,
    profiles = nil,
    core_config = nil,
    initial_config = {},
    initial_core_config = {},
    cached_field_sets = nil -- Cache field sets from mpv-anki-clips-core.conf
}

-- Track which validation warnings have been shown (module-level to persist across calls)
local validation_notified = {}
local initial_validation_done = false

-- Helper function to show validation warnings only once per session
local function notify_validation_once(key, message)
    if not validation_notified[key] then
        validation_notified[key] = true
        msg.warn(message)
        if not initial_validation_done then
            this.notify(message, 'warn', 5)
        end
    else
        msg.warn(message) -- Still log to console but don't spam OSD
    end
end

local default_profile_name = 'mpv-anki-clips'
local base_profile_filename = 'mpv-anki-clips-base'
local core_filename = 'mpv-anki-clips-core'
local profiles_filename = 'mpv-anki-clips-profiles'

local function set_video_format()
    local valid_containers = {["mkv"]=true, ["mp4"]=true, ["webm"]=true}
    if not valid_containers[self.config.video_container] then
        self.config.video_container = "mkv"
    end
    self.config.video_extension = self.config.video_container == "mp4" and ".mp4" or ".mkv"

    local valid_codecs = {
        ["libx264"]=true, ["libvpx"]=true, ["libvpx-vp9"]=true,
        ["libsvtav1"]=true, ["librav1e"]=true, ["libaom-av1"]=true,
        ["av1_nvenc"]=true, ["av1_amf"]=true, ["av1_qsv"]=true,
        ["libx265"]=true
    }
    if not valid_codecs[self.config.video_codec] then
        self.config.video_codec = "libvpx-vp9"
    end

    if not (self.config.audio_codec == "libopus" or self.config.audio_codec == "aac") then
        self.config.audio_codec = "libopus"
    end

    -- av1_speed removed - now using video_preset for all codecs

    -- Set video_preset defaults based on codec if not already set
    if not self.config.video_preset or self.config.video_preset == "" then
        if self.config.video_codec == "libsvtav1" or self.config.video_codec == "librav1e" then
            self.config.video_preset = "6"  -- Default speed for SVT-AV1 and rav1e (0-10 range)
        elseif self.config.video_codec == "libaom-av1" then
            self.config.video_preset = "6"  -- Default cpu-used for libaom-av1 (0-13 range)
        elseif self.config.video_codec == "av1_nvenc" then
            self.config.video_preset = "p4"  -- Default preset for NVENC
        elseif self.config.video_codec == "av1_amf" then
            self.config.video_preset = "balanced"  -- Default quality for AMF
        elseif self.config.video_codec == "av1_qsv" then
            self.config.video_preset = "4"  -- Default preset for QSV (1-7 range)
        elseif self.config.video_codec == "libx264" or self.config.video_codec == "libx265" then
            self.config.video_preset = "slow"  -- Default preset for H.264/H.265
        end
    end

    -- Validate video_preset based on codec
    if self.config.video_codec == "libsvtav1" then
            -- libsvtav1 uses numeric presets 0-13
            local preset_num = tonumber(self.config.video_preset)
            if not preset_num or preset_num < 0 or preset_num > 13 then
                local warn_msg = "Invalid preset '" .. tostring(self.config.video_preset) .. "' for libsvtav1. Using default preset 6."
                notify_validation_once("libsvtav1_preset", warn_msg)
                self.config.video_preset = "6"
            end
        elseif self.config.video_codec == "librav1e" then
            -- librav1e uses speed values 0-10
            local speed_num = tonumber(self.config.video_preset)
            if not speed_num or speed_num < 0 or speed_num > 10 then
                local warn_msg = "Invalid speed '" .. tostring(self.config.video_preset) .. "' for librav1e. Using default speed 6."
                notify_validation_once("librav1e_speed", warn_msg)
                self.config.video_preset = "6"
            end
        elseif self.config.video_codec == "libaom-av1" then
            -- libaom-av1 uses cpu-used 0-13
            local cpu_num = tonumber(self.config.video_preset)
            if not cpu_num or cpu_num < 0 or cpu_num > 13 then
                local warn_msg = "Invalid cpu-used '" .. tostring(self.config.video_preset) .. "' for libaom-av1. Using default cpu-used 6."
                notify_validation_once("libaom_av1_cpu", warn_msg)
                self.config.video_preset = "6"
            end
        elseif self.config.video_codec == "av1_nvenc" then
            -- av1_nvenc uses p1-p8 presets
            if self.config.video_preset and not self.config.video_preset:match("^p[1-8]$") then
                local warn_msg = "Invalid preset '" .. tostring(self.config.video_preset) .. "' for av1_nvenc. Using default preset p4."
                notify_validation_once("av1_nvenc_preset", warn_msg)
                self.config.video_preset = "p4"
            end
        elseif self.config.video_codec == "av1_amf" then
            -- av1_amf uses quality/balanced/speed
            local valid_presets = {["quality"]=true, ["balanced"]=true, ["speed"]=true}
            if not valid_presets[self.config.video_preset] then
                local warn_msg = "Invalid quality '" .. tostring(self.config.video_preset) .. "' for av1_amf. Using default balanced."
                notify_validation_once("av1_amf_quality", warn_msg)
                self.config.video_preset = "balanced"
            end
        elseif self.config.video_codec == "av1_qsv" then
            -- av1_qsv uses numeric presets 1-7
            local preset_num = tonumber(self.config.video_preset)
            if not preset_num or preset_num < 1 or preset_num > 7 then
                local warn_msg = "Invalid preset '" .. tostring(self.config.video_preset) .. "' for av1_qsv. Using default preset 4."
                notify_validation_once("av1_qsv_preset", warn_msg)
                self.config.video_preset = "4"
            end
        elseif self.config.video_codec == "libx264" or self.config.video_codec == "libx265" then
            -- H.264/H.265 use named presets
            local valid_presets = {
                ["ultrafast"]=true, ["superfast"]=true, ["veryfast"]=true, ["faster"]=true,
                ["fast"]=true, ["medium"]=true, ["slow"]=true, ["slower"]=true, ["veryslow"]=true
            }
            if self.config.video_preset and not valid_presets[self.config.video_preset] then
                local warn_msg = "Invalid preset '" .. tostring(self.config.video_preset) .. "' for " .. self.config.video_codec .. ". Using default 'slow'."
                notify_validation_once("h264_h265_preset", warn_msg)
                self.config.video_preset = "slow"
            end
        end



    if self.config.subtitle_track_count == nil or self.config.subtitle_track_count < 0 then
        self.config.subtitle_track_count = 2
    end

    if type(self.config.subtitle_lang_priority) ~= "string" then
        self.config.subtitle_lang_priority = "jp,jpn,ja,eng,ger,de"
    end

    if self.config.include_external_subtitles == nil then
        self.config.include_external_subtitles = false
    end

    if type(self.config.external_subtitle_unknown_language) ~= "string" or this.is_empty(self.config.external_subtitle_unknown_language) then
        self.config.external_subtitle_unknown_language = "und"
    end

    local audio_track_count = tonumber(self.config.audio_track_count)
    if not audio_track_count or audio_track_count < 1 then
        audio_track_count = 1
    end
    self.config.audio_track_count = math.floor(audio_track_count)

    if type(self.config.audio_lang_priority) ~= "string" or this.is_empty(self.config.audio_lang_priority) then
        self.config.audio_lang_priority = "jp,jpn,ja,eng,en,und"
    end
end

local function ensure_in_range(dimension)
    self.config[dimension] = self.config[dimension] < min_side_px and preserve_aspect_ratio or self.config[dimension]
    self.config[dimension] = self.config[dimension] > max_side_px and max_side_px or self.config[dimension]
end

local function conditionally_set_defaults(width, height)
    if self.config[width] < 1 and self.config[height] < 1 then
        self.config[width] = preserve_aspect_ratio
        self.config[height] = default_height_px
    end
end

local function ensure_correct_fps()
    if self.config.video_fps == nil or self.config.video_fps < 0 or self.config.video_fps > 60 then
        self.config.video_fps = 24
    end
end

local function check_video_settings()
    ensure_in_range('video_width')
    ensure_in_range('video_height')
    conditionally_set_defaults('video_width', 'video_height')
    ensure_correct_fps()
end

local function validate_field_sets()
    if self.cached_field_sets then
        self.config.field_sets = this.deepcopy(self.cached_field_sets)
        logger.info_cat('profile_load', "Restored cached field sets: " .. #self.config.field_sets .. " sets")
        return
    end

    self.config.field_sets = {}
    local default_field_set = {
        sentence_field = self.config.sentence_field_1 or "example-sentence-mpv-anki-clips",
        secondary_field = self.config.secondary_field_1 or "example-sentence-translation-mpv-anki-clips",
        video_field = self.config.video_field_1 or "picture-mpv-anki-clips",
        miscinfo_field = self.config.miscinfo_field_1 or "notes",
    }
    table.insert(self.config.field_sets, default_field_set)
    msg.info("Added field set #1: sentence_field=" .. default_field_set.sentence_field)

    if self.config.sentence_field_2 ~= nil then
        local field_set_2 = {
            sentence_field = self.config.sentence_field_2 or "example-sentence-2",
            secondary_field = self.config.secondary_field_2 or "",
            video_field = self.config.video_field_2 or "",
            miscinfo_field = self.config.miscinfo_field_2 or "",
        }
        table.insert(self.config.field_sets, field_set_2)
        msg.info("Added field set #2: sentence_field=" .. field_set_2.sentence_field)
    end

    if self.config.sentence_field_3 ~= nil then
        local field_set_3 = {
            sentence_field = self.config.sentence_field_3 or "example-sentence-3",
            secondary_field = self.config.secondary_field_3 or "",
            video_field = self.config.video_field_3 or "",
            miscinfo_field = self.config.miscinfo_field_3 or "",
        }
        table.insert(self.config.field_sets, field_set_3)
        msg.info("Added field set #3: sentence_field=" .. field_set_3.sentence_field)
    end

    self.cached_field_sets = this.deepcopy(self.config.field_sets)
    msg.info("Total field sets: " .. #self.config.field_sets)
end

local function validate_config()
    set_video_format()
    check_video_settings()
    validate_field_sets()

    local function normalize_stream_toggle(value, default_value)
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

    self.config.enable_video = normalize_stream_toggle(self.config.enable_video, true)
    self.config.enable_audio = normalize_stream_toggle(self.config.enable_audio, true)

    -- Optional queue coordinator shared by mpv instances on the LAN.
    do
        local enabled = normalize_stream_toggle(self.config.queue_server_enabled, false)
        self.config.queue_server_enabled = enabled == true
        if type(self.config.queue_server_host) ~= 'string' then
            self.config.queue_server_host = ''
        end
        self.config.queue_server_host = self.config.queue_server_host:match('^%s*(.-)%s*$')
        if self.config.queue_server_host:find('://', 1, true)
                or self.config.queue_server_host:find('/', 1, true) then
            notify_validation_once('invalid_queue_host', 'queue_server_host must be a hostname or IP address without a URL scheme or path.')
            self.config.queue_server_host = ''
        end
        if self.config.queue_server_enabled and self.config.queue_server_host == '' then
            notify_validation_once('missing_queue_host', 'Queue server is enabled but queue_server_host is empty; disabling queue coordination.')
            self.config.queue_server_enabled = false
        end
        local port = tonumber(self.config.queue_server_port)
        if not port or port < 1 or port > 65535 then port = 56789 end
        self.config.queue_server_port = math.floor(port)
        local connect_timeout = tonumber(self.config.queue_server_connect_timeout)
        if not connect_timeout or connect_timeout <= 0 or connect_timeout > 60 then connect_timeout = 2 end
        self.config.queue_server_connect_timeout = connect_timeout
        local request_timeout = tonumber(self.config.queue_server_request_timeout)
        if not request_timeout or request_timeout <= 0 or request_timeout > 300 then request_timeout = 5 end
        self.config.queue_server_request_timeout = request_timeout
        local heartbeat_interval = tonumber(self.config.queue_server_heartbeat_interval)
        if not heartbeat_interval or heartbeat_interval < 1 or heartbeat_interval > 300 then heartbeat_interval = 10 end
        self.config.queue_server_heartbeat_interval = heartbeat_interval
    end

    -- Remote FFmpeg over SSH (optional)
    do
        local function to_bool(v)
            if v == true then return true end
            if v == false then return false end
            if type(v) == 'string' then
                local s = v:lower()
                if s == 'yes' or s == 'true' or s == 'enabled' then return true end
                if s == 'no' or s == 'false' or s == 'disabled' then return false end
            end
            return nil
        end

        local enabled = to_bool(self.config.remote_ffmpeg_enabled)
        if enabled == nil then enabled = false end
        self.config.remote_ffmpeg_enabled = enabled and 'yes' or 'no'

        if type(self.config.remote_ssh_host) ~= 'string' then self.config.remote_ssh_host = '' end
        if type(self.config.remote_ssh_user) ~= 'string' then self.config.remote_ssh_user = '' end
        if type(self.config.remote_ssh_identity_file) ~= 'string' then self.config.remote_ssh_identity_file = '' end
        if type(self.config.remote_ssh_extra_args) ~= 'string' then self.config.remote_ssh_extra_args = '' end
        if type(self.config.remote_ffmpeg_exec) ~= 'string' or self.config.remote_ffmpeg_exec == '' then self.config.remote_ffmpeg_exec = 'ffmpeg' end
        if type(self.config.remote_encode_staging_dir_local) ~= 'string' then self.config.remote_encode_staging_dir_local = '' end
        if type(self.config.remote_encode_staging_dir_remote) ~= 'string' then self.config.remote_encode_staging_dir_remote = '' end
        if type(self.config.remote_path_map) ~= 'string' then self.config.remote_path_map = '' end

        -- If remote staging dir is empty but local staging dir is present, assume same path on both machines
        if this.is_empty(self.config.remote_encode_staging_dir_remote) and not this.is_empty(self.config.remote_encode_staging_dir_local) then
            self.config.remote_encode_staging_dir_remote = self.config.remote_encode_staging_dir_local
        end

        local port = tonumber(self.config.remote_ssh_port)
        if not port or port < 1 or port > 65535 then port = 22 end
        self.config.remote_ssh_port = port

        local cleanup = to_bool(self.config.remote_encode_cleanup)
        if cleanup == nil then cleanup = true end
        self.config.remote_encode_cleanup = cleanup

        if enabled then
            if this.is_empty(self.config.remote_ssh_host) then
                notify_validation_once('remote_ssh_host_missing', 'remote_ffmpeg_enabled=yes but remote_ssh_host is empty. Disabling remote FFmpeg.')
                self.config.remote_ffmpeg_enabled = 'no'
            elseif this.is_empty(self.config.remote_encode_staging_dir_local) then
                notify_validation_once('remote_staging_dir_missing', 'remote_ffmpeg_enabled=yes but remote_encode_staging_dir_local is empty. Disabling remote FFmpeg.')
                self.config.remote_ffmpeg_enabled = 'no'
            end
        end
    end

    -- Validate video_filter option (enabled|disabled)
    do
        local vf = self.config.video_filter
        if type(vf) ~= 'string' then vf = nil end
        if vf then vf = vf:lower() end
        if vf ~= 'enabled' and vf ~= 'disabled' then
            self.config.video_filter = 'enabled'
        else
            self.config.video_filter = vf
        end
    end

    -- Validate remove_arrows option
    local valid_remove_arrows = {["yes"]=true, ["no"]=true, ["join"]=true, ["join_arrow"]=true}
    if not valid_remove_arrows[self.config.remove_arrows] then
        local warn_msg = "Invalid remove_arrows option, defaulting to 'join_arrow'"
        notify_validation_once("remove_arrows", warn_msg)
        self.config.remove_arrows = "join_arrow"
    end

    -- Set default for include_metadata
    if self.config.include_metadata == nil then
        self.config.include_metadata = true
    end

    do
        local enabled = self.config.clip_log_enabled
        if enabled == nil then
            enabled = false
        elseif type(enabled) == 'string' then
            local normalized = enabled:lower()
            enabled = normalized == 'yes' or normalized == 'true' or normalized == 'enabled'
        else
            enabled = enabled == true
        end
        self.config.clip_log_enabled = enabled

        if type(self.config.clip_log_save_dir) ~= 'string' then
            self.config.clip_log_save_dir = ''
        end
        if this.is_empty(self.config.clip_log_save_dir) then
            self.config.clip_log_save_dir = utils.join_path(mp.get_script_directory(), 'clip_logs')
        end

        local overlap_percent = tonumber(self.config.clip_log_duplicate_overlap_percent)
        if not overlap_percent or overlap_percent < 0 or overlap_percent > 100 then
            notify_validation_once(
                'clip_log_duplicate_overlap_percent',
                'Invalid clip_log_duplicate_overlap_percent. Using default 90.'
            )
            overlap_percent = 90
        end
        self.config.clip_log_duplicate_overlap_percent = overlap_percent

        local advanced = self.config.clip_log_advanced_encode_logging
        if advanced == nil then
            advanced = false
        elseif type(advanced) == 'string' then
            local normalized = advanced:lower()
            advanced = normalized == 'yes' or normalized == 'true' or normalized == 'enabled'
        else
            advanced = advanced == true
        end
        self.config.clip_log_advanced_encode_logging = advanced
    end

    -- Mark initial validation as complete
    initial_validation_done = true
end

local function remember_initial_config()
    if this.is_empty(self.initial_config) then
        for key, value in pairs(self.config) do
            self.initial_config[key] = value
        end
        for key, value in pairs(self.core_config) do
            self.initial_core_config[key] = value
        end
    else
        msg.fatal("Ignoring. Initial config has been read already.")
    end
end

local function restore_initial_config()
    for key, value in pairs(self.initial_config) do
        self.config[key] = value
    end
    for key, value in pairs(self.initial_core_config) do
        self.core_config[key] = value
    end
end

local function read_profile_list()
    self.profiles = self.profiles or {}
    mpopt.read_options(self.profiles, profiles_filename)
    if not self.profiles.profiles or self.profiles.profiles == "" then
        self.profiles.profiles = "mpv-anki-clips"
        self.profiles.active = "mpv-anki-clips"
        msg.warn("No valid profiles found in " .. profiles_filename .. ".conf, using default: mpv-anki-clips")
    end
    msg.info("Read profile list. Defined profiles: " .. self.profiles.profiles)
end

local function read_profile(profile_name)
    mpopt.read_options(self.config, profile_name)

    -- Handle boolean options for base settings
    if self.config.video_two_pass == "" then
        self.config.video_two_pass = nil
    elseif self.config.video_two_pass == "yes" then
        self.config.video_two_pass = true
    elseif self.config.video_two_pass == "no" then
        self.config.video_two_pass = false
    end

    if self.config.video_use_crf == "" then
        self.config.video_use_crf = nil
    elseif self.config.video_use_crf == "yes" then
        self.config.video_use_crf = true
    elseif self.config.video_use_crf == "no" then
        self.config.video_use_crf = false
    end

    if self.config.audio_use_vbr == "" then
        self.config.audio_use_vbr = nil
    elseif self.config.audio_use_vbr == "yes" then
        self.config.audio_use_vbr = true
    elseif self.config.audio_use_vbr == "no" then
        self.config.audio_use_vbr = false
    end

    if self.config.enable_video == "" then
        self.config.enable_video = nil
    elseif self.config.enable_video == "yes" then
        self.config.enable_video = true
    elseif self.config.enable_video == "no" then
        self.config.enable_video = false
    end

    if self.config.enable_audio == "" then
        self.config.enable_audio = nil
    elseif self.config.enable_audio == "yes" then
        self.config.enable_audio = true
    elseif self.config.enable_audio == "no" then
        self.config.enable_audio = false
    end

    -- Quality management (tri-state) with backward compatibility
    local function norm_qm(val, kind)
        if type(val) ~= 'string' then return nil end
        val = val:lower()
        if val == 'enabled' or val == 'disabled' then return val end
        if kind == 'video' and val == 'allow_combined_crf_bitrate' then return val end
        if kind == 'audio' and val == 'allow_combined_vbr_bitrate' then return val end
        return nil
    end

    -- Derive video_quality_management
    do
        local vqm = norm_qm(self.config.video_quality_management, 'video')
        if not vqm then
            -- Map old allow_combined_crf_bitrate if present
            if self.config.allow_combined_crf_bitrate == true or self.config.allow_combined_crf_bitrate == 'yes' then
                vqm = 'allow_combined_crf_bitrate'
            else
                vqm = 'enabled'
            end
        end
        self.config.video_quality_management = vqm
    end

    -- Derive audio_quality_management
    do
        local aqm = norm_qm(self.config.audio_quality_management, 'audio')
        if not aqm then
            if self.config.allow_combined_vbr_bitrate == true or self.config.allow_combined_vbr_bitrate == 'yes' then
                aqm = 'allow_combined_vbr_bitrate'
            else
                aqm = 'enabled'
            end
        end
        self.config.audio_quality_management = aqm
    end

    -- (no test mode toggle; only test output dir is supported)

    if self.config.include_metadata == "" then
        self.config.include_metadata = nil
    elseif self.config.include_metadata == "yes" then
        self.config.include_metadata = true
    elseif self.config.include_metadata == "no" then
        self.config.include_metadata = false
    end

    if self.config.remove_arrows == nil then
        self.config.remove_arrows = "join_arrow" -- Default to join_arrow
    end
    logger.info_cat('profile_load', "Read config file: " .. profile_name)
end

local function read_default_config()
    read_profile(base_profile_filename)
end

local function read_core_config()
    mpopt.read_options(self.core_config, core_filename)
    logger.info_cat('profile_load', "Read core config file: " .. core_filename)
end

local function apply_core_config()
    for key, value in pairs(self.core_config) do
        self.config[key] = value
    end
end

local function reload_from_disk()
    if not this.is_empty(self.config) and not this.is_empty(self.profiles) then
        restore_initial_config()
        read_default_config()
        if self.profiles.active ~= default_profile_name then
            read_profile(self.profiles.active)
        end
        read_core_config()
        apply_core_config()
        -- Reset validation notifications and allow OSD warnings on profile switch
        validation_notified = {}
        initial_validation_done = false
        validate_config()
        initial_validation_done = true
        -- Update logger with potentially changed debug level
        logger.set_config(self.config)
    else
        msg.fatal("Attempt to load config when init hasn't been done.")
    end
end

local function next_profile()
    local first, next, new
    for profile in string.gmatch(self.profiles.profiles, '[^,]+') do
        if not first then
            first = profile
        end
        if profile == self.profiles.active then
            next = true
        elseif next then
            next = false
            new = profile
        end
    end
    if next == true or not new then
        new = first
    end
    self.profiles.active = new
    reload_from_disk()
end

local function previous_profile()
    local profiles_list = {}
    local active_index = nil
    local last_profile = nil

    for profile in string.gmatch(self.profiles.profiles, '[^,]+') do
        table.insert(profiles_list, profile)
        if profile == self.profiles.active then
            active_index = #profiles_list
        end
        last_profile = profile
    end

    if not active_index or #profiles_list == 0 then
        self.profiles.active = last_profile or self.profiles.active
    else
        local new_index = active_index - 1
        if new_index < 1 then
            new_index = #profiles_list
        end
        self.profiles.active = profiles_list[new_index]
    end

    reload_from_disk()
end

local function copy_example_config_if_missing(config_filepath, example_config_filepath, name, notification)
    local file_info = utils.file_info(config_filepath)
    if file_info and file_info.is_file then
        msg.info("Config already exists: " .. config_filepath)
        return
    end

    local handle = io.open(example_config_filepath, 'r')
    if handle == nil then
        msg.error("Failed to read example config: " .. example_config_filepath)
        return
    end

    local content = handle:read("*a")
    handle:close()

    handle = io.open(config_filepath, 'w')
    if handle == nil then
        this.notify(string.format("Couldn't open %s.", config_filepath), "error", 4)
        return
    end

    handle:write(string.format("# Written by %s on %s.\n", name, os.date()))
    handle:write(content)
    handle:close()
    this.notify(notification, "info", 2)
end

local function create_config_file()
    local parent = utils.split_path(mp.get_script_directory())
    parent = utils.split_path(parent:gsub("/$", ""))
    local script_opts_directory = utils.join_path(parent, "script-opts")
    local script_directory = mp.get_script_directory()

    copy_example_config_if_missing(
        utils.join_path(script_opts_directory, base_profile_filename .. ".conf"),
        utils.join_path(script_directory, "exampleconfig/mpv-anki-clips-base.conf"),
        base_profile_filename,
        "Settings saved."
    )
    copy_example_config_if_missing(
        utils.join_path(script_opts_directory, core_filename .. ".conf"),
        utils.join_path(script_directory, "exampleconfig/mpv-anki-clips-core.conf"),
        core_filename,
        "Core settings saved."
    )
    copy_example_config_if_missing(
        utils.join_path(script_opts_directory, profiles_filename .. ".conf"),
        utils.join_path(script_directory, "exampleconfig/mpv-anki-clips-profiles.conf"),
        profiles_filename,
        "Profile settings saved."
    )
end

local function init(config_table, profiles_table, core_config_table)
    create_config_file()
    self.config, self.profiles, self.core_config = config_table, profiles_table, core_config_table
    read_profile_list()
    read_default_config()
    read_core_config()
    remember_initial_config()
    if self.profiles.active ~= default_profile_name then
        read_profile(self.profiles.active)
    end
    apply_core_config()
    validate_config()
    -- Initialize logger with current config (for debug level control)
    logger.set_config(self.config)
end

return {
    reload_from_disk = reload_from_disk,
    init = init,
    next_profile = next_profile,
    previous_profile = previous_profile,
    default_height_px = default_height_px,
    preserve_aspect_ratio = preserve_aspect_ratio,
}