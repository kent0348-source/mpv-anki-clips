local assertx = require('tests.support.assert')

return {
    {
        name = 'menu actions have stable names and temporary menu bindings',
        run = function()
            local old_modules = {
                mp = package.loaded.mp,
                mp_msg = package.loaded['mp.msg'],
                helpers = package.loaded.helpers,
                menu = package.loaded.menu,
            }
            local calls = {
                named = {},
                forced = {},
                removed = {},
            }
            local fake_mp = {
                msg = { error = function() end },
                create_osd_overlay = function()
                    return {
                        update = function() end,
                        remove = function() end,
                    }
                end,
                get_property = function() return 'test-mpv' end,
                add_key_binding = function(key, name, fn)
                    table.insert(calls.named, { key = key, name = name, fn = fn })
                end,
                add_forced_key_binding = function(key, name, fn)
                    table.insert(calls.forced, { key = key, name = name, fn = fn })
                end,
                remove_key_binding = function(name)
                    table.insert(calls.removed, name)
                end,
            }
            package.loaded.mp = fake_mp
            package.loaded['mp.msg'] = fake_mp.msg
            package.loaded.helpers = { notify = function() end }
            package.loaded.menu = nil

            local Menu = require('menu')
            local action_called = false
            local instance = Menu:new({
                keybindings = {
                    {
                        key = 'e',
                        action_name = 'mpv-anki-clips-sub-seek-forward',
                        fn = function() action_called = true end,
                    },
                    {
                        key = '',
                        action_name = 'mpv-anki-clips-toggle-capture',
                        fn = function() end,
                    },
                    {
                        key = 'q',
                        scope = 'global',
                        action_name = 'mpv-anki-clips-copy-sub-to-clipboard',
                        fn = function() end,
                    },
                },
            })
            instance.make_osd = function()
                return { get_text = function() return '' end }
            end

            instance:register_keybindings()
            assertx.equals(2, #calls.named)
            local named_by_name = {}
            for _, call in ipairs(calls.named) do
                named_by_name[call.name] = call
            end
            assertx.equals(nil, named_by_name['mpv-anki-clips-sub-seek-forward'].key)
            assertx.equals(nil, named_by_name['mpv-anki-clips-toggle-capture'].key)
            assertx.equals(nil, named_by_name['mpv-anki-clips-copy-sub-to-clipboard'])
            named_by_name['mpv-anki-clips-sub-seek-forward'].fn()
            assertx.equals(true, action_called)
            fake_mp.add_key_binding('q', 'mpv-anki-clips-copy-sub-to-clipboard', function() end)
            assertx.equals('q', calls.named[3].key)

            instance:open()
            assertx.equals(true, instance.active)
            assertx.equals(1, #calls.forced)
            assertx.equals('e', calls.forced[1].key)
            assertx.equals('mpv-anki-clips-sub-seek-forward-menu', calls.forced[1].name)
            instance:close()
            assertx.equals(false, instance.active)
            assertx.equals('mpv-anki-clips-sub-seek-forward-menu', calls.removed[1])

            package.loaded.mp = old_modules.mp
            package.loaded['mp.msg'] = old_modules.mp_msg
            package.loaded.helpers = old_modules.helpers
            package.loaded.menu = old_modules.menu
        end,
    },
}
