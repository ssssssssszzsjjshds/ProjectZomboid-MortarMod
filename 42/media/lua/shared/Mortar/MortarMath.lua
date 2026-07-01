--***********************************************************************--
-- Mortar System  -  MortarMath.lua
--
-- PURPOSE
--   Pure, deterministic-where-possible math helpers used by targeting and
--   scatter. Kept free of any PZ engine dependency so it is trivially testable
--   and reusable.
--
-- RESPONSIBILITIES
--   * Bearing <-> direction vector conversions (PZ coordinate convention).
--   * Gaussian (normal) random sampling for scatter offsets.
--   * Distance / clamping / rounding helpers.
--
-- COORDINATE CONVENTION (Project Zomboid)
--   +X = East, +Y = South. North is -Y. Compass bearing 0 deg = North.
--     bearing   0 -> ( 0,-1)  North
--     bearing  90 -> ( 1, 0)  East
--     bearing 180 -> ( 0, 1)  South
--     bearing 270 -> (-1, 0)  West
--
-- EXTENSION POINTS
--   * gaussian() uses Box-Muller; swap implementation here if a different
--     distribution is ever wanted -- all scatter flows through it.
--***********************************************************************--

require "Mortar/MortarConfig"

MortarMod = MortarMod or {}
MortarMod.Math = MortarMod.Math or {}

local M = MortarMod.Math

local PI = math.pi
local TWO_PI = PI * 2
local DEG2RAD = PI / 180
local RAD2DEG = 180 / PI

--=======================================================================--
-- BASIC HELPERS
--=======================================================================--

-- Clamp v to [lo, hi].
function M.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Round to nearest integer (Lua 5.1 has no math.round). Handles negatives.
function M.round(v)
    if v >= 0 then
        return math.floor(v + 0.5)
    else
        return math.ceil(v - 0.5)
    end
end

-- Normalise a compass bearing into [0, 360).
function M.normalizeBearing(deg)
    deg = deg % 360
    if deg < 0 then deg = deg + 360 end
    return deg
end

-- Euclidean distance between two points.
function M.distance(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    return math.sqrt(dx * dx + dy * dy)
end

-- Squared distance (avoid sqrt when only comparing).
function M.distanceSq(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    return dx * dx + dy * dy
end

-- Linear interpolation.
function M.lerp(a, b, t)
    return a + (b - a) * t
end

--=======================================================================--
-- BEARING <-> VECTOR
--=======================================================================--

-- Unit direction vector for a compass bearing (degrees). See convention above.
function M.bearingToVector(bearingDeg)
    local rad = bearingDeg * DEG2RAD
    -- bearing 0 -> (0,-1): dx = sin, dy = -cos
    return math.sin(rad), -math.cos(rad)
end

-- Compass bearing (degrees, [0,360)) for a direction vector (dx, dy).
function M.vectorToBearing(dx, dy)
    -- Inverse of bearingToVector: bearing = atan2(dx, -dy)
    local deg = math.atan2(dx, -dy) * RAD2DEG
    return M.normalizeBearing(deg)
end

-- Project a point `range` tiles along `bearing` from (ox, oy).
-- Returns floating-point target coordinates (caller rounds if needed).
function M.projectBearing(ox, oy, bearingDeg, range)
    local vx, vy = M.bearingToVector(bearingDeg)
    return ox + vx * range, oy + vy * range
end

--=======================================================================--
-- GAUSSIAN RANDOM (Box-Muller)
--   Returns a sample from a normal distribution. PZ's ZombRand is integer-only
--   and not networked-deterministic for floats, so we use math.random which is
--   seeded by the engine. For MP authority the server performs the roll.
--=======================================================================--

-- Uniform random in [0,1) safe for B42 server where math.random is nil.
local function randUniform()
    if ZombRandFloat then
        return ZombRandFloat(0, 1)
    end
    return math.random()
end

-- Cached second Box-Muller value (the transform yields two per computation).
local spareReady = false
local spareValue = 0

-- Standard normal sample (mean 0, stddev 1).
function M.gaussianUnit()
    if spareReady then
        spareReady = false
        return spareValue
    end
    -- Avoid log(0).
    local u1 = randUniform()
    if u1 < 1e-12 then u1 = 1e-12 end
    local u2 = randUniform()
    local mag = math.sqrt(-2.0 * math.log(u1))
    local z0 = mag * math.cos(TWO_PI * u2)
    local z1 = mag * math.sin(TWO_PI * u2)
    spareValue = z1
    spareReady = true
    return z0
end

-- Normal sample with given mean and standard deviation.
function M.gaussian(mean, stddev)
    return mean + M.gaussianUnit() * stddev
end

-- Sample a 2D scatter offset (dx, dy) in tiles for a given scatter radius,
-- where `radius` is used as the standard deviation on each axis (design 5.4).
-- Returns integer tile offsets.
function M.scatterOffset(radius)
    local dx = M.gaussian(0, radius)
    local dy = M.gaussian(0, radius)
    return M.round(dx), M.round(dy)
end

return M
