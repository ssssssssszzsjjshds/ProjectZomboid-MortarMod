--***********************************************************************--
-- Mortar System  -  MortarServer.lua   (SERVER / authority)
--
-- PURPOSE
--   Register the authoritative command handlers with the network layer. This is
--   the server-side entry point for everything a client can request. Today that
--   is a single command -- "fire" -- but the registry pattern scales to future
--   server-validated actions (e.g. server-authoritative deploy in a hardened MP
--   pass).
--
-- WHY DEPLOY/BREAKDOWN AREN'T HERE
--   Setup/breakdown run as client timed actions that create/remove the world
--   IsoObject and transmit it -- the standard, MP-safe placement path. Only the
--   explosion path must be server-authoritative (design 9.4), so only "fire" is
--   routed through here.
--
-- DATA FLOW
--   Depends on Network + Fire. Loaded on the authority (server in MP, local in
--   SP). Registered handlers receive (player, args).
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarNetwork"
require "Mortar/MortarFire"

MortarMod = MortarMod or {}
MortarMod.Server = MortarMod.Server or {}

local Server = MortarMod.Server
local Log = MortarMod.Log
local Net = MortarMod.Network
local Fire = MortarMod.Fire

--=======================================================================--
-- COMMAND: fire
--=======================================================================--

function Server.onFire(player, args)
    Log.debug("Server received fire request.")
    Fire.execute(player, args)
end

--=======================================================================--
-- REGISTRATION (idempotent)
--=======================================================================--

if not Server._wired then
    Server._wired = true
    Net.registerServerHandler("fire", Server.onFire)
    Log.debug("MortarServer handlers registered.")
end

return Server
