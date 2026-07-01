--***********************************************************************--
-- Mortar System  -  MortarMoodles.lua
--
-- PURPOSE
--   Read the firing character's moodles (panic, tired, drunk, injured, thermal)
--   and turn them into a combined scatter multiplier per design 5.3.
--
-- RESPONSIBILITIES
--   * Resolve MoodleType enum members defensively (names differ across builds).
--   * Map moodle *levels* (0..4) to the design's tiers, then to the configured
--     multipliers in Config.SCATTER.moodle.
--   * Provide a breakdown for the UI / debug overlay.
--
-- DATA FLOW
--   Depends on Config + Log. Pure read of an IsoPlayer. Used by MortarScatter
--   on the authority side. Engine access is wrapped; an unknown moodle simply
--   contributes x1.0.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"

MortarMod = MortarMod or {}
MortarMod.Moodles = MortarMod.Moodles or {}

local Moodles = MortarMod.Moodles
local Config = MortarMod.Config
local Log = MortarMod.Log

-- Level thresholds mapping engine moodle levels (0..4) to design tiers.
-- These are semantic mappings, not balance values (the multipliers live in
-- Config.SCATTER.moodle). Tune here if PZ changes how levels escalate.
local THRESHOLD = {
    panicModerate = 1,  -- level >= 1 and < panicExtreme
    panicExtreme  = 3,  -- level >= 3
    tiredVery     = 3,  -- "very tired"
    drunk         = 2,  -- noticeably drunk
    injured       = 1,  -- any injury / pain
    thermal       = 1,  -- any hyper/hypothermia
}

-- Candidate MoodleType member names per concept (first that exists is used).
local TYPE_NAMES = {
    panic   = { "Panic" },
    tired   = { "Tired" },
    drunk   = { "Drunk" },
    injured = { "Injured", "Pain" },
    hyper   = { "Hyperthermia", "HyperThermia", "Hot" },
    hypo    = { "Hypothermia", "HypoThermia", "Cold" },
}

-- Resolve and cache the actual MoodleType enum members available this build.
local resolved = nil
local function resolveTypes()
    if resolved then return resolved end
    resolved = {}
    if not MoodleType then return resolved end
    for concept, names in pairs(TYPE_NAMES) do
        for _, n in ipairs(names) do
            if MoodleType[n] ~= nil then
                resolved[concept] = MoodleType[n]
                break
            end
        end
    end
    return resolved
end

-- Get the level (0..4) of a resolved moodle concept for a player.
local function levelOf(player, concept)
    local types = resolveTypes()
    local mt = types[concept]
    if not mt then return 0 end
    local m = player and player.getMoodles and player:getMoodles()
    if not m or not m.getMoodleLevel then return 0 end
    local ok, lvl = pcall(function() return m:getMoodleLevel(mt) end)
    if ok and type(lvl) == "number" then return lvl end
    return 0
end

--=======================================================================--
-- PUBLIC: COMBINED MULTIPLIER + BREAKDOWN
--=======================================================================--

-- Returns: combinedMultiplier (number), breakdown (array of {name, mult})
function Moodles.evaluate(player)
    local S = Config.SCATTER.moodle
    local combined = 1.0
    local breakdown = {}

    local function apply(name, mult)
        combined = combined * mult
        breakdown[#breakdown + 1] = { name = name, mult = mult }
    end

    if not player then
        return combined, breakdown
    end

    -- Panic (extreme overrides moderate).
    local panic = levelOf(player, "panic")
    if panic >= THRESHOLD.panicExtreme then
        apply("panicExtreme", S.panicExtreme)
    elseif panic >= THRESHOLD.panicModerate then
        apply("panicModerate", S.panicModerate)
    end

    -- Tired.
    if levelOf(player, "tired") >= THRESHOLD.tiredVery then
        apply("tired", S.tiredVery)
    end

    -- Drunk.
    if levelOf(player, "drunk") >= THRESHOLD.drunk then
        apply("drunk", S.drunk)
    end

    -- Injured / pain.
    if levelOf(player, "injured") >= THRESHOLD.injured then
        apply("injured", S.injured)
    end

    -- Thermal (hyper OR hypo).
    if levelOf(player, "hyper") >= THRESHOLD.thermal
        or levelOf(player, "hypo") >= THRESHOLD.thermal then
        apply("thermal", S.thermal)
    end

    return combined, breakdown
end

-- Convenience: multiplier only.
function Moodles.multiplier(player)
    local m = Moodles.evaluate(player)
    return m
end

return Moodles
