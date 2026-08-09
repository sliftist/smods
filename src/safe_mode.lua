-- Safe mode, and a history of launch configurations that are known to work.
--
-- This file is loaded from the very top of main.lua, before its first require, and it is read
-- straight off disk rather than through the mod loader. Both are deliberate: the failure it exists
-- to rescue is a mod whose Lovely patch produces a file that will not parse, which kills the game
-- while main.lua is still requiring - long before any mod's own code, this loader included, would
-- otherwise run. An escape hatch that needs the mods to load cannot rescue the mods failing to load.

SafeMode = {}

local MODS_SUBDIR = "Mods"
local IGNORE_FILE = ".lovelyignore"
local HISTORY_FILE = "mod_launch_configs.jkr"
-- Enough to step back through a few bad additions without the list becoming something to read.
local MAX_HISTORY = 12
-- Kept enabled by safe mode: with the mod loader gone there is no menu left to recover from.
local SAFE_MODE_KEEP = { smods = true }
local RECOVERY_KEY = 'f8'
-- Lovely's own working directory sits among the mods and is not one.
local LOVELY_DIR_NAME = "lovely"

local function ignore_path(name)
    return MODS_SUBDIR .. "/" .. name .. "/" .. IGNORE_FILE
end

-- Every mod directory currently on disk, and whether it is switched on.
function SafeMode.installed()
    local mods = {}
    for _, name in ipairs(love.filesystem.getDirectoryItems(MODS_SUBDIR)) do
        local info = love.filesystem.getInfo(MODS_SUBDIR .. "/" .. name)
        if info and info.type == 'directory' and name ~= LOVELY_DIR_NAME then
            mods[#mods + 1] = { name = name, enabled = not love.filesystem.getInfo(ignore_path(name)) }
        end
    end
    table.sort(mods, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
    return mods
end

function SafeMode.enabled_names()
    local names = {}
    for _, mod in ipairs(SafeMode.installed()) do
        if mod.enabled then
            names[#names + 1] = mod.name
        end
    end
    return names
end

-- Identifies a configuration by exactly what it switches on, so relaunching the same set updates the
-- existing entry instead of filling the list with copies of itself.
local function signature(names)
    local sorted = {}
    for _, name in ipairs(names) do
        sorted[#sorted + 1] = name
    end
    table.sort(sorted)
    return table.concat(sorted, "|")
end

-- Stored as a Lua chunk so reading it back is load() rather than a parser written for the occasion.
function SafeMode.read_history()
    if not love.filesystem.getInfo(HISTORY_FILE) then
        return {}
    end
    local ok, chunk = pcall(love.filesystem.load, HISTORY_FILE)
    if not ok or not chunk then
        return {}
    end
    local read, value = pcall(chunk)
    if not read or type(value) ~= 'table' then
        return {}
    end
    return value
end

local function write_history(history)
    local parts = { "return {" }
    for _, entry in ipairs(history) do
        local names = {}
        for _, name in ipairs(entry.enabled) do
            names[#names + 1] = string.format("%q", name)
        end
        parts[#parts + 1] = string.format("  { at = %q, enabled = { %s } },", entry.at, table.concat(names, ", "))
    end
    parts[#parts + 1] = "}"
    love.filesystem.write(HISTORY_FILE, table.concat(parts, "\n"))
end

-- Called once the game is up. Only distinct configurations are kept: relaunching an unchanged set
-- refreshes its timestamp and moves it to the front rather than adding a row.
function SafeMode.record_success()
    local names = SafeMode.enabled_names()
    local sig = signature(names)
    local history = SafeMode.read_history()

    local kept = { { at = os.date("%Y-%m-%d %H:%M:%S"), enabled = names } }
    for _, entry in ipairs(history) do
        if signature(entry.enabled) ~= sig and #kept < MAX_HISTORY then
            kept[#kept + 1] = entry
        end
    end
    write_history(kept)
end

-- Switches the installed mods to exactly this set. Anything in the configuration that is no longer
-- installed is skipped rather than treated as an error - a configuration outlives the mods in it.
function SafeMode.apply(names)
    local wanted = {}
    for _, name in ipairs(names) do
        wanted[name] = true
    end
    local changed = {}
    for _, mod in ipairs(SafeMode.installed()) do
        if wanted[mod.name] and not mod.enabled then
            love.filesystem.remove(ignore_path(mod.name))
            changed[#changed + 1] = mod.name .. " on"
        elseif not wanted[mod.name] and mod.enabled then
            love.filesystem.write(ignore_path(mod.name), "")
            changed[#changed + 1] = mod.name .. " off"
        end
    end
    return changed
end

function SafeMode.enter()
    local keep = {}
    for name in pairs(SAFE_MODE_KEEP) do
        keep[#keep + 1] = name
    end
    return SafeMode.apply(keep)
end

--||| the error screen |||

local ref_errorhandler = love.errorhandler or love.errhand

-- Wraps the stock handler rather than replacing it: the instruction is appended to the message the
-- handler is about to draw, which is the one piece of that screen reachable from outside it, and the
-- key is read with isDown so that polling it cannot swallow the events the handler is consuming.
local function handler(message)
    local text = tostring(message) .. "\n\nPress " .. string.upper(RECOVERY_KEY)
        .. " to disable every mod except the mod loader, then restart."
    local draw = ref_errorhandler and ref_errorhandler(text)
    if not draw then
        return
    end
    return function()
        if love.keyboard.isDown(RECOVERY_KEY) then
            pcall(SafeMode.enter)
            pcall(function() require("lovely").reload_patches() end)
            return "restart"
        end
        return draw()
    end
end

love.errorhandler = handler
love.errhand = handler
