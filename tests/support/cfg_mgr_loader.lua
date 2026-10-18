local M = {}

local function deep_copy(value)
    if type(value) ~= 'table' then return value end
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = deep_copy(item)
    end
    return copy
end

local function parse_option(value, default)
    if type(default) == 'boolean' then
        if type(value) == 'boolean' then return value end
        local normalized = tostring(value):lower()
        return normalized == 'yes' or normalized == 'true' or normalized == 'enabled'
    end
    if type(default) == 'number' then
        return tonumber(value) or default
    end
    return value
end

function M.load(option_files)
    for _, name in ipairs({
        'cfg_mgr', 'mp', 'mp.options', 'mp.msg', 'mp.utils', 'helpers', 'utils.logger',
    }) do
        package.loaded[name] = nil
    end

    package.preload['mp'] = function()
        return {
            get_script_directory = function()
                return '/test/mpv/scripts/mpv-anki-clips'
            end,
        }
    end

    package.preload['mp.options'] = function()
        return {
            read_options = function(options, name)
                for key, value in pairs(option_files[name] or {}) do
                    if options[key] ~= nil then
                        options[key] = parse_option(value, options[key])
                    end
                end
            end,
        }
    end

    package.preload['mp.msg'] = function()
        return {
            info = function() end,
            warn = function() end,
            fatal = function() end,
        }
    end

    package.preload['mp.utils'] = function()
        return {
            file_info = function()
                return { is_file = true }
            end,
            split_path = function(path)
                local normalized = path:gsub('\\', '/')
                local parent, leaf = normalized:match('^(.*)/([^/]+)$')
                return (parent or '') .. '/', leaf
            end,
            join_path = function(parent, child)
                return parent:gsub('/$', '') .. '/' .. child
            end,
        }
    end

    package.preload['helpers'] = function()
        return {
            deepcopy = deep_copy,
            is_empty = function(value)
                if value == nil or value == '' then return true end
                return type(value) == 'table' and next(value) == nil
            end,
            notify = function() end,
        }
    end

    package.preload['utils.logger'] = function()
        return {
            info_cat = function() end,
            set_config = function() end,
        }
    end

    local config = {
        remove_arrows = 'join',
        video_width = -2,
        video_height = 240,
        video_fps = 24,
        video_container = 'mkv',
        video_codec = 'libx264',
        video_preset = 'slow',
        video_quality_management = 'enabled',
        video_filter = 'enabled',
        video_use_crf = true,
        video_two_pass = false,
        video_crf = 20,
        video_bitrate = '500k',
        audio_codec = 'aac',
        audio_quality_management = 'enabled',
        audio_use_vbr = true,
        audio_bitrate = '128k',
        audio_track_count = 1,
        audio_lang_priority = 'en',
        subtitle_track_count = 2,
        subtitle_lang_priority = 'en',
        include_external_subtitles = false,
        external_subtitle_unknown_language = 'und',
        include_metadata = true,
        enable_video = true,
        enable_audio = true,
        miscinfo_format = 'base profile format',
    }
    local core_config = {
        card_overwrite_safeguard = 1,
        autoclip = false,
        autoclip_method = 'clipboard',
        autoclip_custom_args = '',
        copy_text_mode = 'core-copy',
        copy_text_custom_pattern = '',
        copy_text_custom_replacement = '',
        copy_text_custom_scope = 'all',
        copy_text_custom_base_mode = 'subtitle_content',
        use_clipboard_when_empty = false,
        create_deck = false,
        deck_name = 'test-deck',
        model_name = 'test-model',
        sentence_field_1 = 'front',
        secondary_field_1 = '',
        video_field_1 = 'video',
        miscinfo_field_1 = 'notes',
        sentence_field_2 = '',
        secondary_field_2 = '',
        video_field_2 = '',
        miscinfo_field_2 = '',
        sentence_field_3 = '',
        secondary_field_3 = '',
        video_field_3 = '',
        miscinfo_field_3 = '',
        note_tag = 'test',
        highlight_exported_notes_in_browser = false,
        subtitle_lang_priority = 'en',
        secondary_sub_auto_load = false,
        secondary_sub_lang = 'en',
        secondary_sub_area = 0.1,
        secondary_sub_visibility = 'auto',
        miscinfo_enable = true,
        queue_details_format = 'core queue details',
        subtitle_preview_font_scale = 1,
        preview_text_char_limit = 40,
        captured_primarysub_preview_char_limit = 40,
        captured_secondarysub_preview_char_limit = 40,
        cap_video_custom_args_preview = true,
        preview_video = 'toast',
        test_encode_output_dir = '',
        remote_ffmpeg_enabled = 'no',
        remote_ssh_host = '',
        remote_ssh_user = '',
        remote_ssh_port = 22,
        remote_ssh_identity_file = '',
        remote_ssh_extra_args = '',
        remote_ffmpeg_exec = 'ffmpeg',
        remote_encode_staging_dir_local = '',
        remote_encode_staging_dir_remote = '',
        remote_path_map = '',
        remote_encode_cleanup = true,
        use_forvo = 'no',
        vocab_field = 'expression',
        vocab_audio_field = 'audio',
        menu_font_size = 25,
        menu_font_name = 'sans-serif',
        show_selected_text = true,
        ankiconnect_url = '127.0.0.1:8765',
        ankiconnect_api_key = '',
        fix_subtitle_duration = false,
        clip_log_enabled = false,
        clip_log_save_dir = '',
        clip_log_advanced_encode_logging = false,
        clip_log_duplicate_overlap_percent = 90,
        queue_server_enabled = false,
        queue_server_host = '',
        queue_server_port = 56789,
        queue_server_connect_timeout = 2,
        queue_server_request_timeout = 5,
        queue_server_heartbeat_interval = 10,
        debug_level = 'low',
    }
    local profiles = {
        profiles = 'mpv-anki-clips,games',
        active = 'mpv-anki-clips',
    }

    local manager = require('cfg_mgr')
    manager.init(config, profiles, core_config)
    return manager, config, profiles, deep_copy(core_config)
end

return M
