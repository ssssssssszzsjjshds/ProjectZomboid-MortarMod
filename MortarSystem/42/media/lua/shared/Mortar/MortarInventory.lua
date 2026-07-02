--***********************************************************************--
-- Mortar System  -  MortarInventory.lua
--
-- PURPOSE
--   All player-inventory interaction: counting/consuming shells, locating the
--   carried mortar item, and resolving which plotting-tool tier the player has
--   (which drives the scatter multiplier and the UI fidelity).
--
-- RESPONSIBILITIES
--   * Robust count / find / consume helpers (recurse into bags; fail soft).
--   * Tool-tier resolution per design 4.6 / 5.3.
--   * Shell inventory snapshot for the firing UI.
--
-- DATA FLOW
--   Depends on Config + Log + Shells. Called by the UI (counts, tier), by the
--   firing pipeline (consume), and by the context menu (carried mortar check).
--   Engine container methods are probed defensively (names vary across builds).
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarShells"

MortarMod = MortarMod or {}
MortarMod.Inventory = MortarMod.Inventory or {}

local Inv = MortarMod.Inventory
local Config = MortarMod.Config
local Log = MortarMod.Log
local Shells = MortarMod.Shells

--=======================================================================--
-- LOW-LEVEL CONTAINER HELPERS (defensive)
--=======================================================================--

local function container(player)
    if not player or not player.getInventory then return nil end
    return player:getInventory()
end

-- Count items of a full type, recursing into sub-containers when possible.
function Inv.count(player, fullType)
    local inv = container(player)
    if not inv then return 0 end
    -- Prefer recursive count so shells inside bags are included.
    if inv.getCountTypeRecurse then
        local ok, n = pcall(function() return inv:getCountTypeRecurse(fullType) end)
        if ok and type(n) == "number" then return n end
    end
    if inv.getItemCount then
        local ok, n = pcall(function() return inv:getItemCount(fullType) end)
        if ok and type(n) == "number" then return n end
    end
    return 0
end

-- True if the player holds at least one of fullType.
function Inv.has(player, fullType)
    return Inv.count(player, fullType) > 0
end

-- Find the first item instance of fullType (recursing), or nil.
function Inv.find(player, fullType)
    local inv = container(player)
    if not inv then return nil end
    if inv.getFirstTypeRecurse then
        local ok, item = pcall(function() return inv:getFirstTypeRecurse(fullType) end)
        if ok and item then return item end
    end
    if inv.getItemFromTypeRecurse then
        local ok, item = pcall(function() return inv:getItemFromTypeRecurse(fullType) end)
        if ok and item then return item end
    end
    if inv.getItemFromType then
        local ok, item = pcall(function() return inv:getItemFromType(fullType) end)
        if ok and item then return item end
    end
    return nil
end

-- Remove exactly one item of fullType from wherever it lives. Returns true on
-- success. Performs the MP-safe transmit so server-side consumption syncs to
-- the owning client.
function Inv.consumeOne(player, fullType)
    local item = Inv.find(player, fullType)
    if not item then
        Log.warn("consumeOne: no '%s' to remove.", tostring(fullType))
        return false
    end
    local cont = item.getContainer and item:getContainer()
    cont = cont or container(player)
    if not cont then return false end

    local ok = pcall(function() cont:Remove(item) end)
    if not ok then
        -- Some builds expose DoRemoveItem instead.
        ok = pcall(function() cont:DoRemoveItem(item) end)
    end
    if ok then
        pcall(function() cont:setDrawDirty(true) end)
        -- Refresh the player's UI inventory if this is the local player.
        pcall(function()
            if player.getInventory then player:getInventory():setDrawDirty(true) end
        end)
        Log.debug("Consumed one '%s'.", tostring(fullType))
        return true
    end
    Log.error("consumeOne: failed to remove '%s'.", tostring(fullType))
    return false
end

--=======================================================================--
-- CARRIED MORTAR ITEM
--=======================================================================--

function Inv.hasMortarItem(player)
    return Inv.has(player, Config.ITEMS.MORTAR)
end

function Inv.findMortarItem(player)
    return Inv.find(player, Config.ITEMS.MORTAR)
end

-- The carried mortar item tracks condition in its modData so durability follows
-- the weapon across deploy/breakdown cycles (design override "Condition").
local ITEM_CONDITION_KEY = "mortarCondition"

function Inv.getItemCondition(item)
    if not item or not item.getModData then return Config.CONDITION.max end
    local v = item:getModData()[ITEM_CONDITION_KEY]
    if type(v) == "number" then return v end
    return Config.CONDITION.max
end

function Inv.setItemCondition(item, value)
    if not item or not item.getModData then return end
    item:getModData()[ITEM_CONDITION_KEY] = value
end

--=======================================================================--
-- SHELLS
--=======================================================================--

-- Count of a specific shell definition in inventory.
function Inv.countShell(player, shellDef)
    if not shellDef then return 0 end
    return Inv.count(player, shellDef.itemType)
end

-- Snapshot of all shell counts, for the UI. Returns:
--   { byKey = { HE = n, SMOKE = n, ILLUM = n }, total = N, list = { {def, count}... } }
-- `list` preserves shell registration order and includes zero-count entries so
-- the UI can show greyed-out types.
function Inv.shellSnapshot(player)
    local snap = { byKey = {}, total = 0, list = {} }
    for _, def in ipairs(Shells.all()) do
        local c = Inv.countShell(player, def)
        snap.byKey[def.key] = c
        snap.total = snap.total + c
        snap.list[#snap.list + 1] = { def = def, count = c }
    end
    return snap
end

--=======================================================================--
-- PLOTTING TOOL TIER (design 4.6 / 5.3)
--=======================================================================--

-- Resolve the best available tool tier. Returns one of:
--   "FULL_KIT" | "BOARD_TABLES" | "COMPASS" | "RULER" | "NONE"
-- Hierarchy: a proper military solution (board+tables, optionally +circle)
-- always beats the civilian aids; without tables the board cannot give an
-- elevation solution, so it falls back to whatever civilian aid exists.
function Inv.getToolTier(player)
    local hasBoard   = Inv.has(player, Config.ITEMS.PLOTTING_BOARD)
    local hasCircle  = Inv.has(player, Config.ITEMS.AIMING_CIRCLE)
    local hasTables  = Inv.has(player, Config.ITEMS.FIRING_TABLES)
    local hasCompass = Inv.has(player, Config.ITEMS.COMPASS)
    local hasRuler   = Inv.has(player, Config.ITEMS.MAP_RULER)

    if hasBoard and hasTables and hasCircle then return "FULL_KIT" end
    if hasBoard and hasTables then return "BOARD_TABLES" end
    if hasCompass then return "COMPASS" end
    if hasRuler then return "RULER" end
    return "NONE"
end

-- Scatter multiplier for the resolved tier (NONE => nil, meaning cannot fire).
function Inv.getToolMultiplier(player)
    local tier = Inv.getToolTier(player)
    if tier == "NONE" then return nil, tier end
    return Config.SCATTER.tool[tier], tier
end

-- Whether the resolved tier permits showing a numeric range estimate in the UI
-- (only the full military kit gives reliable tables). Per design 4.6.
function Inv.tierShowsRange(tier)
    return tier == "FULL_KIT" or tier == "BOARD_TABLES"
end

-- Human warning string key for a tier (UI). Empty for the full kit.
function Inv.tierWarningKey(tier)
    if tier == "COMPASS" then return "IGUI_Mortar_Warn_Compass" end
    if tier == "RULER"   then return "IGUI_Mortar_Warn_Ruler" end
    if tier == "BOARD_TABLES" then return "IGUI_Mortar_Warn_NoCircle" end
    return nil
end

return Inv
