--***********************************************************************--
-- Mortar System  -  MortarXP.lua
--
-- PURPOSE
--   Award skill XP for mortar actions per design 7.2. Centralised so the XP
--   values stay in Config and the award call is uniform.
--
-- AWARDS
--   * Successful fire (any shell)          -> Config.XP.fireXP  (Aiming)
--   * Impact within accuracyTiles of target-> + accuracyBonusXP (Aiming)
--   * Setup or breakdown                   -> setupBreakdownXP   (Nimble)
--
-- MP NOTE
--   XP is granted on the firing player's object on the AUTHORITY side (server
--   in MP, local in SP). getXp():AddXP propagates to the owning client.
--
-- DATA FLOW
--   Depends on Config, Log, Math. Called by the firing pipeline and by the
--   setup/breakdown timed actions.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarMath"

MortarMod = MortarMod or {}
MortarMod.XP = MortarMod.XP or {}

local XP = MortarMod.XP
local Config = MortarMod.Config
local Log = MortarMod.Log
local Mth = MortarMod.Math

-- Defensive XP grant. Resolves the Perks enum member by name so a renamed perk
-- never crashes the firing pipeline.
local function addXP(player, perkName, amount)
    if not player or not player.getXp or amount == 0 then return end
    if not Perks or Perks[perkName] == nil then
        Log.warn("addXP: unknown perk '%s'.", tostring(perkName))
        return
    end
    local perk = Perks[perkName]
    local ok = pcall(function() player:getXp():AddXP(perk, amount) end)
    if ok then
        Log.debug("Awarded %d %s XP.", amount, perkName)
    else
        Log.warn("addXP: AddXP failed for %s.", perkName)
    end
end

-- Award XP for a successful fire. `impact` and `intended` are {x,y} tables.
function XP.awardFire(player, impactX, impactY, intendedX, intendedY)
    if Config.XP.gainXP == false then return end
    addXP(player, Config.XP.firePerk, Config.XP.fireXP)

    -- Accuracy bonus when the round lands within accuracyTiles of intent.
    local dist = Mth.distance(impactX, impactY, intendedX, intendedY)
    if dist <= Config.XP.accuracyTiles then
        addXP(player, Config.XP.firePerk, Config.XP.accuracyBonusXP)
        Log.debug("Accuracy bonus (impact %.1f tiles from target).", dist)
    end
end

-- Award XP for a completed setup or breakdown (Nimble).
function XP.awardSetupBreakdown(player)
    if Config.XP.gainXP == false then return end
    addXP(player, Config.XP.nimblePerk, Config.XP.setupBreakdownXP)
end

return XP
