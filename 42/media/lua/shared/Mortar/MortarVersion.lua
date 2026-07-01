--***********************************************************************--
-- Mortar System  -  MortarVersion.lua
--
-- PURPOSE
--   Records mod version + a compatibility banner printed once at boot, and a
--   place to perform save-data migrations between mod versions.
--
-- DATA FLOW
--   Pure metadata. Reads Config.VERSION. The migration table is keyed by the
--   stored modData version so persisted mortars created by older versions can
--   be upgraded in-place (see MortarObject.normalize).
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"

MortarMod = MortarMod or {}
MortarMod.Version = MortarMod.Version or {}

local V = MortarMod.Version
local Config = MortarMod.Config
local Log = MortarMod.Log

V.STRING = Config.VERSION

-- The schema version stamped into persisted mortar modData. Bump this whenever
-- the persisted shape changes, and add a migration step below.
V.DATA_SCHEMA = 1

-- Ordered list of migration steps. Each entry upgrades data FROM `from` TO
-- `from + 1`. MortarObject.normalize() applies them in sequence.
-- migrate(data) mutates `data` in place.
V.migrations = {
    -- Example for the future:
    -- [1] = function(data) data.newField = data.newField or defaultValue end,
}

-- Print a one-time boot banner (wired from a boot event in MortarClientInit /
-- server bootstrap). Harmless if called more than once.
local printed = false
function V.banner()
    if printed then return end
    printed = true
    Log.info("Mortar System v%s loaded (data schema v%d).", V.STRING, V.DATA_SCHEMA)
end

return V
