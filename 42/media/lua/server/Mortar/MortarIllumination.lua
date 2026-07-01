--***********************************************************************--
-- Mortar System  -  MortarIllumination.lua   (SERVER / authority)
--
-- PURPOSE
--   Illumination shell behaviour (design 6.2 / open question 9.6). The design
--   listed this as a "framework / placeholder"; we implement it for real using
--   PZ dynamic light sources -- a bright flare at impact that burns for
--   Config.ILLUM.durationMinutes and optionally drifts like a descending
--   parachute flare, with NO blast/fire/damage/noise.
--
-- IMPLEMENTATION
--   * Registers the "ILLUM" effect handler.
--   * Registers an "illum" persistence kind: a live IsoLightSource added to the
--     cell's lamppost list, removed on expiry, recreated on save/load.
--   * onMinute drift nudges the light to simulate the flare falling/sliding.
--
-- DATA FLOW
--   Depends on Config, Log, Utils, Shells, Persistence. ctx as in MortarShells.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarUtils"
require "Mortar/MortarShells"
require "Mortar/MortarPersistence"

MortarMod = MortarMod or {}
MortarMod.Illum = MortarMod.Illum or {}

local Illum = MortarMod.Illum
local Config = MortarMod.Config
local Log = MortarMod.Log
local Utils = MortarMod.Utils
local Shells = MortarMod.Shells
local Persistence = MortarMod.Persistence

--=======================================================================--
-- LIGHT SOURCE HELPERS
--=======================================================================--

-- Create + register a dynamic light. Returns the IsoLightSource or nil.
local function addLight(x, y, z, radius)
    if not IsoLightSource or type(IsoLightSource.new) ~= "function" then
        Log.warn("Illum: IsoLightSource unavailable.")
        return nil
    end
    local C = Config.ILLUM
    local light
    local ok = pcall(function()
        light = IsoLightSource.new(x, y, z, C.r, C.g, C.b, radius)
    end)
    if not ok or not light then return nil end
    -- Apply intensity if the build supports it.
    pcall(function() if light.setIntensity then light:setIntensity(C.intensity) end end)

    local cell = Utils.getCell()
    local added = false
    if cell and type(cell.addLamppost) == "function" then
        added = pcall(function() cell:addLamppost(light) end)
    end
    if not added then
        Log.warn("Illum: could not register light at (%d,%d,%d).", x, y, z)
        return nil
    end
    return light
end

local function removeLight(light)
    if not light then return end
    local cell = Utils.getCell()
    if cell and type(cell.removeLamppost) == "function" then
        pcall(function() cell:removeLamppost(light) end)
    end
end

--=======================================================================--
-- PERSISTENCE KIND: "illum"
--=======================================================================--

local function rehydrateIllum(effect)
    local light = addLight(effect.curX or effect.x, effect.curY or effect.y, effect.z,
        effect.radius or Config.ILLUM.radius)
    if not light then return nil end
    Log.debug("Illum flare lit at (%d,%d,%d).", effect.x, effect.y, effect.z)
    return { light = light }
end

local function cleanupIllum(effect, handle)
    if handle then removeLight(handle.light) end
end

-- Drift the flare a little each minute (wind-driven slide of a parachute flare).
local function onMinuteIllum(effect, handle, now)
    local drift = Config.ILLUM.driftTilesPerMinute or 0
    if drift <= 0 or not handle then return end
    effect.curX = (effect.curX or effect.x) + drift
    effect.curY = (effect.curY or effect.y)
    -- Re-seat the light at the new position (remove + re-add).
    removeLight(handle.light)
    handle.light = addLight(math.floor(effect.curX), math.floor(effect.curY),
        effect.z, effect.radius or Config.ILLUM.radius)
end

if Persistence then
    Persistence.registerKind("illum", {
        rehydrate = rehydrateIllum,
        cleanup   = cleanupIllum,
        onMinute  = onMinuteIllum,
    })
end

--=======================================================================--
-- EFFECT HANDLER: "ILLUM"
--=======================================================================--

function Illum.detonate(ctx)
    if not Persistence then
        Log.warn("Illum: persistence unavailable; flare will not be tracked.")
        return { detonated = false, note = "no-persistence" }
    end
    local now = Utils.gameMinutes()
    Persistence.addEffect({
        kind = "illum",
        x = ctx.x, y = ctx.y, z = ctx.z,
        curX = ctx.x, curY = ctx.y,
        radius = Config.ILLUM.radius,
        expiryMinutes = now + Config.ILLUM.durationMinutes,
    })
    Log.info("Illum shell at (%d,%d,%d) for %d min.",
        ctx.x, ctx.y, ctx.z, Config.ILLUM.durationMinutes)
    return { detonated = true, note = "illum" }
end

Shells.registerEffect("ILLUM", Illum.detonate)

return Illum
