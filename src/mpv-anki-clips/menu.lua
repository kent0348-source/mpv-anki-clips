--[[
Copyright: Ren Tatsumoto and contributors
License: GNU GPL, version 3 or later; http://www.gnu.org/licenses/gpl.html

Menu for MPV Anki Clips
]]

local mp = require('mp')
local msg = require('mp.msg')
local h = require('helpers')

local Menu = {
    active = false,
    keybindings = {},
    overlay = mp.create_osd_overlay and mp.create_osd_overlay('ass-events'),
}

function Menu:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Menu:with_update(params)
    return function()
        local status, error = pcall(h.unpack(params))
        if not status then
            msg['error'](error)
        end
        self:update()
    end
end

function Menu:make_osd()
    return nil
end

function Menu:update()
    if self.active == false then return end
    self.overlay.data = self:make_osd():get_text()
    self.overlay:update()
end

function Menu:open()
    if self.overlay == nil then
        h.notify("OSD overlay is not supported in " .. mp.get_property("mpv-version"), "error", 5)
        return
    end

    if self.active == true then
        self:close()
        return
    end

    for _, val in pairs(self.keybindings) do
        if val.key ~= "" and (val.scope == nil or val.scope == "advanced-menu") then
            val.menu_binding_name = val.menu_binding_name or (val.action_name or val.key) .. "-menu"
            mp.add_forced_key_binding(val.key, val.menu_binding_name, val.fn)
        end
    end

    self.active = true
    self:update()
end

function Menu:close()
    if self.active == false then
        return
    end

    for _, val in pairs(self.keybindings) do
        if val.key ~= "" and (val.scope == nil or val.scope == "advanced-menu") then
            mp.remove_key_binding(val.menu_binding_name or val.key)
        end
    end

    self.overlay:remove()
    self.active = false
end

function Menu:register_keybindings()
    for _, val in pairs(self.keybindings) do
        if val.action_name and val.scope ~= "global" then
            mp.add_key_binding(nil, val.action_name, val.fn)
        end
    end
end

return Menu
