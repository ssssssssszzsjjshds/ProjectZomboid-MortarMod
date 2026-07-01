--***********************************************************************--
-- Mortar System  -  MortarBootstrap.lua   (SHARED)
--
-- PURPOSE
--   One-time boot wiring shared by every VM (SP, MP client, MP server):
--     * Apply Sandbox overrides onto Config once the game (and SandboxVars) are
--       ready.
--     * Print the version banner.
--
--   Kept tiny and dependency-explicit so load order is deterministic. Each VM
--   runs this independently, which is correct: SandboxVars and Config live per
--   VM.
--
-- DATA FLOW
--   Depends on Config + Version. Wires OnGameStart (SandboxVars available) and
--   OnGameBoot (banner). Safe against double-registration on hot reload.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarVersion"

MortarMod = MortarMod or {}
MortarMod._bootstrap = MortarMod._bootstrap or {}

local Config = MortarMod.Config
local Version = MortarMod.Version

if not MortarMod._bootstrap.wired then
    MortarMod._bootstrap.wired = true

    if Events and Events.OnGameBoot then
        Events.OnGameBoot.Add(function()
            Version.banner()
        end)
    end

    -- SandboxVars are reliably populated by OnGameStart.
    if Events and Events.OnGameStart then
        Events.OnGameStart.Add(function()
            Config.refreshFromSandbox()
        end)
    end

    -- Also refresh when global mod data initialises (covers MP client join).
    if Events and Events.OnInitGlobalModData then
        Events.OnInitGlobalModData.Add(function()
            Config.refreshFromSandbox()
        end)
    end
end

return MortarMod._bootstrap
