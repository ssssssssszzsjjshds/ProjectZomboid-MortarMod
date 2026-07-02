--***********************************************************************--
-- Mortar System  -  MortarLogger.lua
--
-- PURPOSE
--   Lightweight levelled logger used across the whole mod. Wraps PZ's print()
--   with a consistent prefix, a level filter, and lazy formatting so DEBUG/TRACE
--   calls cost almost nothing when disabled.
--
-- USAGE
--   local Log = MortarMod.Log
--   Log.info("Deployed mortar at %d,%d", x, y)
--   Log.debug("scatter breakdown: %s", tostring(t))   -- only prints in DEBUG
--
-- EXTENSION POINTS
--   * Levels are ordered; raise/lower MortarMod.Config.LOG_LEVEL to filter.
--   * Redirect output by replacing Log._sink (defaults to print).
--
-- DATA FLOW
--   Depends only on MortarConfig (for the active level). Dependency-light so it
--   can be used during early load.
--***********************************************************************--

require "Mortar/MortarConfig"

MortarMod = MortarMod or {}
MortarMod.Log = MortarMod.Log or {}

local Log = MortarMod.Log
local Config = MortarMod.Config

-- Numeric severities; higher = more verbose.
local LEVELS = {
    ERROR = 1,
    WARN  = 2,
    INFO  = 3,
    DEBUG = 4,
    TRACE = 5,
}

local PREFIX = "[MortarSystem]"

-- Output sink (swap for testing or to route elsewhere).
Log._sink = function(line) print(line) end

-- Resolve the active numeric threshold from Config at call time so a runtime
-- debug toggle takes effect immediately.
local function activeThreshold()
    return LEVELS[Config.LOG_LEVEL] or LEVELS.INFO
end

-- Core emit. Formats only when the level passes the filter (cheap when off).
local function emit(levelName, levelNum, fmt, ...)
    if levelNum > activeThreshold() then return end
    local msg
    if select("#", ...) > 0 then
        -- Guard against malformed format strings so a bad log never crashes.
        local ok, formatted = pcall(string.format, fmt, ...)
        msg = ok and formatted or tostring(fmt)
    else
        msg = tostring(fmt)
    end
    Log._sink(string.format("%s [%s] %s", PREFIX, levelName, msg))
end

function Log.error(fmt, ...) emit("ERROR", LEVELS.ERROR, fmt, ...) end
function Log.warn (fmt, ...) emit("WARN",  LEVELS.WARN,  fmt, ...) end
function Log.info (fmt, ...) emit("INFO",  LEVELS.INFO,  fmt, ...) end
function Log.debug(fmt, ...) emit("DEBUG", LEVELS.DEBUG, fmt, ...) end
function Log.trace(fmt, ...) emit("TRACE", LEVELS.TRACE, fmt, ...) end

-- Convenience: run `fn` in a protected call, logging (not raising) on error.
-- Returns ok, result. Use to keep one failing subsystem from breaking a turn.
function Log.guard(context, fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        Log.error("guarded '%s' failed: %s", tostring(context), tostring(result))
    end
    return ok, result
end

return Log
