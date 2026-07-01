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
--   * Damage falls off continuously from ground zero to blast edge.
--   * Ground charring probability decreases with distance.
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
-- STRUCTURE DAMAGE — concentric zones with per-object-type radius limits
--=======================================================================--

local function damageStructuresOnSquare(square, dist)
    if not square or not square.getObjects then return end
    local objs
    pcall(function() objs = square:getObjects() end)
    if not objs then return end
    for i = objs:size() - 1, 0, -1 do
        local o = objs:get(i)
        if not o then break end

        -- Per-object-type max effective radius.
        local maxRadius = 2
        local isWall = false
        if instanceof then
            if instanceof(o, "IsoWindow") then
                maxRadius = 10
            elseif instanceof(o, "IsoDoor") then
                maxRadius = 6
            elseif instanceof(o, "IsoThumpable") then
                if o.isFence then
                    maxRadius = 5
                elseif o.isWall and o.isWooden then
                    maxRadius = 3
                elseif o.isWall then
                    maxRadius = 2; isWall = true
                end
            end
            if o.isTree then
                maxRadius = 5
            end
        end

        -- Check radius and 75% per-object randomization.
        if dist <= maxRadius and ZombRand(100) < 75 then
            if dist <= 2 then
                -- Complete destruction zone.
                if o.smashWindow then
                    pcall(function() o:smashWindow() end)
                end
                pcall(function() square:transmitRemoveItemFromSquare(o) end)
                if o.removeFromWorld then
                    pcall(function() o:removeFromWorld() end)
                end
                if o.setIsDismantled then
                    pcall(function() o:setIsDismantled(true) end)
                end

            elseif dist <= 5 then
                -- Heavy damage zone.
                if o.smashWindow then
                    pcall(function() o:smashWindow() end)
                elseif o.takeDamage then
                    for j = 1, 6 do
                        pcall(function() o:takeDamage(80) end)
                    end
                end

            else
                -- Light damage zone (6-10) — walls survive.
                if not isWall then
                    if o.smashWindow then
                        pcall(function() o:smashWindow() end)
                    elseif o.takeDamage then
                        pcall(function() o:takeDamage(30) end)
                    end
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

-- Scorch a single square. Places a burnt sprite as a tile object since B42
-- may not expose setFloorSprite or getLuaFloorObject.
local function maybeCharGround(sq, dist, blastRadius)
    if not sq then return end
    local t = dist / math.max(blastRadius, 1)
    local chance = 0.9 * math.max(0, 1 - t)
    if ZombRand(100) >= chance * 100 then return end
    -- Try the direct floor API first.
    if sq.getLuaFloorObject then
        local floor = sq:getLuaFloorObject()
        if floor and floor.setSpriteName then
            floor:setSpriteName(BURNT_SPRITES[ZombRand(BURNT_SPRITE_COUNT) + 1])
            return
        end
    end
    if sq.setFloorSprite then
        sq:setFloorSprite(BURNT_SPRITES[ZombRand(BURNT_SPRITE_COUNT) + 1])
        return
    end
    -- Fallback: place a decorative IsoObject with burnt sprite.
    local cell = Utils.getCell()
    if not cell then return end
    local burntObj
    if ZombRandFloat then
        burntObj = IsoObject.new(sq, BURNT_SPRITES[ZombRand(BURNT_SPRITE_COUNT) + 1], "", false)
    else
        burntObj = IsoObject.new(Utils.getCell(), sq, BURNT_SPRITES[ZombRand(BURNT_SPRITE_COUNT) + 1])
    end
    if burntObj then
        pcall(function() sq:AddSpecialObject(burntObj) end)
        pcall(function() burntObj:transmitCompleteItemToClients() end)
    end
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
                        damageStructuresOnSquare(sq, dist)
                    end
                    maybeCharGround(sq, dist, blastRadius)
                    maybeSmoke(sq, dist, blastRadius)
                end
                -- Also damage structures and char ground on Z+1 and Z+2
                -- (top 2 floors above impact).
                if shell.damagesStructures then
                    for dz = 1, 2 do
                        local upSq = Utils.getSquare(x + dx, y + dy, z + dz)
                        if upSq then
                            damageStructuresOnSquare(upSq, dist)
                            maybeCharGround(upSq, dist, blastRadius)
                            maybeSmoke(upSq, dist, blastRadius)
                        end
                    end
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
