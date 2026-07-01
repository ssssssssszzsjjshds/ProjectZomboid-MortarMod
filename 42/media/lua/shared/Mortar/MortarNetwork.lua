--***********************************************************************--
-- Mortar System  -  MortarNetwork.lua
--
-- PURPOSE
--   The ONE place that knows about client/server message routing. Every other
--   system calls Network.toServer(...) / Network.toClient(...) and never touches
--   sendClientCommand / sendServerCommand directly. This is what makes the mod
--   "multiplayer-ready": in SP the calls dispatch locally; in MP they cross the
--   wire to the authoritative server and back.
--
-- ROUTING RULES
--   toServer(command, args)
--     * MP client  -> sendClientCommand (server runs the handler)
--     * SP / server -> run the server handler inline (this VM is authority)
--   toClient(player, command, args)
--     * server     -> sendServerCommand to that player
--     * SP         -> run the client handler inline
--   broadcast(command, args)
--     * server     -> sendServerCommand to all
--     * SP         -> run the client handler inline
--
-- PAYLOAD CONTRACT
--   `args` must be a plain table of primitives (numbers/strings/booleans/sub-
--   tables) -- never IsoObjects. Fire solutions are pure data by design.
--
-- DATA FLOW
--   Depends on Config, Log, Utils. The actual command handlers are registered
--   by server/MortarServer.lua (server side) and the client result handlers by
--   the client modules. Event wiring lives here, guarded so it is inert in SP.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarUtils"

MortarMod = MortarMod or {}
MortarMod.Network = MortarMod.Network or {}

local Net = MortarMod.Network
local Config = MortarMod.Config
local Log = MortarMod.Log
local Utils = MortarMod.Utils

local MODULE = Config.MODULE

-- Handler registries (idempotent across reloads).
Net._serverHandlers = Net._serverHandlers or {}
Net._clientHandlers = Net._clientHandlers or {}

--=======================================================================--
-- HANDLER REGISTRATION
--=======================================================================--

-- Register a server-side handler: fn(player, args).
function Net.registerServerHandler(command, fn)
    Net._serverHandlers[command] = fn
end

-- Register a client-side handler: fn(args).
function Net.registerClientHandler(command, fn)
    Net._clientHandlers[command] = fn
end

local function runServerHandler(command, player, args)
    local fn = Net._serverHandlers[command]
    if not fn then
        Log.warn("No server handler for command '%s'.", tostring(command))
        return
    end
    Log.guard("server:" .. tostring(command), fn, player, args)
end

local function runClientHandler(command, args)
    local fn = Net._clientHandlers[command]
    if not fn then
        Log.warn("No client handler for command '%s'.", tostring(command))
        return
    end
    Log.guard("client:" .. tostring(command), fn, args)
end

--=======================================================================--
-- OUTBOUND ROUTING
--=======================================================================--

-- Client -> authority. In SP/server, runs inline; on an MP client, sends.
function Net.toServer(command, args)
    if Utils.isMPClient() then
        local player = Utils.getPlayer()
        sendClientCommand(player, MODULE, command, args)
        Log.trace("toServer (net) '%s'.", command)
    else
        -- SP or server: this VM is the authority.
        runServerHandler(command, Utils.getPlayer(), args)
        Log.trace("toServer (local) '%s'.", command)
    end
end

-- Authority -> a specific client. In SP, runs the client handler inline.
function Net.toClient(player, command, args)
    if Utils.isServerSide() then
        sendServerCommand(player, MODULE, command, args)
        Log.trace("toClient (net) '%s'.", command)
    else
        runClientHandler(command, args)
        Log.trace("toClient (local) '%s'.", command)
    end
end

-- Authority -> all clients. In SP, runs the client handler inline.
function Net.broadcast(command, args)
    if Utils.isServerSide() then
        sendServerCommand(MODULE, command, args)
        Log.trace("broadcast (net) '%s'.", command)
    else
        runClientHandler(command, args)
        Log.trace("broadcast (local) '%s'.", command)
    end
end

--=======================================================================--
-- EVENT WIRING (inert where it can't fire)
--   OnClientCommand fires on the server; OnServerCommand fires on clients.
--   Registering both unconditionally is harmless: each only triggers in the
--   context where it is meaningful. SP relies on the inline dispatch above.
--=======================================================================--

local function onClientCommand(module, command, player, args)
    if module ~= MODULE then return end
    runServerHandler(command, player, args)
end

local function onServerCommand(module, command, args)
    if module ~= MODULE then return end
    runClientHandler(command, args)
end

-- Guard against double-registration on hot reload.
if not Net._eventsWired then
    Net._eventsWired = true
    if Events and Events.OnClientCommand then
        Events.OnClientCommand.Add(onClientCommand)
    end
    if Events and Events.OnServerCommand then
        Events.OnServerCommand.Add(onServerCommand)
    end
end

return Net
