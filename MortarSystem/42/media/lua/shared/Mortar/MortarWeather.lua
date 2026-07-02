--***********************************************************************--
-- Mortar System  -  MortarWeather.lua
--
-- PURPOSE
--   Read the live climate (wind / rain / fog) and turn it into a single
--   weather scatter multiplier per design 5.3.
--
-- RESPONSIBILITIES
--   * Defensively query getClimateManager() -- method names have shifted across
--     builds, so every read probes several candidate getters and fails soft.
--   * Bucket raw readings using Config.WEATHER thresholds.
--   * Produce a combined multiplier (wind * rain * fog) plus a human-readable
--     breakdown for the UI / debug overlay.
--
-- EXTENSION POINTS
--   * Add a new weather factor by reading it in sample() and folding it into
--     multiplier() + the breakdown table.
--
-- DATA FLOW
--   Depends on Config + Log. Called by MortarScatter (authority side) and by
--   the UI for a preview. All engine access is wrapped so a renamed API only
--   means "weather contributes x1.0", never a crash.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"

MortarMod = MortarMod or {}
MortarMod.Weather = MortarMod.Weather or {}

local Weather = MortarMod.Weather
local Config = MortarMod.Config
local Log = MortarMod.Log

--=======================================================================--
-- DEFENSIVE CLIMATE ACCESS
--=======================================================================--

-- Try a list of zero-arg getter names on an object; return the first numeric
-- result, else `fallback`. Keeps us resilient to B41<->B42 method renames.
local function tryGetters(obj, names, fallback)
    if not obj then return fallback end
    for i = 1, #names do
        local name = names[i]
        local fn = obj[name]
        if type(fn) == "function" then
            local ok, val = pcall(fn, obj)
            if ok and type(val) == "number" then
                return val
            end
            -- Some getters return Float objects; coerce if possible.
            if ok and val ~= nil and type(val) == "userdata" then
                local ok2, num = pcall(tonumber, tostring(val))
                if ok2 and num then return num end
            end
        end
    end
    return fallback
end

local function climate()
    if not getClimateManager then return nil end
    local ok, mgr = pcall(getClimateManager)
    if ok then return mgr end
    return nil
end

--=======================================================================--
-- RAW SAMPLES (normalised 0..1 where applicable)
--=======================================================================--

-- Wind speed in MPH (approximate). Climate wind intensity is normalised 0..1;
-- we scale by Config.WEATHER.windMaxMph. If a direct speed getter exists we use
-- it as-is.
function Weather.windMph()
    local mgr = climate()
    -- Prefer a direct speed if exposed; else use normalised intensity.
    local intensity = tryGetters(mgr, {
        "getWindIntensity", "getWindAngleIntensity", "getWindPower",
    }, nil)
    if intensity ~= nil then
        return intensity * Config.WEATHER.windMaxMph
    end
    local speed = tryGetters(mgr, { "getWindSpeed" }, nil)
    if speed ~= nil then return speed end
    return 0
end

-- Rain intensity 0..1.
function Weather.rainIntensity()
    local mgr = climate()
    local v = tryGetters(mgr, {
        "getPrecipitationIntensity", "getRainIntensity",
    }, nil)
    if v ~= nil then return v end
    -- Boolean fallback: isRaining() -> treat as moderate.
    if mgr and type(mgr.isRaining) == "function" then
        local ok, raining = pcall(mgr.isRaining, mgr)
        if ok and raining then return 0.5 end
    end
    return 0
end

-- Fog intensity 0..1.
function Weather.fogIntensity()
    local mgr = climate()
    return tryGetters(mgr, { "getFogIntensity" }, 0)
end

--=======================================================================--
-- BUCKETING -> MULTIPLIERS
--=======================================================================--

local function windMult(mph)
    local W = Config.WEATHER
    local S = Config.SCATTER.weather
    if mph > W.windStormMph then return S.windStorm, "storm" end
    if mph > W.windModerateMph then return S.windStrong, "strong" end
    if mph > W.windLightMph then return S.windLight, "light" end
    return S.windCalm, "calm"
end

local function rainMult(intensity)
    local W = Config.WEATHER
    local S = Config.SCATTER.weather
    if intensity >= W.rainHeavy then return S.rainHeavy, "heavy" end
    if intensity >= W.rainLight then return S.rainLight, "light" end
    return 1.0, "none"
end

local function fogMult(intensity)
    if intensity >= Config.WEATHER.fog then
        return Config.SCATTER.weather.fog, "foggy"
    end
    return 1.0, "clear"
end

--=======================================================================--
-- PUBLIC: COMBINED MULTIPLIER + BREAKDOWN
--=======================================================================--

-- Returns: combinedMultiplier (number), breakdown (table for UI/debug)
-- breakdown = { wind = {mph, mult, tier}, rain = {...}, fog = {...} }
function Weather.evaluate()
    local mph = Weather.windMph()
    local rain = Weather.rainIntensity()
    local fog = Weather.fogIntensity()

    local wM, wTier = windMult(mph)
    local rM, rTier = rainMult(rain)
    local fM, fTier = fogMult(fog)

    local combined = wM * rM * fM

    local breakdown = {
        wind = { mph = mph, mult = wM, tier = wTier },
        rain = { intensity = rain, mult = rM, tier = rTier },
        fog  = { intensity = fog, mult = fM, tier = fTier },
        combined = combined,
    }
    return combined, breakdown
end

-- Convenience: just the multiplier.
function Weather.multiplier()
    local m = Weather.evaluate()
    return m
end

return Weather
