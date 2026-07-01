--***********************************************************************--
-- Mortar System  -  MortarSpotter.lua   (CLIENT)
--
-- PURPOSE
--   The map "plotting device" front-end for the targeting abstraction.
--   Adds a "Plot Fire Mission" button to the in-game world map; the player
--   then clicks two points and the device computes distance + bearing between
--   them and stores a pending fire solution that the firing UI can consume
--   ("Use Plotted Solution").
--
--   The IMPORTANT part -- the neutral fire-solution pipeline -- lives in
--   MortarTargeting and is rock-solid. THIS module is only the (inherently
--   version-sensitive) map UI glue, so it is written to degrade gracefully: if
--   B42's map internals differ from what we detect, it logs once and disables
--   itself, leaving the rest of the mod fully functional.
--
-- DATA FLOW
--   Depends on Config, Utils, Inventory (tool tier), Targeting (store solution).
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarUtils"
require "Mortar/MortarInventory"
require "Mortar/MortarTargeting"

local Config = MortarMod.Config
local Log = MortarMod.Log
local Utils = MortarMod.Utils
local Inv = MortarMod.Inventory
local Targeting = MortarMod.Targeting

MortarMod = MortarMod or {}
MortarMod.Spotter = MortarMod.Spotter or {}
local Spotter = MortarMod.Spotter

-- Plotting state stored in the module, not on the map instance, so it
-- survives map close/reopen.
Spotter._plotting = false
Spotter._observer = nil
Spotter._plotTarget = nil
Spotter._warnedOnce = {}

local function tr(key, ...)
    if not getText then return key end
    if select("#", ...) > 0 then
        local ok, s = pcall(string.format, getText(key), ...)
        return ok and s or getText(key)
    end
    return getText(key)
end

-- Soft player notification (halo note -> say -> log).
local function notify(player, text)
    if not player then Log.info("%s", text) return end
    if player.setHaloNote then pcall(function() player:setHaloNote(text) end) end
end

--=======================================================================--
-- MAP API RESOLUTION (defensive)
--=======================================================================--

-- Resolve the coordinate API for a map instance across possible shapes.
-- Dynamically probes any available getAPI* method for future-proofing.
local function getMapAPI(map)
    if not map then return nil end
    if map.mapAPI then return map.mapAPI end
    if map.javaObject then
        for idx = 0, 9 do
            local name = "getAPIv" .. tostring(idx)
            if type(map.javaObject[name]) == "function" then
                local ok, api = pcall(map.javaObject[name], map.javaObject)
                if ok and api then return api end
            end
        end
    end
    if type(map.getAPIv3) == "function" then
        local ok, api = pcall(map.getAPIv3, map)
        if ok and api then return api end
    end
    return nil
end

-- Convert a local UI click to world tile coords using the map API.
<<<<<<< HEAD
-- Uses a Lua closure wrapper for reliable Java interop in pcall.
=======
-- x,y from onMouseDown/onMouseUp are widget-relative; uiToWorldX/Y expects
-- the same coordinate space — pass them through without adjustment.
>>>>>>> adfaaa6 (minimal working version)
local function uiToWorld(api, x, y)
    if not api then return nil end
    if type(api.uiToWorldX) ~= "function" or type(api.uiToWorldY) ~= "function" then
        return nil
    end
    local okx, wx = pcall(function() return api:uiToWorldX(x, y) end)
    local oky, wy = pcall(function() return api:uiToWorldY(x, y) end)
    if okx and oky and wx and wy then
        return math.floor(wx), math.floor(wy)
    end
    return nil
end

--=======================================================================--
-- PLOTTING FLOW
--=======================================================================--

local function mapPlayer(map)
    return (map and map.character) or Utils.getPlayer()
end

function Spotter.isPlotting()
    return Spotter._plotting
end

-- Toggle plotting mode.
function Spotter.togglePlot(map)
    local player = mapPlayer(map)
    local tier = Inv.getToolTier(player)
    Log.info("Spotter: togglePlot tier=%s plotting=%s", tostring(tier), tostring(Spotter._plotting))
    if tier == "NONE" then
        notify(player, tr("IGUI_Mortar_Spotter_NeedTool"))
        return
    end
    Spotter._plotting = not Spotter._plotting
    if Spotter._plotting then
        Spotter._observer = nil
        Spotter._plotTarget = nil
        notify(player, tr("IGUI_Mortar_Spotter_PickObserver"))
    else
        Spotter._observer = nil
        Spotter._plotTarget = nil
        notify(player, tr("IGUI_Mortar_Spotter_Cleared"))
    end
end

-- Handle a click while plotting. Returns true if the click was consumed.
function Spotter.handlePlotClick(map, x, y)
    if not Spotter._plotting then return false end
    Log.info("Spotter: handlePlotClick (%d,%d) plotting=%s", x, y, tostring(Spotter._plotting))
    local api = getMapAPI(map)
    local wx, wy = uiToWorld(api, x, y)
    if not wx then
        if not Spotter._warnedOnce.coords then
            Spotter._warnedOnce.coords = true
            Log.warn("Spotter: could not convert click to world coords.")
        end
        return false
    end
    local player = mapPlayer(map)

    if not Spotter._observer then
        -- First click: the observer / mortar position.
        Spotter._observer = { x = wx, y = wy }
        notify(player, tr("IGUI_Mortar_Spotter_PickTarget"))
        return true
    end

    -- Second click: the target. Compute the mission and store it.
    local obs = Spotter._observer
    local tier = Inv.getToolTier(player)
    local z = player and player:getZ() or 0
    local solution = Targeting.fromPoints(obs.x, obs.y, z, wx, wy, tier)
    if not solution then
        notify(player, tr("IGUI_Mortar_InvalidTarget"))
        return true
    end
    Targeting.setPendingSolution(player, solution)

    notify(player, tr("IGUI_Mortar_Spotter_Solution",
        math.floor(solution.bearing), math.floor(solution.range), solution.chargeId))
    Log.info("Spotter plotted: %s", Targeting.describe(solution))

    Spotter._plotTarget = { x = wx, y = wy }
    Spotter._plotting = false
    Spotter._observer = nil
    return true
end

-- Clear the plot state (called when the firing UI consumes the solution or
-- the user cancels).
function Spotter.clearPlot()
    Spotter._plotting = false
    Spotter._observer = nil
    Spotter._plotTarget = nil
end

--=======================================================================--
-- MAP UI INSTALLATION
--=======================================================================--

local function install()
    if ISWorldMap._MortarSpotterInstalled then return end
    if not ISWorldMap then
        Log.debug("Spotter: ISWorldMap not present; map plotting unavailable.")
        return
    end
    ISWorldMap._MortarSpotterInstalled = true

    -- Add the button once per map instance.
    local origCreate = ISWorldMap.createChildren
    function ISWorldMap:createChildren(...)
        if origCreate then origCreate(self, ...) end
        if self.mortarPlotButton then return end
        local ok = pcall(function()
            local by = (self.height or 600) - 30
            local function onPlotButton(target, button)
                Log.info("Spotter: plot button clicked.")
                MortarMod.Spotter.togglePlot(target)
            end
            local btn = ISButton:new(8, by, 150, 20,
                tr("IGUI_Mortar_Spotter_Plot"), self, onPlotButton)
            btn:initialise()
            btn:instantiate()
            self:addChild(btn)
            self.mortarPlotButton = btn
            Log.info("Spotter: button added at y=%d.", by)
        end)
        if not ok and not Spotter._warnedOnce.button then
            Spotter._warnedOnce.button = true
            Log.warn("Spotter: failed to add map button (pcall failed).")
        end
    end

<<<<<<< HEAD
    -- Capture clicks while plotting (onMouseUp only). Never return true —
    -- consuming the event prevents the map from releasing mouse capture.
    local origMouseUp = ISWorldMap.onMouseUp
    function ISWorldMap:onMouseUp(x, y)
        if Spotter._plotting then
            pcall(function() MortarMod.Spotter.handlePlotClick(self, x, y) end)
        end
        if origMouseUp then return origMouseUp(self, x, y) end
    end
=======
    -- Capture clicks while plotting. Try onMouseDown first (B42 often consumes
    -- mouse events before onMouseUp), then fall back to onMouseUp.
    local hooksTried = {}
    local function installClickHook(hookName)
        if hooksTried[hookName] then return end
        hooksTried[hookName] = true
        local orig = ISWorldMap[hookName]
        if type(orig) ~= "function" then return end
        ISWorldMap[hookName] = function(self, x, y)
            if Spotter._plotting then
                local mx, my = x, y
                if type(self.getMouseX) == "function" and type(self.getMouseY) == "function" then
                    mx, my = self:getMouseX(), self:getMouseY()
                end
                local consumed = false
                pcall(function() consumed = MortarMod.Spotter.handlePlotClick(self, mx, my) end)
                if consumed then return true end
            end
            if orig then return orig(self, x, y) end
        end
    end
    installClickHook("onMouseDown")
    installClickHook("onMouseUp")
>>>>>>> adfaaa6 (minimal working version)

    -- Plot line rendering (observer -> target).
    local origPrerender = ISWorldMap.prerender
    function ISWorldMap:prerender()
        if origPrerender then origPrerender(self) end
        if Spotter._observer and Spotter._plotTarget then
            local api = getMapAPI(self)
            if not api then return end
            local ox, oy, tx, ty
            if type(api.worldToUIX) == "function" and type(api.worldToUIY) == "function" then
                ox = api:worldToUIX(Spotter._observer.x, Spotter._observer.y)
                oy = api:worldToUIY(Spotter._observer.x, Spotter._observer.y)
                tx = api:worldToUIX(Spotter._plotTarget.x, Spotter._plotTarget.y)
                ty = api:worldToUIY(Spotter._plotTarget.x, Spotter._plotTarget.y)
<<<<<<< HEAD
            else
                -- Fallback: manually invert uiToWorldX/Y by sampling corners.
                local w = self.width or 600
                local h = self.height or 600
                local wx0 = api:uiToWorldX(0, 0)
                local wy0 = api:uiToWorldY(0, 0)
                local wx1 = api:uiToWorldX(w, h)
                local wy1 = api:uiToWorldY(w, h)
                local rwx = wx1 - wx0
                local rwy = wy1 - wy0
                if rwx ~= 0 and rwy ~= 0 then
                    ox = (Spotter._observer.x - wx0) / rwx * w
                    oy = (Spotter._observer.y - wy0) / rwy * h
                    tx = (Spotter._plotTarget.x - wx0) / rwx * w
                    ty = (Spotter._plotTarget.y - wy0) / rwy * h
                end
=======
>>>>>>> adfaaa6 (minimal working version)
            end
            if ox and oy and tx and ty then
                self:drawLine(ox, oy, tx, ty, 1.0, 0.3, 0.25, 0.8)
            end
        end
    end

    Log.info("Spotter: map plotting installed.")
end

if Config.SPOTTER.enabled and not Spotter._wired then
    Spotter._wired = true
    if Events and Events.OnGameStart then
        Events.OnGameStart.Add(install)
    else
        install()
    end
end

return Spotter
