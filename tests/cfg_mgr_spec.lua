local assertx = require('tests.support.assert')
local loader = require('tests.support.cfg_mgr_loader')

return {
    {
        name = 'core settings override profile values and survive profile changes',
        run = function()
            local files = {
                ['mpv-anki-clips-profiles'] = {
                    profiles = 'mpv-anki-clips,games',
                    active = 'mpv-anki-clips',
                },
                ['mpv-anki-clips-base'] = {
                    video_height = 360,
                    miscinfo_format = 'base format',
                    copy_text_mode = 'base-profile-copy',
                    preview_video = 'yes',
                    queue_server_enabled = 'yes',
                    fix_subtitle_duration = 'no',
                    miscinfo_enable = 'no',
                },
                games = {
                    video_height = 720,
                    miscinfo_format = 'game format',
                    copy_text_mode = 'game-profile-copy',
                    preview_video = 'no',
                    queue_server_enabled = 'yes',
                    fix_subtitle_duration = 'no',
                    miscinfo_enable = 'no',
                },
                ['mpv-anki-clips-core'] = {
                    copy_text_mode = 'core-copy',
                    preview_video = 'toast',
                    queue_server_enabled = 'no',
                    fix_subtitle_duration = 'yes',
                    miscinfo_enable = 'yes',
                    queue_details_format = 'core queue details',
                },
            }
            local manager, config, profiles = loader.load(files)

            assertx.equals(360, config.video_height)
            assertx.equals('base format', config.miscinfo_format)
            assertx.equals('core-copy', config.copy_text_mode)
            assertx.equals('toast', config.preview_video)
            assertx.equals(false, config.queue_server_enabled)
            assertx.equals(true, config.fix_subtitle_duration)
            assertx.equals(true, config.miscinfo_enable)
            assertx.equals('core queue details', config.queue_details_format)

            manager.next_profile()
            assertx.equals('games', profiles.active)
            assertx.equals(720, config.video_height)
            assertx.equals('game format', config.miscinfo_format)
            assertx.equals('core-copy', config.copy_text_mode)
            assertx.equals('toast', config.preview_video)
            assertx.equals(false, config.queue_server_enabled)
            assertx.equals(true, config.fix_subtitle_duration)
            assertx.equals(true, config.miscinfo_enable)

            files['mpv-anki-clips-core'].copy_text_mode = 'updated-core-copy'
            files['mpv-anki-clips-core'].preview_video = 'no'
            manager.reload_from_disk()
            assertx.equals('updated-core-copy', config.copy_text_mode)
            assertx.equals('no', config.preview_video)
            assertx.equals(720, config.video_height)
            assertx.equals('game format', config.miscinfo_format)

            manager.previous_profile()
            assertx.equals('mpv-anki-clips', profiles.active)
            assertx.equals(360, config.video_height)
            assertx.equals('base format', config.miscinfo_format)
            assertx.equals('updated-core-copy', config.copy_text_mode)
            assertx.equals('no', config.preview_video)
        end,
    },
}
