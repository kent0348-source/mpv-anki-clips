local assertx = require('tests.support.assert')

local function load_observer(config_overrides, properties)
    package.loaded['subtitles.observer'] = nil
    package.loaded['subtitles.sub_list'] = nil
    package.loaded['subtitles.subtitle'] = nil
    package.loaded['helpers'] = nil
    package.preload['helpers'] = nil
    package.loaded['mp'] = nil
    package.loaded['mp.msg'] = nil
    package.loaded['mp.utils'] = nil
    package.loaded['platform.init'] = nil
    package.loaded['utils.logger'] = nil

    local clipboard = {}
    local property_values = properties or {}

    package.preload['mp'] = function()
        return {
            get_property = function(name)
                return property_values[name]
            end,
            get_property_number = function(name)
                return tonumber(property_values[name]) or 0
            end,
            get_property_native = function(name)
                return property_values[name] or 0
            end,
            observe_property = function()
            end,
            osd_message = function()
            end,
            add_timeout = function(_, callback)
                if callback then
                    callback()
                end
            end,
            add_periodic_timer = function()
                return {
                    kill = function()
                    end,
                }
            end,
            command_native = function()
                return { status = 0, stdout = '', stderr = '' }
            end,
            command_native_async = function(_, callback)
                if callback then
                    callback(true, { status = 0, stdout = '', stderr = '' })
                end
            end,
        }
    end

    package.preload['mp.msg'] = function()
        return {
            debug = function()
            end,
            info = function()
            end,
            warn = function()
            end,
            error = function()
            end,
        }
    end

    package.preload['mp.utils'] = function()
        return {}
    end

    package.preload['utils.logger'] = function()
        return {
            info_cat = function()
            end,
        }
    end

    package.preload['platform.init'] = function()
        return {
            healthy = true,
            clip_util = 'clipboard',
            copy_to_clipboard = function(text)
                clipboard[#clipboard + 1] = text
            end,
        }
    end

    local observer = require('subtitles.observer')
    observer.init(
        {
            update = function()
            end,
        },
        {
            autoclip = false,
            autoclip_method = 'clipboard',
            preserve_japanese_parentheses = false,
            remove_arrows = 'join',
            nuke_spaces = false,
            copy_text_mode = 'single_line',
            copy_text_custom_pattern = '',
            copy_text_custom_replacement = '',
            copy_text_custom_scope = 'all',
            copy_text_custom_base_mode = 'single_line',
            video_padding = 0.12,
        }
    )

    for key, value in pairs(config_overrides or {}) do
        observer.config[key] = value
    end

    return observer, clipboard, property_values
end

return {
    {
        name = 'observer copy_current_primary_to_clipboard collapses newlines in single_line mode',
        run = function()
            local observer, clipboard = load_observer(nil, {
                ['sub-text'] = 'foo\nbar',
            })

            observer.copy_current_primary_to_clipboard()

            assertx.equals('foo bar', clipboard[1], 'single_line mode should collapse copied subtitle text')
        end,
    },
    {
        name = 'observer copy_current_primary_to_clipboard preserves raw subtitle text in subtitle_content mode',
        run = function()
            local observer, clipboard = load_observer({ copy_text_mode = 'subtitle_content' }, {
                ['sub-text'] = ' foo ➡\nbar ',
            })

            observer.copy_current_primary_to_clipboard()

            assertx.equals(' foo ➡\nbar ', clipboard[1], 'subtitle_content mode should preserve copied subtitle text as-is')
        end,
    },
    {
        name = 'observer copy_current_primary_to_clipboard applies custom pattern per line before single-line formatting',
        run = function()
            local observer, clipboard = load_observer({
                copy_text_mode = 'custom_pattern',
                copy_text_custom_pattern = '^[^:]+:%s*',
                copy_text_custom_replacement = '',
                copy_text_custom_scope = 'per_line',
                copy_text_custom_base_mode = 'single_line',
            }, {
                ['sub-text'] = 'エミッサリー: 俺は\nハンター: まあ',
            })

            observer.copy_current_primary_to_clipboard()

            assertx.equals('俺は まあ', clipboard[1], 'custom_pattern mode should strip line prefixes before collapsing lines')
        end,
    },
    {
        name = 'observer copy_current_primary_to_clipboard applies custom pattern with subtitle-content base mode',
        run = function()
            local observer, clipboard = load_observer({
                copy_text_mode = 'custom_pattern',
                copy_text_custom_pattern = '^[^:]+:%s*',
                copy_text_custom_replacement = '',
                copy_text_custom_scope = 'per_line',
                copy_text_custom_base_mode = 'subtitle_content',
            }, {
                ['sub-text'] = 'エミッサリー: 俺は\nハンター: まあ',
            })

            observer.copy_current_primary_to_clipboard()

            assertx.equals('俺は\nまあ', clipboard[1], 'custom_pattern mode should preserve newlines when subtitle_content is the base mode')
        end,
    },
    {
        name = 'observer set_manual_timing does not capture visible subtitles while capture is disabled',
        run = function()
            local observer, _, property_values = load_observer(nil, {
                ['time-pos'] = 12,
                ['audio-delay'] = 0,
                ['sub-delay'] = 0,
                ['sub-text'] = 'visible line',
                ['sub-start'] = 11,
                ['sub-end'] = 13,
            })

            observer.toggle_subtitle_capture()
            observer.set_manual_timing('start')

            assertx.equals(true, observer.subtitle_capture_disabled(), 'subtitle capture should remain disabled after setting timings')
            assertx.equals(0, #observer.recorded_subs(), 'visible subtitles should not be appended while capture is disabled')

            property_values['sub-text'] = 'next line'
            property_values['sub-start'] = 13
            property_values['sub-end'] = 14
            observer.toggle_subtitle_capture()

            assertx.equals(false, observer.subtitle_capture_disabled(), 'subtitle capture should re-enable on second toggle')
            assertx.equals(1, #observer.recorded_subs(), 're-enabling capture should append the current visible subtitle when timings are active')
            assertx.equals('next line', observer.recorded_subs()[1].text, 're-enabled capture should track the current visible subtitle')
        end,
    },
    {
        name = 'observer remove_current_subtitle_from_recorded removes matching captured subtitle',
        run = function()
            local observer = load_observer(nil, {
                ['audio-delay'] = 0,
                ['sub-delay'] = 0,
                ['sub-text'] = 'captured line',
                ['sub-start'] = 21,
                ['sub-end'] = 23,
            })

            observer.set_to_current_sub()
            assertx.equals(1, #observer.recorded_subs(), 'precondition failed: expected one recorded subtitle')

            observer.remove_current_subtitle_from_recorded()

            assertx.equals(0, #observer.recorded_subs(), 'current visible subtitle should be removed from the recorded list')
        end,
    },
}