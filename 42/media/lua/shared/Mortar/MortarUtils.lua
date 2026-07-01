--***********************************************************************--
-- Mortar System  -  MortarUtils.lua
--
-- PURPOSE
--   Grab-bag of small, reusable engine-aware helpers that don't belong to a
--   single subsystem: action-time conversion, environment checks, game-time,
--   table helpers, and safe IsoObject/coord utilities.
--
-- RESPONSIBILITIES
--   * Convert design "seconds" into PZ timed-action ticks (skill-scaled).
--   * Provide MP/SP environment predicates in one place.
--   * Shallow/deep copy, table length, value-in-list helpers.
--   * Square/coordinate fetch wrappers that fail soft (log + nil, never crash).
--
-- DATA FLOW
--   Depends on Config + Log + Math. Used widely. Engine calls are wrapped so a
--   missing API degrades gracefully rather than erroring on load.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarMath"

MortarMod = MortarMod or {}
MortarMod.Utils = MortarMod.Utils or {}

local Utils = MortarMod.Utils
local Config = MortarMod.Config
local Log = MortarMod.Log
local Mth = MortarMod.Math

--=======================================================================--
-- ENVIRONMENT PREDICATES
--   Centralise the SP / MP-client / MP-server branching used by networking.
--=======================================================================--

-- True on a multiplayer client (not the integrated host's server thread).
function Utils.isMPClient()
    return isClient and isClient() == true
end

-- True on a dedicated/integrated server thread.
function Utils.isServerSide()
    return isServer and isServer() == true
end

-- True in single-player (neither MP client nor server).
function Utils.isSinglePlayer()
    return not Utils.isMPClient() and not Utils.isServerSide()
end

-- True when authoritative world-mutating code may run *in this VM right now*:
-- single-player OR the server. (MP clients must defer to the server.)
function Utils.isAuthority()
    return Utils.isServerSide() or Utils.isSinglePlayer()
end

--=======================================================================--
-- TIMED ACTION TIMING
--=======================================================================--

-- Convert real seconds to PZ action ticks using the configured factor.
function Utils.secondsToTicks(seconds)
    return math.max(1, Mth.round(seconds * Config.ACTION.ticksPerSecond))
end

-- Compute a setup/breakdown action duration (ticks) scaled by Nimble & Strength.
-- baseSeconds: the un-skilled duration. Returns integer ticks.
function Utils.skilledActionTicks(character, baseSeconds)
    local factor = 1.0
    if character and character.getPerkLevel and Perks then
        local nimble = character:getPerkLevel(Perks.Nimble) or 0
        local strength = character:getPerkLevel(Perks.Strength) or 0
        factor = factor
            - nimble   * Config.DEPLOY.nimblePerLevel
            - strength * Config.DEPLOY.strengthPerLevel
    end
    factor = Mth.clamp(factor, Config.DEPLOY.minDurationFactor, 1.0)
    return Utils.secondsToTicks(baseSeconds * factor)
end

--=======================================================================--
-- GAME TIME
--=======================================================================--

-- Current in-game world time in minutes (float). Used to schedule expiry of
-- smoke clouds, flares, and spotter solutions. Falls back to 0 if unavailable.
function Utils.gameMinutes()
    local gt = getGameTime and getGameTime()
    if not gt then return 0 end
    -- World age in hours -> minutes. getWorldAgeHours is stable across builds.
    if gt.getWorldAgeHours then
        return gt:getWorldAgeHours() * 60.0
    end
    return 0
end

--=======================================================================--
-- COORDINATE / SQUARE HELPERS  (fail soft)
--=======================================================================--

-- Safe getCell(). Returns the cell or nil.
function Utils.getCell()
    if not getCell then return nil end
    local ok, cell = pcall(getCell)
    if ok then return cell end
    return nil
end

-- Fetch an existing grid square at world coords, or nil. Never throws.
function Utils.getSquare(x, y, z)
    local cell = Utils.getCell()
    if not cell then return nil end
    local ok, sq = pcall(function() return cell:getGridSquare(x, y, z) end)
    if ok then return sq end
    return nil
end

-- Fetch or create a grid square (creates the IsoGridSquare if the underlying
-- chunk data is present). Returns the square or nil.
function Utils.getOrCreateSquare(x, y, z)
    local cell = Utils.getCell()
    if not cell then return nil end
    if cell.getOrCreateGridSquare then
        local ok, sq = pcall(function() return cell:getOrCreateGridSquare(x, y, z) end)
        if ok and sq then return sq end
    end
    return Utils.getSquare(x, y, z)
end

-- World coords of an IsoObject's square as integers (x, y, z) or nil.
function Utils.objectCoords(obj)
    if not obj or not obj.getSquare then return nil end
    local sq = obj:getSquare()
    if not sq then return nil end
    return sq:getX(), sq:getY(), sq:getZ()
end

--=======================================================================--
-- TABLE HELPERS
--=======================================================================--

-- Shallow copy of a flat table.
function Utils.shallowCopy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- Recursive deep copy (no metatables, no cycles -- fine for plain data).
function Utils.deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do
        out[k] = Utils.deepCopy(v)
    end
    return out
end

-- Is `value` present in array `list`?
function Utils.contains(list, value)
    for i = 1, #list do
        if list[i] == value then return true end
    end
    return false
end

-- Count keys in a (possibly non-array) table.
function Utils.count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--=======================================================================--
-- MISC
--=======================================================================--

-- Resolve the player object for a given online id, or the local player in SP.
-- In MP server context, command handlers receive the player directly, so this
-- is mostly a SP/client convenience.
function Utils.getPlayer()
    if getSpecificPlayer then
        local p = getSpecificPlayer(0)
        if p then return p end
    end
    if getPlayer then return getPlayer() end
    return nil
end

return Utils
