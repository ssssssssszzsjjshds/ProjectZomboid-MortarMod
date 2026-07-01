--***********************************************************************--
-- Mortar System  -  MortarFire.lua   (SERVER / authority)
--
-- PURPOSE
--   The authoritative firing pipeline. Given a fire request (a pure-data fire
--   solution) from a player, it performs the full design 4.5 -> 6 sequence:
--
--     validate -> misfire check -> scatter -> resolve impact ->
--     force-load chunk -> dispatch shell effect -> consume shell ->
--     wear condition -> award XP -> small tube noise -> notify client
--
--   This is the function the server command handler calls (and, in SP, the
--   network layer calls inline). Clients NEVER run this -- they only request it.
--
-- INPUT (payload; pure data so it survives the wire)
--   A fire solution from MortarTargeting plus nothing else; the mortar is
--   located from payload.originX/Y/Z on the authority so clients can't spoof a
--   mortar reference.
--
-- DATA FLOW
--   Depends on virtually every gameplay module. Returns a result table and also
--   pushes a "fireResult" message back to the firing client for UI/debug.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarUtils"
require "Mortar/MortarMath"
require "Mortar/MortarShells"
require "Mortar/MortarScatter"
require "Mortar/MortarTargeting"
require "Mortar/MortarInventory"
require "Mortar/MortarObject"
require "Mortar/MortarXP"
require "Mortar/MortarNetwork"
require "Mortar/MortarChunk"
require "Mortar/MortarExplosion"
require "Mortar/MortarPending"

MortarMod = MortarMod or {}
MortarMod.Fire = MortarMod.Fire or {}

local Fire = MortarMod.Fire
local Config = MortarMod.Config
local Log = MortarMod.Log
local Utils = MortarMod.Utils
local Mth = MortarMod.Math
local Shells = MortarMod.Shells
local Scatter = MortarMod.Scatter
local Targeting = MortarMod.Targeting
local Inv = MortarMod.Inventory
local MObj = MortarMod.Object
local XP = MortarMod.XP
local Net = MortarMod.Network
local Chunk = MortarMod.Chunk
local Explosion = MortarMod.Explosion
local Pending = MortarMod.Pending

--=======================================================================--
-- HELPERS
--=======================================================================--

-- Roll a condition-based misfire. Returns true if the round fails to launch.
local function rollMisfire(conditionValue)
    local below = Config.CONDITION.misfireBelow
    if not below or below <= 0 then return false end
    if conditionValue >= below then return false end
    -- Linear from 0 chance at `below` to misfireMaxChance at 0 condition.
    local t = 1 - (conditionValue / below)
    local chance = Config.CONDITION.misfireMaxChance * t
    local roll = (ZombRandFloat and ZombRandFloat(0, 1)) or math.random()
    return roll < chance
end

-- Notify the firing client of the outcome (UI feedback + debug overlay data).
local function notifyClient(player, result)
    Net.toClient(player, "fireResult", result)
end

-- Dispatch a shell's effect handler at a tile. Shared by the immediate path and
-- the deferred (MortarPending) path. Resolves the impact square (may be nil) and
-- returns the handler's result table (with .needsSquare when terrain is absent).
function Fire.detonateAt(shellKey, x, y, z, intendedX, intendedY, player)
    local shell = Shells.get(shellKey)
    if not shell then return { detonated = false } end
    local handler = Shells.getEffect(shell.effectType)
    if not handler then
        Log.error("No effect handler for '%s'.", tostring(shell.effectType))
        return { detonated = false }
    end
    local square = Utils.getSquare(x, y, z)
    local _, res = Log.guard("effect:" .. tostring(shell.effectType), handler, {
        shell = shell,
        x = x, y = y, z = z,
        square = square,
        player = player,
        intended = { x = intendedX, y = intendedY },
    })
    return res or { detonated = false }
end

--=======================================================================--
-- MAIN ENTRY
--=======================================================================--

-- Execute a fire request. `player` is the firing IsoPlayer (authority-resolved),
-- `payload` is a fire solution table. Returns a result table.
function Fire.execute(player, payload)
    if not player then
        Log.error("Fire.execute: nil player.")
        return { ok = false, reason = "no-player" }
    end
    if type(payload) ~= "table" then
        Log.error("Fire.execute: bad payload.")
        return { ok = false, reason = "bad-payload" }
    end

    -- 1. Locate the deployed mortar at the claimed origin (anti-spoof + state).
    local mortar = MObj.findAt(payload.originX, payload.originY, payload.originZ)
    if not mortar then
        Log.warn("Fire.execute: no mortar at (%s,%s,%s).",
            tostring(payload.originX), tostring(payload.originY), tostring(payload.originZ))
        notifyClient(player, { ok = false, reason = "IGUI_Mortar_Err_NoSolution" })
        return { ok = false, reason = "no-mortar" }
    end

    -- 2. Serviceability.
    if not mortar:isServiceable() then
        notifyClient(player, { ok = false, reason = "IGUI_Mortar_Err_Unserviceable" })
        return { ok = false, reason = "unserviceable" }
    end

    -- 3. Resolve shell + availability.
    local shell = Shells.get(payload.shellKey)
    if not shell then
        notifyClient(player, { ok = false, reason = "IGUI_Mortar_Err_NoShell" })
        return { ok = false, reason = "bad-shell" }
    end
    if Inv.count(player, shell.itemType) <= 0 then
        notifyClient(player, { ok = false, reason = "IGUI_Mortar_Err_NoShell" })
        return { ok = false, reason = "no-shell" }
    end

    -- 4. Validate the solution (range bounds, charge).
    local okSol, reason = Targeting.validate(payload)
    if not okSol then
        notifyClient(player, { ok = false, reason = reason })
        return { ok = false, reason = reason }
    end

    -- 5. Misfire? (Consumes the shell + wears the tube, but no detonation.)
    if rollMisfire(mortar:getCondition()) then
        Inv.consumeOne(player, shell.itemType)
        mortar:addCondition(-Config.CONDITION.wearPerFire)
        Log.info("Misfire (condition %.0f).", mortar:getCondition())
        notifyClient(player, { ok = true, misfire = true,
            reason = "IGUI_Mortar_Misfire", shellKey = shell.key })
        return { ok = true, misfire = true }
    end

    -- 6. Scatter radius from the full modifier stack.
    local toolTier = Inv.getToolTier(player)
    local radius, breakdown = Scatter.computeRadius({
        player = player,
        chargeId = payload.chargeId,
        toolTier = toolTier,
        conditionFraction = mortar:getConditionFraction(),
        spotterPlotTier = payload.spotterPlotTier,
    })

    -- 7. Resolve the impact tile from the intended target + scatter.
    local impactX, impactY, dX, dY =
        Scatter.resolveImpact(payload.targetX, payload.targetY, radius)
    local impactZ = payload.targetZ or payload.originZ

    Log.info("FIRE: %s | radius=%.2f offset=(%d,%d) -> impact (%d,%d,%d)",
        Targeting.describe(payload), radius, dX, dY, impactX, impactY, impactZ)
    if Config.DEBUG then
        Log.debug("scatter breakdown: base=%.1f tool=%.2f skill=%.2f cond=%.2f moodle=%.2f weather=%.2f spot=%.2f global=%.2f",
            breakdown.base, breakdown.toolMult, breakdown.skillMult, breakdown.conditionMult,
            breakdown.moodleMult, breakdown.weatherMult, breakdown.spotterMult, breakdown.globalScalar)
    end

    -- 8. Tube "thunk": a small local noise at the firing position.
    if Explosion and Explosion.worldSound then
        Explosion.worldSound(payload.originX, payload.originY, payload.originZ,
            Config.NOISE.fireRadius, Config.NOISE.fireVolume)
        -- 9. The signature impact noise -- the weapon's huge zombie pull. Emitted
        -- at the impact coords immediately, even if that terrain isn't streamed
        -- (world-sound is coordinate-based and needs no loaded chunk).
        Explosion.worldSound(impactX, impactY, impactZ,
            Config.NOISE.radius, Config.NOISE.volume)
    end

    -- 10. Detonate. HE needs streamed terrain, so it detonates now only if the
    -- impact chunk is loaded, else the blast is DEFERRED until it streams in
    -- (B42 has no off-screen force-load). Smoke/illum self-realise via the
    -- persistence layer, so they always dispatch immediately.
    local function deferBlast()
        Pending.add({ x = impactX, y = impactY, z = impactZ, shellKey = shell.key,
            intendedX = payload.targetX, intendedY = payload.targetY })
    end

    if shell.deferUntilLoaded and not Chunk.isLoaded(impactX, impactY, impactZ) then
        deferBlast()
    else
        local res = Fire.detonateAt(shell.key, impactX, impactY, impactZ,
            payload.targetX, payload.targetY, player)
        if res and res.needsSquare then deferBlast() end
    end

    -- 11. Consume the shell.
    Inv.consumeOne(player, shell.itemType)

    -- 12. Wear the tube.
    mortar:addCondition(-Config.CONDITION.wearPerFire)

    -- 13. XP (fire + accuracy bonus).
    XP.awardFire(player, impactX, impactY, payload.targetX, payload.targetY)

    -- 14. Keep the world object's facing in sync with the last bearing fired,
    -- then push the mutated object modData to MP clients (not auto-synced).
    if payload.bearing then mortar:setBearing(payload.bearing) end
    mortar:syncModData()

    -- 15. Tell the client (UI feedback + debug markers).
    local result = {
        ok = true,
        misfire = false,
        shellKey = shell.key,
        intendedX = payload.targetX, intendedY = payload.targetY,
        impactX = impactX, impactY = impactY, impactZ = impactZ,
        scatterRadius = radius,
        conditionLeft = mortar:getCondition(),
    }
    notifyClient(player, result)
    return result
end

return Fire
