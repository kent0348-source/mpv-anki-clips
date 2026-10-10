local assertx = require('tests.support.assert')
local helpers_loader = require('tests.support.helpers_loader')

return {
    {
        name = 'helpers.deepcopy isolates independent note field updates',
        run = function()
            local helpers = helpers_loader.load_helpers()
            local template = {
                Front = 'new sentence',
                Video = '[sound:clip.mp3]',
            }
            local first_note = helpers.deepcopy(template)
            local second_note = helpers.deepcopy(template)

            first_note.Video = 'first note media' .. first_note.Video
            second_note.Video = 'second note media' .. second_note.Video

            assertx.equals('[sound:clip.mp3]', template.Video)
            assertx.equals('first note media[sound:clip.mp3]', first_note.Video)
            assertx.equals('second note media[sound:clip.mp3]', second_note.Video)
        end,
    },
    {
        name = 'helpers.get_episode_number extracts expected numbers',
        run = function()
            local helpers = helpers_loader.load_helpers()
            local test_cases = {
                { nil, 'A Whisker Away.mkv' },
                { nil, '[Placeholder] Gekijouban SHIROBAKO [Ma10p_1080p][x265_flac]' },
                { '06', '[Placeholder] Sono Bisque Doll wa Koi wo Suru - 06 [54E495D0]' },
                { '02', '(Hi10)_Kobayashi-san_Chi_no_Maid_Dragon_-_02_(BD_1080p)_(Placeholder)_(12C5D2B4)' },
                { '01', '[Placeholder] Koi to Yobu ni wa Kimochi Warui - 01 (1080p) [D517C9F0]' },
                { '01', '[Placeholder] Tsukimonogatari 01 [BD 1080p x264 10-bit FLAC] [5CD88145]' },
                { '01', '[Placeholder] 86 - Eighty Six - 01 (1080p) [1B13598F]' },
                { '00', '[Placeholder] Fate Stay Night - Unlimited Blade Works - 00 (BD 1080p Hi10 FLAC) [95590B7F]' },
                { '01', 'House, M.D. S01E01 Pilot - Everybody Lies (1080p x265 Placeholder)' },
                { '165', 'A Generic Episode-165' },
            }

            for _, case in ipairs(test_cases) do
                local _, _, episode_num = helpers.get_episode_number(case[2])
                assertx.equals(case[1], episode_num, 'episode number mismatch for ' .. case[2])
            end
        end,
    },
}