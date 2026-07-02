--***********************************************************************--
-- Mortar System  -  MortarTargeting.lua
--
-- PURPOSE
--   The target-acquisition abstraction (design override "Spotter Support").
--   Everything downstream of aiming consumes a single neutral data structure --
--   a FIRE SOLUTION -- regardless of whether the coordinates came from the UI,
--   a map-plotted spotter mission, or (future) a second player.
--
-- FIRE SOLUTION (plain table; safe to serialise / send over the network)
--   {
--     originX, originY, originZ,   -- the mortar tube tile
--     bearing,                      -- compass degrees [0,360)
--     range,                        -- tiles from tube to intended target
--     chargeId,                     -- propellant charge (0..N)
--     targetX, targetY, targetZ,    -- resolved intended target tile (pre-scatter)
--     shellKey,                     -- selected shell ("HE"/"SMOKE"/"ILLUM")
--     source,                       -- "UI" | "SPOTTER" | "MARKER"
--     spotterPlotTier,              -- tool tier used to plot (optional)
--   }
--
-- RESPONSIBILITIES
--   * Build a solution from bearing+range (UI path).
--   * Build a solution from two world points (spotter / map-plot path) --
--     computing bearing, range, and the best charge automatically.
--   * Validate solutions (min/max range).
--   * Persist a "pending" spotter solution on the player so the firing UI can
--     pick it up, with a TTL so stale missions expire.
--
-- DATA FLOW
--   Depends on Config, Math, Utils. Consumed by the UI, the firing pipeline,
--   and the spotter/map module. Engine-agnostic (operates on numbers), so it is
--   shared and runs identically on client and server.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarMath"
require "Mortar/MortarUtils"

MortarMod = MortarMod or {}
MortarMod.Targeting = MortarMod.Targeting or {}

local Targeting = MortarMod.Targeting
local Config = MortarMod.Config
local Log = MortarMod.Log
local Mth = MortarMod.Math
local Utils = MortarMod.Utils

--=======================================================================--
-- CHARGE SELECTION
--=======================================================================--

-- Best charge id whose range band contains `range`. Prefers the LOWEST such
-- charge (less propellant -> tighter base scatter). If no band contains it,
-- clamps to the nearest band edge.
function Targeting.bestChargeForRange(range)
    local best, bestGap
    for _, c in ipairs(Config.CHARGES) do
        if range >= c.minRange and range <= c.maxRange then
            return c.id
        end
        -- Track nearest band by edge distance for the clamp fallback.
        local gap
        if range < c.minRange then gap = c.minRange - range else gap = range - c.maxRange end
        if not bestGap or gap < bestGap then
            bestGap, best = gap, c.id
        end
    end
    return best or 0
end

-- Clamp a range to a charge's valid band.
function Targeting.clampRangeToCharge(range, chargeId)
    local c = Config.getCharge(chargeId)
    if not c then return range end
    return Mth.clamp(range, c.minRange, c.maxRange)
end

--=======================================================================--
-- SOLUTION CONSTRUCTORS
--=======================================================================--

-- Build a solution from bearing + range (the manual UI path).
function Targeting.fromBearingRange(originX, originY, originZ, bearing, range, chargeId, shellKey)
    bearing = Mth.normalizeBearing(bearing)
    local tx, ty = Mth.projectBearing(originX, originY, bearing, range)
    return {
        originX = originX, originY = originY, originZ = originZ,
        bearing = bearing,
        range   = range,
        chargeId = chargeId,
        targetX = Mth.round(tx),
        targetY = Mth.round(ty),
        targetZ = originZ,
        shellKey = shellKey,
        source  = "UI",
    }
end

-- Build a solution from two world points: the tube (origin) and a target tile.
-- Computes bearing, range and the best charge automatically. Used by the map
-- plotting device / spotter. `plotTier` records the tool quality for scatter.
function Targeting.fromPoints(originX, originY, originZ, targetX, targetY, plotTier, shellKey)
    local dx = targetX - originX
    local dy = targetY - originY
    local range = math.sqrt(dx * dx + dy * dy)
    local bearing = Mth.vectorToBearing(dx, dy)
    local chargeId = Targeting.bestChargeForRange(range)
    return {
        originX = originX, originY = originY, originZ = originZ,
        bearing = bearing,
        range   = range,
        chargeId = chargeId,
        targetX = Mth.round(targetX),
        targetY = Mth.round(targetY),
        targetZ = originZ,
        shellKey = shellKey,
        source  = "SPOTTER",
        spotterPlotTier = plotTier,
    }
end

--=======================================================================--
-- VALIDATION
--=======================================================================--

-- Validate a solution's range against the global + charge limits.
-- Returns: ok (bool), reasonKey (translation key or nil)
function Targeting.validate(solution)
    if not solution then return false, "IGUI_Mortar_Err_NoSolution" end

    local range = solution.range or 0
    if range < Config.RANGE.minRangeTiles then
        return false, "IGUI_Mortar_Err_TooClose"
    end
    if range > Config.RANGE.maxRangeTiles then
        return false, "IGUI_Mortar_Err_TooFar"
    end

    -- Per-shell range cap (e.g. illumination rounds fly shorter). Data-driven
    -- from the shell definition; solutions without a shell key skip this and
    -- are re-validated at fire time when the shell is known.
    if solution.shellKey and MortarMod.Shells and MortarMod.Shells.get then
        local shell = MortarMod.Shells.get(solution.shellKey)
        if shell and shell.maxRangeTiles and range > shell.maxRangeTiles then
            return false, "IGUI_Mortar_Err_TooFar"
        end
    end

    local c = Config.getCharge(solution.chargeId)
    if not c then
        return false, "IGUI_Mortar_Err_BadCharge"
    end
    return true, nil
end

-- Short human description (debug / log).
function Targeting.describe(s)
    if not s then return "<nil solution>" end
    return string.format(
        "src=%s shell=%s brg=%.0f rng=%.1f chg=%s target=(%d,%d,%d)",
        tostring(s.source), tostring(s.shellKey), s.bearing or 0, s.range or 0,
        tostring(s.chargeId), s.targetX or 0, s.targetY or 0, s.targetZ or 0)
end

--=======================================================================--
-- PENDING SPOTTER SOLUTION (player modData, with TTL)
--=======================================================================--

local PENDING_KEY = "MortarPendingSolution"

-- Store a plotted solution on the player. Stamped with game-time for TTL.
function Targeting.setPendingSolution(player, solution)
    if not player or not player.getModData then return end
    local md = player:getModData()
    solution = Utils.deepCopy(solution)
    solution._stampMinutes = Utils.gameMinutes()
    md[PENDING_KEY] = solution
    Log.debug("Stored pending spotter solution: %s", Targeting.describe(solution))
end

-- Retrieve a non-expired pending solution, or nil. Expired ones are cleared.
function Targeting.getPendingSolution(player)
    if not player or not player.getModData then return nil end
    local md = player:getModData()
    local s = md[PENDING_KEY]
    if not s then return nil end
    local age = Utils.gameMinutes() - (s._stampMinutes or 0)
    if age > Config.SPOTTER.solutionTtlMinutes then
        md[PENDING_KEY] = nil
        Log.debug("Pending spotter solution expired (%.0f min).", age)
        return nil
    end
    return s
end

function Targeting.clearPendingSolution(player)
    if not player or not player.getModData then return end
    player:getModData()[PENDING_KEY] = nil
end

return Targeting
