local script_path = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
local project_root = script_path:match('^(.*)/tests/run%.lua$')
if not project_root or project_root == '' then
    project_root = '.'
end

local app_root = project_root .. '/src/mpv-anki-clips'
package.path = table.concat({
    project_root .. '/?.lua',
    project_root .. '/?/init.lua',
    app_root .. '/?.lua',
    app_root .. '/?/init.lua',
    package.path,
}, ';')

local suites = {
    require('tests.ankiconnect_spec'),
    require('tests.encoder_spec'),
    require('tests.ffmpeg_exec_spec'),
    require('tests.helpers_spec'),
    require('tests.observer_spec'),
    require('tests.clip_logger_spec'),
    require('tests.queue_client_spec'),
    require('tests.platform_http_spec'),
    require('tests.cfg_mgr_spec'),
    require('tests.menu_spec'),
}

local passed = 0
local failed = 0

for _, suite in ipairs(suites) do
    for _, test_case in ipairs(suite) do
        io.write('[TEST] ' .. test_case.name .. ' ... ')
        local ok, err = pcall(test_case.run)
        if ok then
            passed = passed + 1
            print('ok')
        else
            failed = failed + 1
            print('FAIL')
            print(err)
        end
    end
end

if failed > 0 then
    error(string.format('%d tests failed (%d passed)', failed, passed))
end

print(string.format('All tests passed (%d total).', passed))