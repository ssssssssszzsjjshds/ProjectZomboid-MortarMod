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

-- Create + register a single dynamic light. Returns the IsoLightSource or nil.
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

-- The lighting engine visually caps a single source well below the flare's
-- 50-tile coverage, so wide illumination is assembled from concentric rings
-- of overlapping lamp-sized lights. Returns a list of IsoLightSources.
local function addLightGroup(cx, cy, z, coverRadius)
    local lamp = Config.ILLUM.lampRadius or 22
    local lights = {}
    local function put(x, y, r)
        local l = addLight(math.floor(x + 0.5), math.floor(y + 0.5), z, math.floor(r))
        if l then lights[#lights + 1] = l end
    end
    put(cx, cy, math.min(lamp, math.max(coverRadius, 4)))
    local step = lamp * 0.9
    local d = step
    while d < coverRadius do
        local n = math.max(4, math.ceil((2 * math.pi * d) / (lamp * 1.2)))
        for i = 0, n - 1 do
            local a = (i / n) * 2 * math.pi
            put(cx + math.cos(a) * d, cy + math.sin(a) * d, lamp)
        end
        d = d + step
    end
    return lights
end

local function removeLightGroup(lights)
    if not lights then return end
    for _, l in ipairs(lights) do removeLight(l) end
end

--=======================================================================--
-- PERSISTENCE KIND: "illum"
--=======================================================================--

-- Effective radius for this point in the burn: full brightness until
-- fadeStartFraction of the lifetime has elapsed, then a linear shrink down to
-- minFadeRadius at expiry (the flare visibly dies instead of cutting out).
local function fadedRadius(effect, now)
    local base = effect.radius or Config.ILLUM.radius
    local dur = effect.durationMinutes or Config.ILLUM.durationMinutes
    local start = effect.startMinutes or (effect.expiryMinutes and (effect.expiryMinutes - dur))
    if not start or dur <= 0 then return base end
    local e = (now - start) / dur                      -- 0..1 of the burn
    local fs = Config.ILLUM.fadeStartFraction or 0.6
    if e <= fs then return base end
    local t = math.min((e - fs) / math.max(1 - fs, 0.01), 1)
    local minR = Config.ILLUM.minFadeRadius or 6
    return math.max(minR, math.floor(base * (1 - t) + minR * t))
end

local function rehydrateIllum(effect)
    local now = Utils.gameMinutes()
    local lights = addLightGroup(effect.curX or effect.x, effect.curY or effect.y,
        effect.z, fadedRadius(effect, now))
    if #lights == 0 then return nil end
    Log.debug("Illum flare lit at (%d,%d,%d) with %d lamps.",
        effect.x, effect.y, effect.z, #lights)
    return { lights = lights }
end

local function cleanupIllum(effect, handle)
    if handle then removeLightGroup(handle.lights) end
end

-- Drift + fade each in-game minute: slide like a parachute flare and re-seat
-- the light with the current faded radius.
local function onMinuteIllum(effect, handle, now)
    if not handle then return end
    local drift = Config.ILLUM.driftTilesPerMinute or 0
    effect.curX = (effect.curX or effect.x) + drift
    effect.curY = (effect.curY or effect.y)
    -- Re-seat the lamp grid at the new position/size (remove + re-add).
    removeLightGroup(handle.lights)
    handle.lights = addLightGroup(effect.curX, effect.curY, effect.z,
        fadedRadius(effect, now))
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
        startMinutes = now,
        durationMinutes = Config.ILLUM.durationMinutes,
        expiryMinutes = now + Config.ILLUM.durationMinutes,
    })
    Log.info("Illum shell at (%d,%d,%d) for %d min.",
        ctx.x, ctx.y, ctx.z, Config.ILLUM.durationMinutes)
    return { detonated = true, note = "illum" }
end

Shells.registerEffect("ILLUM", Illum.detonate)

return Illum
