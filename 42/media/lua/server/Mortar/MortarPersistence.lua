--***********************************************************************--
-- Mortar System  -  MortarPersistence.lua   (SERVER / authority)
--
-- PURPOSE
--   Track transient timed world effects (smoke clouds, illumination flares) so
--   they expire correctly AND survive a save/load. The deployed mortar itself
--   persists automatically via IsoObject modData; this module covers the
--   effects that have no backing IsoObject the engine would save for us.
--
-- DESIGN
--   * Effect *data* is stored in global ModData (saved + MP-synced).
--   * Effect *live handles* (IsoLightSource, spawned IsoObjects) live in a
--     runtime-only table and are recreated on load.
--   * Each effect "kind" registers two callbacks:
--       rehydrate(effect) -> liveHandle   (spawn the world side; may return nil
--                                           if its chunk isn't loaded yet)
--       cleanup(effect, liveHandle)        (despawn the world side)
--   => Adding a new persistent effect type = registerKind + addEffect.
--
-- DATA FLOW
--   Depends on Config, Log, Utils. Smoke + Illumination register kinds and add
--   effects. EveryOneMinute drives expiry + lazy rehydration of effects whose
--   chunks have since loaded.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarUtils"

MortarMod = MortarMod or {}
MortarMod.Persistence = MortarMod.Persistence or {}

local P = MortarMod.Persistence
local Config = MortarMod.Config
local Log = MortarMod.Log
local Utils = MortarMod.Utils

local STORE_KEY = Config.MODULE .. "_World"

-- Runtime-only: kind -> {rehydrate, cleanup} and effectId -> liveHandle.
P._kinds = P._kinds or {}
P._live  = P._live  or {}
P._nextId = P._nextId or 1

--=======================================================================--
-- PERSISTENT STORE
--=======================================================================--

-- Lazily get/create the global persisted table. Falls back to a plain table if
-- ModData is unavailable (very early load), so callers never crash.
function P.store()
    if ModData and ModData.getOrCreate then
        local ok, t = pcall(function() return ModData.getOrCreate(STORE_KEY) end)
        if ok and t then
            t.effects = t.effects or {}
            return t
        end
    end
    P._fallback = P._fallback or { effects = {} }
    return P._fallback
end

--=======================================================================--
-- KIND REGISTRATION
--=======================================================================--

-- Register handlers for an effect kind. handlers = { rehydrate=fn, cleanup=fn }.
function P.registerKind(kind, handlers)
    P._kinds[kind] = handlers
    Log.debug("Persistence: registered effect kind '%s'.", kind)
end

--=======================================================================--
-- EFFECT LIFECYCLE
--=======================================================================--

-- Add a timed effect. `effect` must contain at least:
--   kind            (string, a registered kind)
--   expiryMinutes   (game-minute at which it dies)
-- Plus any kind-specific fields (x, y, z, radius, ...). Returns the effect id.
function P.addEffect(effect)
    local store = P.store()
    effect.id = P._nextId
    P._nextId = P._nextId + 1
    store.effects[tostring(effect.id)] = effect

    -- Spawn the live side immediately.
    P.rehydrateOne(effect)
    P.transmit()
    Log.debug("Persistence: added effect #%d kind=%s expiry=%.0f.",
        effect.id, tostring(effect.kind), effect.expiryMinutes or -1)
    return effect.id
end

-- Spawn the live handle for one effect (if not already live and kind known).
function P.rehydrateOne(effect)
    if not effect then return end
    local id = tostring(effect.id)
    if P._live[id] ~= nil then return end            -- already live
    local handlers = P._kinds[effect.kind]
    if not handlers or not handlers.rehydrate then return end
    local ok, handle = Log.guard("rehydrate:" .. tostring(effect.kind),
        handlers.rehydrate, effect)
    if ok and handle ~= nil then
        P._live[id] = handle
    end
end

-- Despawn + forget one effect by id.
function P.removeEffect(id)
    id = tostring(id)
    local store = P.store()
    local effect = store.effects[id]
    if effect then
        local handlers = P._kinds[effect.kind]
        local handle = P._live[id]
        if handlers and handlers.cleanup then
            Log.guard("cleanup:" .. tostring(effect.kind),
                handlers.cleanup, effect, handle)
        end
        store.effects[id] = nil
    end
    P._live[id] = nil
end

--=======================================================================--
-- TICK: EXPIRY + LAZY REHYDRATION
--=======================================================================--

function P.tick()
    local store = P.store()
    local now = Utils.gameMinutes()
    local expired = {}
    for id, effect in pairs(store.effects) do
        if effect.expiryMinutes and now >= effect.expiryMinutes then
            expired[#expired + 1] = id
        else
            -- Effects whose chunk only just loaded get their live side now.
            if P._live[id] == nil then
                P.rehydrateOne(effect)
            else
                -- Allow kinds to animate/drift per minute if they want.
                local handlers = P._kinds[effect.kind]
                if handlers and handlers.onMinute then
                    Log.guard("onMinute:" .. tostring(effect.kind),
                        handlers.onMinute, effect, P._live[id], now)
                end
            end
        end
    end
    for _, id in ipairs(expired) do
        P.removeEffect(id)
    end
    if #expired > 0 then P.transmit() end
end

-- Rehydrate everything (called once on load).
function P.rehydrateAll()
    local store = P.store()
    for _, effect in pairs(store.effects) do
        P.rehydrateOne(effect)
    end
    Log.debug("Persistence: rehydrated %d effect(s) on load.", Utils.count(store.effects))
end

-- Push the global store to MP clients (no-op in SP).
function P.transmit()
    if ModData and ModData.transmit then
        pcall(function() ModData.transmit(STORE_KEY) end)
    end
end

--=======================================================================--
-- EVENT WIRING (authority only)
--=======================================================================--

if not P._wired then
    P._wired = true
    if Utils.isAuthority() then
        if Events and Events.EveryOneMinute then
            Events.EveryOneMinute.Add(function() P.tick() end)
        end
        -- Rehydrate after the world + global modData are ready.
        if Events and Events.OnGameStart then
            Events.OnGameStart.Add(function() P.rehydrateAll() end)
        end
    end
end

return P
