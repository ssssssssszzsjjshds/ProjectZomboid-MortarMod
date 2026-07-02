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

-- All candidate list names below are confirmed B42.19 procedural
-- distributions (per PZwiki / vanilla source). The existence check in
-- inject() still guards each one, so any list a future patch renames is
-- skipped, not fatal. Each bucket's weights are scaled by the matching
-- Config.LOOT sandbox multiplier (lootMult key); a multiplier of 0 disables
-- the whole bucket.
Dist.BUCKETS = {
    -----------------------------------------------------------------------
    -- The weapon itself: army weapon storage only, very rare.
    -----------------------------------------------------------------------
    {
        name = "MortarHardware",
        lootMult = "hardwareMult",
        candidates = { "ArmyStorageGuns" },
        items = {
            -- Vanilla entries in these lists run weight ~10-100, so anything
            -- below ~5 is practically unfindable. 8 = "rare": you'll see one
            -- in a well-looted base, not in every locker.
            { I.MORTAR, 8.0 },
        },
    },

    -----------------------------------------------------------------------
    -- Military plotting kit: armoury + electronics storage; the firing
    -- tables booklet also shows up as surplus-store literature.
    -----------------------------------------------------------------------
    {
        name = "PlottingKit",
        lootMult = "hardwareMult",
        candidates = { "ArmyStorageGuns", "ArmyStorageElectronics" },
        items = {
            { I.PLOTTING_BOARD, 10.0 },
            { I.AIMING_CIRCLE,  10.0 },
            { I.FIRING_TABLES,  12.0 },
        },
    },
    {
        name = "SurplusLiterature",
        lootMult = "hardwareMult",
        candidates = { "ArmySurplusLiterature" },
        items = {
            { I.FIRING_TABLES, 15.0 },
        },
    },

    -----------------------------------------------------------------------
    -- Military ammunition: all shells (loose HE more common), uncommon.
    -----------------------------------------------------------------------
    {
        name = "MilitaryAmmo",
        lootMult = "ammoMult",
        candidates = { "ArmyStorageAmmunition" },
        items = {
            { I.SHELL_HE,    40.0 },
            { I.SHELL_SMOKE, 24.0 },
            { I.SHELL_ILLUM, 24.0 },
        },
    },

    -----------------------------------------------------------------------
    -- Army surplus ammo boxes: demilled stock, very rare.
    -----------------------------------------------------------------------
    {
        name = "SurplusAmmo",
        lootMult = "ammoMult",
        candidates = { "ArmySurplusAmmoBoxes" },
        items = {
            { I.SHELL_HE,    8.0 },
            { I.SHELL_SMOKE, 5.0 },
            { I.SHELL_ILLUM, 5.0 },
        },
    },

    -----------------------------------------------------------------------
    -- Army surplus store: civilian navigation aids, common.
    -----------------------------------------------------------------------
    {
        name = "SurplusNavigation",
        lootMult = "toolsMult",
        candidates = { "ArmySurplusTools", "ArmySurplusMisc" },
        items = {
            { I.COMPASS,   20.0 },
            { I.MAP_RULER, 20.0 },
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

    -- Sandbox overrides load before OnPreDistributionMerge fires, so the
    -- Config.LOOT multipliers are final here.
    Config.refreshFromSandbox()

    local totalMatched, totalInsertions = 0, 0
    for _, bucket in ipairs(Dist.BUCKETS) do
        local mult = 1.0
        if bucket.lootMult and Config.LOOT then
            mult = Config.LOOT[bucket.lootMult] or 1.0
        end
        local matchedHere = 0
        for _, listName in ipairs(bucket.candidates) do
            local list = PL[listName]
            if list and mult > 0 then
                matchedHere = matchedHere + 1
                for _, pair in ipairs(bucket.items) do
                    if addToList(list, pair[1], pair[2] * mult) then
                        totalInsertions = totalInsertions + 1
                    end
                end
                Log.debug("Injected '%s' bucket into list '%s' (x%.2f).",
                    bucket.name, listName, mult)
            elseif list then
                matchedHere = matchedHere + 1  -- matched but disabled by sandbox
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
