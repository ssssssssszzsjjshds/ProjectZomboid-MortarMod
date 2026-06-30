--***********************************************************************--
-- Mortar System  -  MortarPending.lua   (SERVER / authority)
--
-- PURPOSE
--   Because B42 cannot force-load off-screen terrain, a round that lands on an
--   unloaded chunk has its physical blast DEFERRED here until that terrain
--   streams in. The huge zombie-attracting noise already fired at launch (it is
--   coordinate-based); only the on-tile damage/fire waits.
--
-- MECHANISM
--   * Pending detonations are persisted in global ModData (survive save/load).
--   * Events.LoadGridsquare fires the matching detonation the instant its tile
--     streams in; EveryOneMinute also polls (belt-and-braces) and expires stale
--     records past Config.CHUNK.deferTtlMinutes.
--   * Detonation is delegated to MortarFire.detonateAt (resolved at call time to
--     avoid a require cycle).
--
-- DATA FLOW
--   Depends on Config, Log, Utils, Chunk. Written by MortarFire when an impact
--   area is not loaded.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarUtils"
require "Mortar/MortarChunk"

-- Defensive global setup: ensure MortarMod and MortarMod.Pending are tables.
if type(MortarMod) ~= "table" then MortarMod = {} end
if type(MortarMod.Pending) ~= "table" then MortarMod.Pending = {} end

local Pending = MortarMod.Pending

-- Safe references to optional submodules. These may be nil if their require failed;
-- callers must guard before calling functions on them.
local Config = (type(MortarMod.Config) == "table") and MortarMod.Config or nil
local Log    = (type(MortarMod.Log) == "table") and MortarMod.Log or nil
local Utils  = (type(MortarMod.Utils) == "table") and MortarMod.Utils or nil
local Chunk  = (type(MortarMod.Chunk) == "table") and MortarMod.Chunk or nil

-- Provide minimal fallbacks if Config/Log are absent so the file doesn't error.
if not Config then
    Config = {
        MODULE = "MortarSystem",
        CHUNK = { deferTtlMinutes = 20 }
    }
    MortarMod.Config = Config
end

-- Minimal Log fallback that prints to console so we always have logging functions.
if not Log then
    Log = {
        info = function(...) print("[MortarMod][INFO]", ...) end,
        warn = function(...) print("[MortarMod][WARN]", ...) end,
        debug = function(...) print("[MortarMod][DEBUG]", ...) end,
    }
    MortarMod.Log = Log
end

local STORE_KEY = tostring(Config.MODULE) .. "_Pending"
Pending._nextId = (type(Pending._nextId) == "number") and Pending._nextId or 1

-- Helper: get (or create) persistent store
function Pending.store()
    if ModData and ModData.getOrCreate then
        local ok, t = pcall(function() return ModData.getOrCreate(STORE_KEY) end)
        if ok and type(t) == "table" then
            if type(t.records) ~= "table" then t.records = {} end
        if ok and type(t) == "table" then
            if type(t.records) ~= "table" then t.records = {} end
            return t
        end
    end
    Pending._fallback = Pending._fallback or { records = {} }
    return Pending._fallback
end

-- Helper: transmit persistent data (no-op if ModData.transmit missing)
local function transmit()
    if ModData and ModData.transmit then
        pcall(function() ModData.transmit(STORE_KEY) end)
    end
end

-- Resolve the detonation entry point lazily (avoids a Fire<->Pending cycle).
local function detonate(record)
    local Fire = MortarMod.Fire
    if not Fire or type(Fire.detonateAt) ~= "function" then
        Log.warn("Pending: MortarFire.detonateAt unavailable.")
        return { detonated = false }
    end
    -- Call detonateAt and protect with pcall just in case
    local ok, res = pcall(function()
        return Fire.detonateAt(record.shellKey, record.x, record.y, record.z,
            record.intendedX, record.intendedY, nil)
    end)
    if not ok then
        Log.warn("Pending.detonate: MortarFire.detonateAt call failed:", res)
        return { detonated = false }
    end
    return res or { detonated = false }
end

-- Queue a deferred detonation.
function Pending.add(record)
    if type(record) ~= "table" then
        Log.warn("Pending.add called with non-table record; ignoring.")
        return
    end

    if not Pending._nextId or type(Pending._nextId) ~= "number" then
        Log.warn("Pending._nextId invalid; ignoring record.")
        return
    end

    if not Pending._nextId or type(Pending._nextId) ~= "number" then
        Log.warn("Pending._nextId invalid; ignoring record.")
        return
    end

    record.id = Pending._nextId
    Pending._nextId = Pending._nextId + 1

    -- Guard Utils.gameMinutes; if missing, use a safe fallback of 0 and log.
    local gm = 0
    if Utils and type(Utils.gameMinutes) == "function" then
        local ok, val = pcall(Utils.gameMinutes)
        if ok and type(val) == "number" then
            gm = val
        else
            Log.warn("Pending.add: Utils.gameMinutes returned invalid value; using 0.")
        end
    else
        Log.warn("Pending.add: Utils.gameMinutes unavailable; using 0 as fallback.")
    end

    record.expiryMinutes = gm + (Config.CHUNK and Config.CHUNK.deferTtlMinutes or 20)
    Pending.store().records[tostring(record.id)] = record
    transmit()
    Log.info(string.format("Deferred detonation #%d at (%s,%s,%s) shell=%s.",
        record.id, tostring(record.x), tostring(record.y), tostring(record.z), tostring(record.shellKey)))
end

-- Attempt one record now: detonate if its terrain is loaded; returns true if
-- the record was consumed (detonated or expired).
local function resolveRecord(id, record, now)
    if now >= (record.expiryMinutes or 0) then
        Log.debug(string.format("Pending #%s expired without loading.", tostring(id)))
        return true
    end

    if not Chunk or type(Chunk.isLoaded) ~= "function" then
        Log.warn("Pending: Chunk.isLoaded unavailable; cannot resolve record #%s now.", tostring(id))
        return false
    end

    local ok, loaded = pcall(function() return Chunk.isLoaded(record.x, record.y, record.z) end)
    if not ok or type(loaded) ~= "boolean" then
        Log.warn("Pending: Chunk.isLoaded call failed or returned non-boolean for #%s.", tostring(id))
    if not ok or type(loaded) ~= "boolean" then
        Log.warn("Pending: Chunk.isLoaded call failed or returned non-boolean for #%s.", tostring(id))
        return false
    end

    if loaded then
        local res = detonate(record)
        if type(res) ~= "table" or type(res.needsSquare) ~= "boolean" then
            res = { needsSquare = false }
        end
        if res.needsSquare then
        if type(res) ~= "table" or type(res.needsSquare) ~= "boolean" then
            res = { needsSquare = false }
        end
        if res.needsSquare then
            return false   -- chunk reported loaded but square still not ready; retry
        end
        Log.info(string.format("Deferred detonation #%s fired on load.", tostring(id)))
        return true
    end
    return false
end

-- Called when any grid square streams in.
function Pending.onLoadSquare(square)
    if not square then return end
    local store = Pending.store()
    if type(store) ~= "table" or type(store.records) ~= "table" then return end
    if type(store) ~= "table" or type(store.records) ~= "table" then return end

    -- Guard Utils.gameMinutes
    if not Utils or type(Utils.gameMinutes) ~= "function" then
        Log.warn("Pending.onLoadSquare: Utils.gameMinutes unavailable; skipping resolution.")
        return
    end

    local ok, now = pcall(Utils.gameMinutes)
    if not ok or type(now) ~= "number" then
        Log.warn("Pending.onLoadSquare: Utils.gameMinutes failed; skipping resolution.")
        return
    end

    local x, y, z = square:getX(), square:getY(), square:getZ()
    local consumed = {}
    for id, rec in pairs(store.records) do
        if rec and rec.x == x and rec.y == y and rec.z == z then
            if resolveRecord(id, rec, now) then consumed[#consumed + 1] = id end
        end
    end
    for _, id in ipairs(consumed) do store.records[tostring(id)] = nil end
    if #consumed > 0 then transmit() end
end

-- Periodic poll + expiry.
function Pending.tick()
    local store = Pending.store()
    if type(store) ~= "table" or type(store.records) ~= "table" then return end
    if type(store) ~= "table" or type(store.records) ~= "table" then return end

    if not Utils or type(Utils.gameMinutes) ~= "function" then
        Log.warn("Pending.tick: Utils.gameMinutes unavailable; skipping tick.")
        return
    end

    local ok, now = pcall(Utils.gameMinutes)
    if not ok or type(now) ~= "number" then
        Log.warn("Pending.tick: Utils.gameMinutes failed; skipping tick.")
        return
    end

    local consumed = {}
    for id, rec in pairs(store.records) do
        if resolveRecord(id, rec, now) then consumed[#consumed + 1] = id end
    end
    for _, id in ipairs(consumed) do store.records[tostring(id)] = nil end
    if #consumed > 0 then transmit() end
end

-- Wiring: register event handlers only if running as authority and Events exist.
if not Pending._wired then
    Pending._wired = true

    local isAuth = false
    if Utils and type(Utils.isAuthority) == "function" then
        local ok, val = pcall(Utils.isAuthority)
        if ok and val then isAuth = true end
    else
        -- If Utils missing, we cannot determine authority; assume client and avoid wiring server-only events.
        Log.debug("Pending: Utils.isAuthority unavailable; skipping server-only event wiring.")
    end

    if isAuth then
        if Events and Events.LoadGridsquare and type(Events.LoadGridsquare.Add) == "function" then
            Events.LoadGridsquare.Add(function(sq) Pending.onLoadSquare(sq) end)
        else
            Log.warn("Pending: Events.LoadGridsquare not available; deferred detonations may not fire on square load.")
        end
        if Events and Events.EveryOneMinute and type(Events.EveryOneMinute.Add) == "function" then
            Events.EveryOneMinute.Add(function() Pending.tick() end)
        else
            Log.warn("Pending: Events.EveryOneMinute not available; periodic expiry checks disabled.")
        end
    end
end

return Pending