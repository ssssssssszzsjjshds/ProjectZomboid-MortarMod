--***********************************************************************--
-- Mortar System  -  MortarSmoke.lua   (SERVER / authority)
--
-- PURPOSE
--   Smoke shell behaviour (design 6.2/6.3): spawn a vision-obscuring smoke
--   cloud at impact that lingers for Config.SMOKE.durationMinutes, with NO
--   blast, fire, damage, or zombie noise.
--
-- IMPLEMENTATION
--   * Registers the "SMOKE" effect handler (dispatched by shell.effectType).
--   * Registers a "smoke" persistence kind so the cloud survives save/load and
--     auto-expires (MortarPersistence drives the lifecycle).
--   * Visual: tries a native smoke spawner if one exists; otherwise places
--     translucent placeholder smoke IsoObjects. True engine vision-occlusion is
--     not Lua-exposed, so the closest practical effect (visual cloud + lifetime)
--     is implemented and documented.
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
MortarMod.Smoke = MortarMod.Smoke or {}

local Smoke = MortarMod.Smoke
local Config = MortarMod.Config
local Log = MortarMod.Log
local Utils = MortarMod.Utils
local Shells = MortarMod.Shells
local Persistence = MortarMod.Persistence

--=======================================================================--
-- VISUAL SPAWN / REMOVE
--=======================================================================--

-- Try a native smoke spawner; return true if it handled the square.
local function nativeSmoke(square)
    if not square then return false end
    if IsoFireManager and type(IsoFireManager.StartSmoke) == "function" then
        local ok = pcall(function()
            IsoFireManager.StartSmoke(Utils.getCell(), square, false, 100, 3600)
        end)
        if ok then return true end
    end
    return false
end

-- Place a placeholder smoke IsoObject on a square. Returns the object or nil.
local function placeSmokeObject(square)
    if not square then return nil end
    local obj
    local ok = pcall(function()
        if ZombRandFloat then
            obj = IsoObject.new(square, Config.SMOKE.placeholderSprite, "", false)
        else
            obj = IsoObject.new(Utils.getCell(), square, Config.SMOKE.placeholderSprite)
        end
    end)
    if not ok or not obj then return nil end
    -- Tag so it can never be confused with a mortar.
    pcall(function() obj:getModData().MortarSmokePuff = true end)
    local added = pcall(function() square:AddTileObject(obj) end)
    if not added then pcall(function() square:AddSpecialObject(obj) end) end
    pcall(function() obj:transmitCompleteItemToClients() end)
    return obj
end

local function removeObject(obj)
    if not obj then return end
    local sq = obj.getSquare and obj:getSquare()
    if sq then
        local ok = pcall(function() sq:transmitRemoveItemFromSquare(obj) end)
        if not ok then pcall(function() sq:RemoveTileObject(obj) end) end
    end
end

--=======================================================================--
-- PERSISTENCE KIND: "smoke"
--=======================================================================--

-- Squares within the cloud radius.
local function cloudSquares(effect)
    local list = {}
    local r = effect.radius or Config.SMOKE.radius
    for dx = -r, r do
        for dy = -r, r do
            if (dx * dx + dy * dy) <= r * r then
                local sq = Utils.getSquare(effect.x + dx, effect.y + dy, effect.z)
                if sq then list[#list + 1] = sq end
            end
        end
    end
    return list
end

local function rehydrateSmoke(effect)
    local squares = cloudSquares(effect)
    if #squares == 0 then return nil end   -- chunk not loaded yet; try later
    local objects = {}
    for _, sq in ipairs(squares) do
        if not nativeSmoke(sq) then
            local obj = placeSmokeObject(sq)
            if obj then objects[#objects + 1] = obj end
        end
    end
    Log.debug("Smoke cloud rehydrated: %d puff object(s).", #objects)
    return { objects = objects }
end

local function cleanupSmoke(effect, handle)
    if not handle then return end
    for _, obj in ipairs(handle.objects or {}) do
        removeObject(obj)
    end
end

if Persistence then
    Persistence.registerKind("smoke", {
        rehydrate = rehydrateSmoke,
        cleanup   = cleanupSmoke,
    })
end

--=======================================================================--
-- EFFECT HANDLER: "SMOKE"
--=======================================================================--

function Smoke.detonate(ctx)
    if not Persistence then
        Log.warn("Smoke: persistence unavailable; cloud will not be tracked.")
        return { detonated = false, note = "no-persistence" }
    end
    local now = Utils.gameMinutes()
    Persistence.addEffect({
        kind = "smoke",
        x = ctx.x, y = ctx.y, z = ctx.z,
        radius = Config.SMOKE.radius,
        expiryMinutes = now + Config.SMOKE.durationMinutes,
    })
    Log.info("Smoke shell at (%d,%d,%d) for %d min.",
        ctx.x, ctx.y, ctx.z, Config.SMOKE.durationMinutes)
    return { detonated = true, note = "smoke" }
end

Shells.registerEffect("SMOKE", Smoke.detonate)

return Smoke
