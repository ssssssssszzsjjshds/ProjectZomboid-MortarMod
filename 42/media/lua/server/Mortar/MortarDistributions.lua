--***********************************************************************--
-- Mortar System  -  MortarDistributions.lua   (SERVER)
--
-- PURPOSE
--   Inject mortar items into the world's loot tables per design 2.4, without
--   touching vanilla files. Implemented data-driven + defensive: we declare
--   "logical buckets" of items and a list of CANDIDATE procedural-distribution
--   names for each, then insert into whichever candidates actually exist in
--   this build. Renamed/absent lists are skipped (and logged), so the mod never
--   errors on a list that B42.19 happens to call something else.
--
-- TUNING
--   * Edit BUCKETS below to change rarity (weights) or where items spawn.
--   * Run with DebugMode on to see exactly which lists matched in the log; use
--     the in-game "item zone" debug tools to discover the real list names for a
--     given container and add them here.
--
-- DATA FLOW
--   Hooks Events.OnPreDistributionMerge (fires before the loot tables merge,
--   the supported modder injection point). Depends on Config + Log.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"

MortarMod = MortarMod or {}
MortarMod.Distributions = MortarMod.Distributions or {}

local Dist = MortarMod.Distributions
local Config = MortarMod.Config
local Log = MortarMod.Log
local I = Config.ITEMS

--=======================================================================--
-- INJECTION SPEC
--   weight = relative spawn weight in that list (higher = more common). These
--   are intentionally low for the military hardware (design: "Rare").
--=======================================================================--

-- All candidate list names below are REAL B42.19 procedural distributions
-- (verified against vanilla 42.19 source). The existence check in inject() still
-- guards each one, so any list a future patch renames is skipped, not fatal.
Dist.BUCKETS = {
    -----------------------------------------------------------------------
    -- Military storage: the heavy hardware + plotting kit, rare.
    -- (Mortar + board + circle + tables live with armoury equipment.)
    -----------------------------------------------------------------------
    {
        name = "MilitaryHardware",
        candidates = {
            "ArmyStorageGuns", "ArmyStorageOutfit",
            "ArmyStorageElectronics", "ArmyStorageMedical",
        },
        items = {
            { I.MORTAR,         0.6 },
            { I.PLOTTING_BOARD, 1.0 },
            { I.AIMING_CIRCLE,  1.0 },
            { I.FIRING_TABLES,  1.5 },
        },
    },

    -----------------------------------------------------------------------
    -- Military ammunition: all shells (loose HE more common), uncommon.
    -----------------------------------------------------------------------
    {
        name = "MilitaryAmmo",
        candidates = {
            "ArmyStorageAmmunition", "ArmySurplusAmmoBoxes",
        },
        items = {
            { I.SHELL_HE,    4.0 },
            { I.SHELL_SMOKE, 2.0 },
            { I.SHELL_ILLUM, 2.0 },
        },
    },

    -----------------------------------------------------------------------
    -- Army surplus store: civilian navigation aids only, common.
    -----------------------------------------------------------------------
    {
        name = "ArmySurplusCivilian",
        candidates = {
            "ArmySurplusTools", "ArmySurplusOutfit",
            "ArmySurplusBackpacks", "ArmySurplusFootwear",
        },
        items = {
            { I.COMPASS,   8.0 },
            { I.MAP_RULER, 8.0 },
        },
    },
}

--=======================================================================--
-- INJECTION
--=======================================================================--

-- Insert one item/weight pair into a procedural list's `items` array (the
-- alternating {name, weight, name, weight, ...} format PZ uses).
local function addToList(list, itemName, weight)
    if not list or type(list.items) ~= "table" then return false end
    -- Avoid duplicate insertion on hot-reload.
    for i = 1, #list.items, 2 do
        if list.items[i] == itemName then return false end
    end
    table.insert(list.items, itemName)
    table.insert(list.items, weight)
    return true
end

function Dist.inject()
    if not ProceduralDistributions or type(ProceduralDistributions.list) ~= "table" then
        Log.warn("ProceduralDistributions.list unavailable; skipping loot injection.")
        return
    end
    local PL = ProceduralDistributions.list

    local totalMatched, totalInsertions = 0, 0
    for _, bucket in ipairs(Dist.BUCKETS) do
        local matchedHere = 0
        for _, listName in ipairs(bucket.candidates) do
            local list = PL[listName]
            if list then
                matchedHere = matchedHere + 1
                for _, pair in ipairs(bucket.items) do
                    if addToList(list, pair[1], pair[2]) then
                        totalInsertions = totalInsertions + 1
                    end
                end
                Log.debug("Injected '%s' bucket into list '%s'.", bucket.name, listName)
            end
        end
        if matchedHere == 0 then
            Log.warn("Loot bucket '%s' matched NO candidate lists -- adjust candidates for this build.",
                bucket.name)
        else
            totalMatched = totalMatched + matchedHere
        end
    end
    Log.info("Loot injection complete: %d list(s) matched, %d insertion(s).",
        totalMatched, totalInsertions)
end

-- Wire the supported injection event (guard against double-add on reload).
if not Dist._wired then
    Dist._wired = true
    if Events and Events.OnPreDistributionMerge then
        Events.OnPreDistributionMerge.Add(function() Dist.inject() end)
    else
        Log.warn("OnPreDistributionMerge event missing; loot will not be injected.")
    end
end

return Dist
