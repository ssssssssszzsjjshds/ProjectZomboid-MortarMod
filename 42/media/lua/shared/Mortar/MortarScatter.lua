--***********************************************************************--
-- Mortar System  -  MortarScatter.lua
--
-- PURPOSE
--   Compute the composite scatter radius for a shot and turn it into a concrete
--   impact tile. Implements design section 5 exactly: all factors multiply.
--
--     scatterRadius = baseRadius[charge]
--                   * toolMult * skillMult * conditionMult
--                   * moodleMult * weatherMult * spotterMult * globalScalar
--     dX = gaussian(0, scatterRadius);  dY = gaussian(0, scatterRadius)
--     impact = target + round(dX, dY)
--
-- RESPONSIBILITIES
--   * Assemble every multiplier from the relevant subsystem.
--   * Return BOTH the radius and a fully itemised breakdown so the UI and the
--     debug overlay can explain "why did it miss".
--   * Roll the gaussian offset and resolve the impact tile.
--
-- DETERMINISM / MP
--   The gaussian roll uses math.random. On the authority side (server in MP)
--   this is rolled once per shot so all clients see the same impact.
--
-- DATA FLOW
--   Depends on Config, Math, Weather, Moodles, Inventory. Pure aside from the
--   RNG and the subsystem reads. Called by MortarFire (authority) and by the UI
--   for a no-RNG radius *preview*.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarMath"
require "Mortar/MortarWeather"
require "Mortar/MortarMoodles"
require "Mortar/MortarInventory"

MortarMod = MortarMod or {}
MortarMod.Scatter = MortarMod.Scatter or {}

local Scatter = MortarMod.Scatter
local Config = MortarMod.Config
local Log = MortarMod.Log
local Mth = MortarMod.Math
local Weather = MortarMod.Weather
local Moodles = MortarMod.Moodles
local Inv = MortarMod.Inventory

--=======================================================================--
-- INDIVIDUAL FACTORS
--=======================================================================--

-- Aiming skill multiplier from the configured bands.
local function skillMultiplier(player)
    local level = 0
    if player and player.getPerkLevel and Perks then
        level = player:getPerkLevel(Perks.Aiming) or 0
    end
    for _, band in ipairs(Config.SCATTER.skill) do
        if level >= band.min and level <= band.max then
            return band.mult, level
        end
    end
    return 1.0, level
end

-- Condition multiplier: 1.0 at full condition, up to maxConditionMult at zero.
-- conditionFraction is 0..1 (1 = pristine). nil treated as pristine.
local function conditionMultiplier(conditionFraction)
    if conditionFraction == nil then return 1.0 end
    conditionFraction = Mth.clamp(conditionFraction, 0, 1)
    return Mth.lerp(Config.SCATTER.maxConditionMult, 1.0, conditionFraction)
end

--=======================================================================--
-- COMPOSITE RADIUS
--=======================================================================--

-- Compute the scatter radius. `opts`:
--   player            IsoPlayer (skill / moodle reads)
--   chargeId          numeric charge id
--   toolTier          tool tier string (defaults to resolving from inventory)
--   conditionFraction 0..1 mortar condition (default 1)
--   spotterPlotTier   tool tier used to plot a spotter solution, or nil
-- Returns: radius (number), breakdown (table)
function Scatter.computeRadius(opts)
    opts = opts or {}
    local player = opts.player

    local charge = Config.getCharge(opts.chargeId)
    local base = charge and charge.baseScatter or Config.CHARGES[1].baseScatter

    local toolTier = opts.toolTier or Inv.getToolTier(player)
    local toolMult = Config.SCATTER.tool[toolTier] or Config.SCATTER.tool.RULER

    local sMult, aimingLevel = skillMultiplier(player)
    local cMult = conditionMultiplier(opts.conditionFraction)
    local mMult, moodleBreak = Moodles.evaluate(player)
    local wMult, weatherBreak = Weather.evaluate()

    -- Spotter solutions can carry an extra plotting penalty.
    local spotMult = 1.0
    if opts.spotterPlotTier then
        spotMult = Config.SPOTTER.plotAccuracyByTool[opts.spotterPlotTier] or 1.0
    end

    local globalScalar = Config.scatterGlobalScalar or 1.0

    local radius = base
        * toolMult
        * sMult
        * cMult
        * mMult
        * wMult
        * spotMult
        * globalScalar

    radius = Mth.clamp(radius, Config.SCATTER.minRadius, Config.SCATTER.maxRadius)

    local breakdown = {
        base          = base,
        charge        = charge and charge.id or nil,
        toolTier      = toolTier,
        toolMult      = toolMult,
        aimingLevel   = aimingLevel,
        skillMult     = sMult,
        conditionMult = cMult,
        moodleMult    = mMult,
        moodle        = moodleBreak,
        weatherMult   = wMult,
        weather       = weatherBreak,
        spotterMult   = spotMult,
        globalScalar  = globalScalar,
        radius        = radius,
    }
    return radius, breakdown
end

--=======================================================================--
-- IMPACT RESOLUTION
--=======================================================================--

-- Roll a gaussian offset and resolve the impact tile from a target tile.
-- Returns: impactX, impactY, dX, dY (integer tile offsets).
function Scatter.resolveImpact(targetX, targetY, radius)
    local dX, dY = Mth.scatterOffset(radius)
    return targetX + dX, targetY + dY, dX, dY
end

-- Convenience used by debug/preview: the 1-sigma circle radius for drawing.
function Scatter.previewRadius(opts)
    local r = Scatter.computeRadius(opts)
    return r
end

return Scatter
