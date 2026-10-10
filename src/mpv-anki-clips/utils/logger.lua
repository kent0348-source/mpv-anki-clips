--[[
Lightweight category-based logger with debug levels.
Levels: low, basic, advanced, full
  - low: only uncategorized existing logs (no categories)
  - basic: ffmpeg_info, ffmpeg_encode_output
  - advanced: ffmpeg_info, ffmpeg_encode_output, file_integrity
  - full: all categories (ffmpeg_info, codec_compat, profile_load, file_integrity, loudnorm_detail, ffmpeg_encode_output)
Categories:
  - ffmpeg_info
  - codec_compat
  - profile_load
  - file_integrity
  - loudnorm_detail
  - ffmpeg_encode_output
Only console logging is gated; OSD messages are unaffected elsewhere.
]]

local msg = require('mp.msg')

local M = {}

local state = {
  level = 'low',
  enabled = {
    -- filled by set_level
  }
}

local function normalize_level(lvl)
  if type(lvl) ~= 'string' or lvl == '' then return 'low' end
  lvl = string.lower(lvl)
  if lvl == 'low' or lvl == 'basic' or lvl == 'advanced' or lvl == 'full' then return lvl end
  -- accept synonyms
  if lvl == 'none' or lvl == 'off' or lvl == 'minimal' then return 'low' end
  return 'low'
end

local function recompute_enabled()
  local enabled = {}
  if state.level == 'basic' then
    enabled['ffmpeg_info'] = true
    enabled['ffmpeg_encode_output'] = true
  elseif state.level == 'advanced' then
    enabled['ffmpeg_info'] = true
    enabled['file_integrity'] = true
    enabled['ffmpeg_encode_output'] = true
  elseif state.level == 'full' then
    enabled['ffmpeg_info'] = true
    enabled['codec_compat'] = true
    enabled['profile_load'] = true
    enabled['file_integrity'] = true
    enabled['loudnorm_detail'] = true
    enabled['ffmpeg_encode_output'] = true
  end
  state.enabled = enabled
end

function M.set_level(lvl)
  state.level = normalize_level(lvl)
  recompute_enabled()
end

function M.set_config(cfg)
  local lvl = 'low'
  if cfg and cfg.debug_level then
    lvl = cfg.debug_level
  end
  M.set_level(lvl)
end

function M.should_log(category)
  if not category or category == '' then return true end
  return state.enabled[category] == true
end

local function log_if(category, fn, text)
  if M.should_log(category) and text and text ~= '' then
    fn(text)
    return true
  end
  return false
end

function M.info_cat(category, text)
  return log_if(category, msg.info, text)
end

function M.warn_cat(category, text)
  return log_if(category, msg.warn, text)
end

function M.error_cat(category, text)
  return log_if(category, msg.error, text)
end

function M.level()
  return state.level
end

return M
