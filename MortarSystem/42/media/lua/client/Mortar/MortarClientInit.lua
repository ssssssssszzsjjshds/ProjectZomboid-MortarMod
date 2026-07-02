--***********************************************************************--
-- Mortar System  -  MortarClientInit.lua   (CLIENT)
--
-- PURPOSE
--   Client-side wiring that ties the network replies back into the UI and debug
--   overlay. The authority sends a "fireResult" after each shot; we route it to
--   the firing HUD (status + re-enable) and to the debug overlay (impact marker).
--
-- DATA FLOW
--   Depends on Network (handler registration), the UI module, and Debug. Loaded
--   on clients (and SP). Keep this the single client entry point so load order
--   and registration are obvious.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarNetwork"
require "Mortar/UI/MortarFireUI"
require "Mortar/MortarDebug"

local Net = MortarMod.Network
local Log = MortarMod.Log

if not MortarMod._clientWired then
    MortarMod._clientWired = true

    -- Authority -> client: outcome of a fire request.
    Net.registerClientHandler("fireResult", function(result)
        if MortarMod.UI and MortarMod.UI.onFireResult then
            MortarMod.UI.onFireResult(result)
        end
        if MortarMod.Debug and MortarMod.Debug.onFireResult then
            MortarMod.Debug.onFireResult(result)
        end
    end)

    Log.debug("Mortar client wiring complete.")
end
