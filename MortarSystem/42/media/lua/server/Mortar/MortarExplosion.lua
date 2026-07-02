--***********************************************************************--
-- Mortar System  -  MortarExplosion.lua   (SERVER / authority)
--
-- PURPOSE
--   The HE detonation behaviour. 81mm HE mortar: large blast radius, no
--   persistent fire, distance-based damage falloff, scorched ground, lingering
--   smoke, and a massive zombie-attracting sound event.
--
-- DESIGN DECISIONS
--   * NEVER calls IsoFireManager.explode() — it always creates fire in B42.
--   * NEVER calls IsoFireManager.StartFire() — mortar HE does not start fires.
--   * Character damage falls off continuously from ground zero to blast edge.
--   * Structural destruction is top-down (Config.EXPLOSION.destroy): within
--     fullRadius the top `levelsFromTop` floor levels of any structure are
--     levelled outright; within damageRadius structures are battered.
--   * Charring: permanent floor-sprite scorch inside fullRadius; a REMOVABLE
--     burnt overlay object (sledgehammer) elsewhere, fading with distance.
--   * Lingering smoke appears on ~15-20% of affected tiles near center.
--   * World sound radius is huge (250 tiles) to draw zombies from afar.
--   * The shell definition's blastRadiusMin/Max are used (default 10 tiles).
--
-- DATA FLOW
--   Depends on Config, Log, Utils, Math, Shells. Registers effect "HE".
--   ctx = { shell, x, y, z, square, player, intended }.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarUtils"
require "Mortar/MortarMath"
require "Mortar/MortarShells"

MortarMod = MortarMod or {}
MortarMod.Explosion = MortarMod.Explosion or {}

local Explosion = MortarMod.Explosion
local Config = MortarMod.Config
local Log = MortarMod.Log
local Utils = MortarMod.Utils
local Mth = MortarMod.Math
local Shells = MortarMod.Shells

--=======================================================================--
-- WORLD SOUND (zombie attraction)
--=======================================================================--

function Explosion.worldSound(x, y, z, radius, volume)
    if type(addSound) == "function" then
        local ok = pcall(addSound, nil, x, y, z, radius, volume)
        if ok then return true end
    end
    if type(getWorldSoundManager) == "function" then
        local ok = pcall(function()
            getWorldSoundManager():addSound(nil, x, y, z, radius, volume)
        end)
        if ok then return true end
    end
    Log.warn("worldSound: no sound API available.")
    return false
end

--=======================================================================--
-- CHARGE / DAMAGE FALLOFF
--=======================================================================--

-- Continuous damage multiplier from distance. 1.0 at center, ~0 at edge.
local function falloff(dist, blastRadius)
    if blastRadius <= 0 then return 1.0 end
    local t = dist / blastRadius
    return math.max(0, 1 - t * t)
end

--=======================================================================--
-- CHARACTER DAMAGE
--=======================================================================--

local function killZombie(z, attacker)
    if pcall(function() z:Kill(attacker) end) then return end
    if pcall(function() z:Kill(attacker, true) end) then return end
    if pcall(function() z:setHealth(0) end) then return end
    pcall(function() z:changeState(nil) end)
end

local function damageCharacter(ch, amount)
    local bd = ch.getBodyDamage and ch:getBodyDamage()
    if bd then
        if pcall(function() bd:ReduceGeneralHealth(amount) end) then return end
        if pcall(function() bd:setOverallBodyHealth(math.max(0, bd:getOverallBodyHealth() - amount)) end) then return end
    end
    pcall(function() ch:setHealth(ch:getHealth() - (amount / 100.0)) end)
end

local function damageCharactersOnSquare(square, mult, blastRadius, player)
    if not square or not square.getMovingObjects then return end
    local movers
    local ok = pcall(function() movers = square:getMovingObjects() end)
    if not ok or not movers then return end
    local n = movers:size()
    for i = n - 1, 0, -1 do
        local obj = movers:get(i)
        if obj then
            if instanceof and instanceof(obj, "IsoZombie") then
                local dmg = Config.EXPLOSION.outerZombieDamage * mult
                if mult > 0.6 then
                    killZombie(obj, player)
                elseif dmg > 5 then
                    pcall(function() obj:setHealth(obj:getHealth() - dmg) end)
                    if obj:getHealth() <= 0 then killZombie(obj, player) end
                end
            elseif instanceof and (instanceof(obj, "IsoPlayer") or instanceof(obj, "IsoGameCharacter")) then
                damageCharacter(obj, Config.EXPLOSION.playerOuterDamage * mult)
            end
        end
    end
end

--=======================================================================--
-- STRUCTURE DESTRUCTION — top-down levelling (reworked)
--   Config.EXPLOSION.destroy drives two concentric zones:
--     dist <= fullRadius   : the top `levelsFromTop` occupied floor levels of
--                            the column are removed outright, and the impact
--                            level is stripped of everything but its floor.
--     dist <= damageRadius : heavy damage (windows smashed, doors/furniture
--                            battered); nothing structural above survives
--                            differently -- walls stay up here.
--=======================================================================--

-- Any tile object (floor/wall/furniture) means the level is "occupied".
local function squareHasStructure(sq)
    local n = 0
    pcall(function() n = sq:getObjects():size() end)
    if n > 0 then return true end
    pcall(function() n = sq:getSpecialObjects():size() end)
    return n > 0
end

-- Remove every tile object from a square (walls, floor, furniture).
local function clearSquare(sq)
    local function purge(list)
        if not list then return end
        for i = list:size() - 1, 0, -1 do
            local o = list:get(i)
            if o then
                local removed = pcall(function() sq:transmitRemoveItemFromSquare(o) end)
                if not removed then pcall(function() sq:RemoveTileObject(o) end) end
            end
        end
    end
    pcall(function() purge(sq:getObjects()) end)
    pcall(function() purge(sq:getSpecialObjects()) end)
    pcall(function() sq:RecalcAllWithNeighbours(true) end)
end

-- Level the top `levelsFromTop` occupied floor levels in the column at (x,y).
-- Ground level (z=0) is never removed wholesale -- charring handles it.
local function levelColumnTop(x, y, D)
    local topZ
    for z = D.maxScanZ or 31, 1, -1 do
        local sq = Utils.getSquare(x, y, z)
        if sq and squareHasStructure(sq) then topZ = z break end
    end
    if not topZ then return end
    local bottom = math.max(topZ - (D.levelsFromTop or 2) + 1, 1)
    for z = topZ, bottom, -1 do
        local sq = Utils.getSquare(x, y, z)
        if sq then clearSquare(sq) end
    end
end

-- Strip the impact level bare (walls, doors, furniture) but keep its floor,
-- so a ground-zero hit doesn't punch black holes into the terrain.
local function destroyAtImpact(sq)
    local objs
    pcall(function() objs = sq:getObjects() end)
    if not objs then return end
    local floor
    pcall(function() floor = sq:getFloor() end)
    for i = objs:size() - 1, 0, -1 do
        local o = objs:get(i)
        if o and o ~= floor then
            if o.smashWindow then pcall(function() o:smashWindow() end) end
            local removed = pcall(function() sq:transmitRemoveItemFromSquare(o) end)
            if not removed and o.removeFromWorld then
                pcall(function() o:removeFromWorld() end)
            end
        end
    end
end

-- Heavy-damage ring: batter destructibles without guaranteed demolition.
local function damageStructuresOnSquare(square, dist)
    if not square or not square.getObjects then return end
    local objs
    pcall(function() objs = square:getObjects() end)
    if not objs then return end
    for i = objs:size() - 1, 0, -1 do
        local o = objs:get(i)
        if not o then break end
        -- 75% per-object randomization keeps the ring looking organic.
        if ZombRand(100) < 75 then
            if o.smashWindow then
                pcall(function() o:smashWindow() end)
            elseif o.takeDamage then
                for _ = 1, 6 do
                    pcall(function() o:takeDamage(80) end)
                end
            end
        end
    end
end

--=======================================================================--
-- GROUND CHARRING
--=======================================================================--

local BURNT_SPRITES = {
    "floors_burnt_01_1", "floors_burnt_01_8",
    "floors_burnt_01_13", "floors_burnt_01_14", "floors_burnt_01_15"
}
local BURNT_SPRITE_COUNT = #BURNT_SPRITES

local function pickBurntSprite()
    return BURNT_SPRITES[ZombRand(BURNT_SPRITE_COUNT) + 1]
end

-- Permanently swap the floor sprite itself (core zone only). Returns true on
-- success so the caller can fall back to an overlay.
local function charFloorSprite(sq)
    local name = pickBurntSprite()
    if sq.getLuaFloorObject then
        local done = false
        pcall(function()
            local floor = sq:getLuaFloorObject()
            if floor and floor.setSpriteName then
                floor:setSpriteName(name)
                done = true
            end
        end)
        if done then return true end
    end
    if sq.setFloorSprite then
        if pcall(function() sq:setFloorSprite(name) end) then return true end
    end
    -- Last resort: mutate the floor object's sprite directly.
    local done = false
    pcall(function()
        local floor = sq:getFloor()
        if floor and floor.setSprite and getSprite then
            local spr = getSprite(name)
            if spr then
                floor:setSprite(spr)
                floor:transmitCompleteItemToClients()
                done = true
            end
        end
    end)
    return done
end

-- Removable scorch mark (outer zone): an IsoThumpable overlay carrying a burnt
-- sprite, so players can clear it in-game (sledgehammer destroy). Falls back
-- to a plain IsoObject if thumpables misbehave on this build. Idempotent per
-- square across multiple shots.
local function addBurntOverlay(sq)
    local existing
    pcall(function()
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            if o and o.getModData and o:getModData().MortarBurntOverlay then
                existing = o
                break
            end
        end
    end)
    if existing then return end

    local name = pickBurntSprite()
    local obj
    pcall(function() obj = IsoThumpable.new(Utils.getCell(), sq, name, false, {}) end)
    if obj then
        pcall(function()
            if obj.setMaxHealth then obj:setMaxHealth(40) end
            if obj.setHealth then obj:setHealth(40) end
            if obj.setCanBarricade then obj:setCanBarricade(false) end
            if obj.setIsDismantable then obj:setIsDismantable(true) end
            if obj.setBlockAllTheSquare then obj:setBlockAllTheSquare(false) end
        end)
    else
        -- Plain decorative object fallback (removable only via debug tools).
        pcall(function()
            if ZombRandFloat then
                obj = IsoObject.new(sq, name, "", false)
            else
                obj = IsoObject.new(Utils.getCell(), sq, name)
            end
        end)
    end
    if not obj then return end
    pcall(function() obj:getModData().MortarBurntOverlay = true end)
    local added = pcall(function() sq:AddTileObject(obj) end)
    if not added then pcall(function() sq:AddSpecialObject(obj) end) end
    pcall(function() obj:transmitCompleteItemToClients() end)
end

-- Charring policy (reworked): inside the total-destruction core the floor
-- sprite itself is charred (permanent); everywhere else in the blast the
-- scorch is a removable overlay object, with probability falling off with
-- distance.
local function charGround(sq, dist, blastRadius, D)
    if not sq then return end
    if dist <= (D and D.fullRadius or 2) then
        if not charFloorSprite(sq) then addBurntOverlay(sq) end
        return
    end
    local t = dist / math.max(blastRadius, 1)
    local chance = 0.9 * math.max(0, 1 - t)
    if ZombRand(100) >= chance * 100 then return end
    addBurntOverlay(sq)
end

--=======================================================================--
-- LINGERING SMOKE
--=======================================================================--

local function maybeSmoke(sq, dist, blastRadius)
    if not sq then return end
    if not IsoFireManager or type(IsoFireManager.StartSmoke) ~= "function" then
        return
    end
    local t = dist / math.max(blastRadius, 1)
    local chance = 0.25 * math.max(0, 1 - t)
    if ZombRand(100) >= chance * 100 then return end
    if ZombRandFloat then
        IsoFireManager.StartSmoke(Utils.getCell(), sq, false, 50, 900)
    else
        IsoFireManager.StartSmoke(Utils.getCell(), sq, true, 1)
    end
end

--=======================================================================--
-- MANUAL BLAST
--=======================================================================--

local function manualBlast(ctx, centre, blastRadius)
    local shell = ctx.shell
    local x, y, z = ctx.x, ctx.y, ctx.z
    local D = Config.EXPLOSION.destroy or { fullRadius = 2, damageRadius = 5, levelsFromTop = 2 }
    local affected = 0
    for dx = -blastRadius, blastRadius do
        for dy = -blastRadius, blastRadius do
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist <= blastRadius then
                local sq = (dx == 0 and dy == 0) and centre
                            or Utils.getSquare(x + dx, y + dy, z)
                if sq then
                    affected = affected + 1
                    local mult = falloff(dist, blastRadius)
                    if shell.damagesCharacters then
                        damageCharactersOnSquare(sq, mult, blastRadius, ctx.player)
                    end
                    if shell.damagesStructures then
                        if dist <= D.fullRadius then
                            -- Total destruction core: level the top floor
                            -- levels of the column, strip the impact level.
                            levelColumnTop(x + dx, y + dy, D)
                            destroyAtImpact(sq)
                        elseif dist <= D.damageRadius then
                            -- Damaged ring: battered but standing.
                            damageStructuresOnSquare(sq, dist)
                        end
                    end
                    charGround(sq, dist, blastRadius, D)
                    maybeSmoke(sq, dist, blastRadius)
                end
            end
        end
    end
    return affected
end

--=======================================================================--
-- HE DETONATION
--=======================================================================--

function Explosion.detonateHE(ctx)
    local shell = ctx.shell
    local x, y, z = ctx.x, ctx.y, ctx.z

    local centre = ctx.square or Utils.getSquare(x, y, z)
    if not centre then
        Log.debug("detonateHE: impact (%d,%d,%d) terrain not loaded; defer.", x, y, z)
        return { detonated = false, needsSquare = true }
    end

    local rMin = shell.blastRadiusMin or 10
    local rMax = shell.blastRadiusMax or rMin
    local blastRadius = rMin
    if rMax > rMin and ZombRand then
        blastRadius = rMin + ZombRand(rMax - rMin + 1)
    end

    -- Manual blast only (no native explode — it always creates fire in B42).
    local affected = manualBlast(ctx, centre, blastRadius)

    -- Huge world sound at impact.
    Explosion.worldSound(x, y, z, Config.NOISE.radius, Config.NOISE.volume)

    Log.info("HE detonation at (%d,%d,%d) r=%d tiles=%d.", x, y, z, blastRadius, affected)
    return { detonated = true, note = string.format("r=%d tiles=%d", blastRadius, affected) }
end

-- Register as the HE effect handler.
Shells.registerEffect("HE", Explosion.detonateHE)

return Explosion
