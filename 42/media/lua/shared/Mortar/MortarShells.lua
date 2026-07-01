<<<<<<< HEAD
--***********************************************************************--
-- Mortar System  -  MortarShells.lua
--
-- PURPOSE
--   Central registry of shell *definitions* (pure data) and *effect handlers*
--   (behaviour). This is THE extension point promised by the design: adding a
--   new shell type is "register a definition" -- and reusing an existing effect
--   needs no new code at all.
--
-- TWO DECOUPLED REGISTRIES
--   1. Shell definitions  : data describing a round (item type, blast, etc.).
--   2. Effect handlers     : functions keyed by `effectType`. The HE / Smoke /
--                            Illumination systems register a handler under a
--                            string key; a shell definition just names the key.
--   => A new shell either reuses an effectType (data-only) or ships a new
--      handler + a data row. Nothing else in the firing pipeline changes.
--
-- HANDLER CONTRACT
--   registerEffect(effectType, fn)
--     fn(ctx) is invoked server-side (authority) at detonation time, where ctx =
--       {
--         shell    = <shell definition>,
--         x, y, z  = impact tile coordinates (integers),
--         square   = IsoGridSquare at impact (may be nil if unloadable),
--         player   = firing IsoPlayer (may be nil),
--         intended = { x=, y= } intended target tile (for telemetry),
--       }
--     fn returns a small result table {detonated=bool, note=string} for logging.
--
-- DATA FLOW
--   Depends on Config. Required by MortarInventory (counts), the firing UI
--   (selectable types), and MortarExplosion (dispatch). Effect handlers are
--   registered by the server-side effect modules at their load time.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"

MortarMod = MortarMod or {}
MortarMod.Shells = MortarMod.Shells or {}

local Shells = MortarMod.Shells
local Config = MortarMod.Config
local Log = MortarMod.Log

-- Internal storage (idempotent across reloads).
Shells._defs        = Shells._defs        or {}   -- key -> definition
Shells._order       = Shells._order       or {}   -- ordered list of keys
Shells._byItemType  = Shells._byItemType  or {}   -- itemType -> definition
Shells._effects     = Shells._effects     or {}   -- effectType -> handler fn

--=======================================================================--
-- DEFINITION REGISTRATION
--=======================================================================--

-- Register (or replace) a shell definition. `def` fields:
--   key            (string, required)  short id, e.g. "HE"
--   itemType       (string, required)  fully-qualified script item
--   order          (number)            UI sort order
--   nameKey        (string)            translation key for the UI label
--   effectType     (string, required)  which effect handler to run on impact
--   blastRadiusMin (number)            tiles (0 = no blast)
--   blastRadiusMax (number)
--   fireSpread     (bool)
--   fireChance     (number 0..1)       multiplier vs Config.EXPLOSION.baseFireChance
--   damagesCharacters (bool)
--   damagesStructures (bool)
--   selfHarmWarning   (bool)           UI hint that close shots endanger the crew
function Shells.register(def)
    assert(def and def.key,        "MortarShells.register: def.key required")
    assert(def.itemType,           "MortarShells.register: def.itemType required")
    assert(def.effectType,         "MortarShells.register: def.effectType required")

    if not Shells._defs[def.key] then
        table.insert(Shells._order, def.key)
    end
    Shells._defs[def.key] = def
    Shells._byItemType[def.itemType] = def
    Log.debug("Registered shell '%s' (item %s, effect %s).",
        def.key, def.itemType, def.effectType)
    return def
end

-- Lookup by short key (e.g. "HE").
function Shells.get(key)
    return Shells._defs[key]
end

-- Lookup by fully-qualified item type (e.g. "MortarSystem.Shell_HE_60").
function Shells.getByItemType(itemType)
    return Shells._byItemType[itemType]
end

-- Ordered list of all shell definitions (registration order, then `order`).
function Shells.all()
    local list = {}
    for _, key in ipairs(Shells._order) do
        list[#list + 1] = Shells._defs[key]
    end
    table.sort(list, function(a, b)
        return (a.order or 0) < (b.order or 0)
    end)
    return list
end

--=======================================================================--
-- EFFECT HANDLER REGISTRATION
--=======================================================================--

-- Register a detonation behaviour under an effectType key. Called by the
-- HE / Smoke / Illumination systems. Re-registration overrides (hot-reload OK).
function Shells.registerEffect(effectType, fn)
    assert(type(effectType) == "string", "effectType must be a string")
    assert(type(fn) == "function", "effect handler must be a function")
    Shells._effects[effectType] = fn
    Log.debug("Registered effect handler '%s'.", effectType)
end

-- Resolve a handler. Returns the fn or nil.
function Shells.getEffect(effectType)
    return Shells._effects[effectType]
end

--=======================================================================--
-- DEFAULT SHELL DEFINITIONS (data only -- handlers live in their systems)
--   Per design section 2.2 + 6.2. Tune freely; these are balance values and
--   intentionally centralised so a designer never edits behaviour code.
--=======================================================================--

Shells.register({
    key            = "HE",
    itemType       = Config.ITEMS.SHELL_HE,
    order          = 1,
    nameKey        = "IGUI_Mortar_Shell_HE",
    effectType     = "HE",
    blastRadiusMin = 10,
    blastRadiusMax = 10,
    fireSpread     = false,
    fireChance     = 0.0,
    damagesCharacters = true,
    damagesStructures = true,
    selfHarmWarning   = true,
    deferUntilLoaded  = true,
})

Shells.register({
    key            = "SMOKE",
    itemType       = Config.ITEMS.SHELL_SMOKE,
    order          = 2,
    nameKey        = "IGUI_Mortar_Shell_Smoke",
    effectType     = "SMOKE",
    blastRadiusMin = 0,
    blastRadiusMax = 0,
    fireSpread     = false,
    fireChance     = 0.0,
    damagesCharacters = false,
    damagesStructures = false,
    selfHarmWarning   = false,
})

Shells.register({
    key            = "ILLUM",
    itemType       = Config.ITEMS.SHELL_ILLUM,
    order          = 3,
    nameKey        = "IGUI_Mortar_Shell_Illum",
    effectType     = "ILLUM",
    blastRadiusMin = 0,
    blastRadiusMax = 0,
    fireSpread     = false,
    fireChance     = 0.0,
    damagesCharacters = false,
    damagesStructures = false,
    selfHarmWarning   = false,
})

return Shells
=======
--***********************************************************************--
-- Mortar System  -  MortarShells.lua
--
-- PURPOSE
--   Central registry of shell *definitions* (pure data) and *effect handlers*
--   (behaviour). This is THE extension point promised by the design: adding a
--   new shell type is "register a definition" -- and reusing an existing effect
--   needs no new code at all.
--
-- TWO DECOUPLED REGISTRIES
--   1. Shell definitions  : data describing a round (item type, blast, etc.).
--   2. Effect handlers     : functions keyed by `effectType`. The HE / Smoke /
--                            Illumination systems register a handler under a
--                            string key; a shell definition just names the key.
--   => A new shell either reuses an effectType (data-only) or ships a new
--      handler + a data row. Nothing else in the firing pipeline changes.
--
-- HANDLER CONTRACT
--   registerEffect(effectType, fn)
--     fn(ctx) is invoked server-side (authority) at detonation time, where ctx =
--       {
--         shell    = <shell definition>,
--         x, y, z  = impact tile coordinates (integers),
--         square   = IsoGridSquare at impact (may be nil if unloadable),
--         player   = firing IsoPlayer (may be nil),
--         intended = { x=, y= } intended target tile (for telemetry),
--       }
--     fn returns a small result table {detonated=bool, note=string} for logging.
--
-- DATA FLOW
--   Depends on Config. Required by MortarInventory (counts), the firing UI
--   (selectable types), and MortarExplosion (dispatch). Effect handlers are
--   registered by the server-side effect modules at their load time.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"

MortarMod = MortarMod or {}
MortarMod.Shells = MortarMod.Shells or {}

local Shells = MortarMod.Shells
local Config = MortarMod.Config
local Log = MortarMod.Log

-- Internal storage (idempotent across reloads).
Shells._defs        = Shells._defs        or {}   -- key -> definition
Shells._order       = Shells._order       or {}   -- ordered list of keys
Shells._byItemType  = Shells._byItemType  or {}   -- itemType -> definition
Shells._effects     = Shells._effects     or {}   -- effectType -> handler fn

--=======================================================================--
-- DEFINITION REGISTRATION
--=======================================================================--

-- Register (or replace) a shell definition. `def` fields:
--   key            (string, required)  short id, e.g. "HE"
--   itemType       (string, required)  fully-qualified script item
--   order          (number)            UI sort order
--   nameKey        (string)            translation key for the UI label
--   effectType     (string, required)  which effect handler to run on impact
--   blastRadiusMin (number)            tiles (0 = no blast)
--   blastRadiusMax (number)
--   fireSpread     (bool)
--   fireChance     (number 0..1)       multiplier vs Config.EXPLOSION.baseFireChance
--   damagesCharacters (bool)
--   damagesStructures (bool)
--   selfHarmWarning   (bool)           UI hint that close shots endanger the crew
function Shells.register(def)
    assert(def and def.key,        "MortarShells.register: def.key required")
    assert(def.itemType,           "MortarShells.register: def.itemType required")
    assert(def.effectType,         "MortarShells.register: def.effectType required")

    if not Shells._defs[def.key] then
        table.insert(Shells._order, def.key)
    end
    Shells._defs[def.key] = def
    Shells._byItemType[def.itemType] = def
    Log.debug("Registered shell '%s' (item %s, effect %s).",
        def.key, def.itemType, def.effectType)
    return def
end

-- Lookup by short key (e.g. "HE").
function Shells.get(key)
    return Shells._defs[key]
end

-- Lookup by fully-qualified item type (e.g. "MortarSystem.Shell_HE_60").
function Shells.getByItemType(itemType)
    return Shells._byItemType[itemType]
end

-- Ordered list of all shell definitions (registration order, then `order`).
function Shells.all()
    local list = {}
    for _, key in ipairs(Shells._order) do
        list[#list + 1] = Shells._defs[key]
    end
    table.sort(list, function(a, b)
        return (a.order or 0) < (b.order or 0)
    end)
    return list
end

--=======================================================================--
-- EFFECT HANDLER REGISTRATION
--=======================================================================--

-- Register a detonation behaviour under an effectType key. Called by the
-- HE / Smoke / Illumination systems. Re-registration overrides (hot-reload OK).
function Shells.registerEffect(effectType, fn)
    assert(type(effectType) == "string", "effectType must be a string")
    assert(type(fn) == "function", "effect handler must be a function")
    Shells._effects[effectType] = fn
    Log.debug("Registered effect handler '%s'.", effectType)
end

-- Resolve a handler. Returns the fn or nil.
function Shells.getEffect(effectType)
    return Shells._effects[effectType]
end

--=======================================================================--
-- DEFAULT SHELL DEFINITIONS (data only -- handlers live in their systems)
--   Per design section 2.2 + 6.2. Tune freely; these are balance values and
--   intentionally centralised so a designer never edits behaviour code.
--=======================================================================--

Shells.register({
    key            = "HE",
    itemType       = Config.ITEMS.SHELL_HE,
    order          = 1,
    nameKey        = "IGUI_Mortar_Shell_HE",
    effectType     = "HE",
    blastRadiusMin = 10,
    blastRadiusMax = 10,
    fireSpread     = false,
    fireChance     = 0.0,
    damagesCharacters = true,
    damagesStructures = true,
    selfHarmWarning   = true,
    deferUntilLoaded  = true,
})

Shells.register({
    key            = "SMOKE",
    itemType       = Config.ITEMS.SHELL_SMOKE,
    order          = 2,
    nameKey        = "IGUI_Mortar_Shell_Smoke",
    effectType     = "SMOKE",
    blastRadiusMin = 0,
    blastRadiusMax = 0,
    fireSpread     = false,
    fireChance     = 0.0,
    damagesCharacters = false,
    damagesStructures = false,
    selfHarmWarning   = false,
})

Shells.register({
    key            = "ILLUM",
    itemType       = Config.ITEMS.SHELL_ILLUM,
    order          = 3,
    nameKey        = "IGUI_Mortar_Shell_Illum",
    effectType     = "ILLUM",
    blastRadiusMin = 0,
    blastRadiusMax = 0,
    fireSpread     = false,
    fireChance     = 0.0,
    damagesCharacters = false,
    damagesStructures = false,
    selfHarmWarning   = false,
})

return Shells
>>>>>>> adfaaa6 (minimal working version)
