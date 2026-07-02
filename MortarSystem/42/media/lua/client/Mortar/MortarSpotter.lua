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
-- RENDERING
--   B42 has no ISUIElement line primitive, so the plot line is rasterised as a
--   run of small quads of a solid red mod texture (media/textures/
--   mortar_plotline.png) via drawTextureScaled, which exists in every build.
--   Endpoints are kept in WORLD coordinates and converted to UI space every
--   frame through the map API, so the line tracks pan/zoom. Drawing happens in
--   render() (after the map content paints), never in prerender().
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
-- survives map close/reopen. Endpoints are WORLD tile coordinates.
Spotter._plotting = false
Spotter._observer = nil
Spotter._plotTarget = nil
Spotter._lineLabel = nil
Spotter._warnedOnce = {}
Spotter._renderDisabled = false

--=======================================================================--
-- LINE STYLE
--=======================================================================--

local LINE = {
    texture      = "media/textures/mortar_plotline.png",
    thickness    = 3,     -- line width in UI pixels
    maxQuads     = 400,   -- perf clamp for very long lines
    alpha        = 0.85,  -- plotted line
    previewAlpha = 0.55,  -- rubber-band line while picking the target
    markerSize   = 9,     -- endpoint squares
}

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

-- Inverse of uiToWorld: world tile -> current UI pixel inside the map element.
-- Re-evaluated every frame so the plot line follows pan/zoom.
local function worldToUI(api, wx, wy)
    if not api then return nil end
    if type(api.worldToUIX) ~= "function" or type(api.worldToUIY) ~= "function" then
        return nil
    end
    local okx, ux = pcall(function() return api:worldToUIX(wx, wy) end)
    local oky, uy = pcall(function() return api:worldToUIY(wx, wy) end)
    if okx and oky and ux and uy then
        return ux, uy
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
    Spotter._observer = nil
    Spotter._plotTarget = nil
    Spotter._lineLabel = nil
    if Spotter._plotting then
        notify(player, tr("IGUI_Mortar_Spotter_PickObserver"))
    else
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

    local setting = Config.getCharge(solution.chargeId)
    notify(player, tr("IGUI_Mortar_Spotter_Solution",
        math.floor(solution.bearing), math.floor(solution.range),
        setting and setting.name or tostring(solution.chargeId)))
    Log.info("Spotter plotted: %s", Targeting.describe(solution))

    Spotter._plotTarget = { x = wx, y = wy }
    Spotter._lineLabel = tr("IGUI_Mortar_Spotter_LineLabel",
        math.floor(solution.bearing + 0.5), math.floor(solution.range + 0.5))
    Spotter._plotting = false
    return true
end

-- Clear the plot line and state (called when the firing UI consumes the
-- solution, or the user cancels / starts a new plot).
function Spotter.clearPlot()
    Spotter._plotting = false
    Spotter._observer = nil
    Spotter._plotTarget = nil
    Spotter._lineLabel = nil
end

--=======================================================================--
-- PLOT LINE RENDERING
--=======================================================================--

-- Resolve the line texture once. Primary: the mod's own solid red texture
-- (drawn untinted). Fallback: any vanilla white rect, tinted red.
local texResolved = false
local lineTex, tintR, tintG, tintB
local function resolveLineTexture()
    if texResolved then return lineTex end
    texResolved = true
    lineTex = getTexture(LINE.texture)
    tintR, tintG, tintB = 1.0, 1.0, 1.0
    if not lineTex then
        lineTex = getTexture("media/ui/WhiteRect.png")
            or getTexture("media/ui/Cross.png")
        tintR, tintG, tintB = 1.0, 0.25, 0.20
        if not Spotter._warnedOnce.texture then
            Spotter._warnedOnce.texture = true
            if lineTex then
                Log.warn("Spotter: %s missing; using tinted vanilla fallback.", LINE.texture)
            else
                Log.warn("Spotter: no usable line texture; plot line disabled.")
            end
        end
    end
    return lineTex
end

-- Rasterise a line segment as a run of small textured quads. drawTextureScaled
-- is the one draw call guaranteed across builds, so no native line API needed.
local function drawPlotLine(ui, tex, x1, y1, x2, y2, alpha)
    local t = LINE.thickness
    local half = t * 0.5
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then
        ui:drawTextureScaled(tex, x1 - half, y1 - half, t, t, alpha, tintR, tintG, tintB)
        return
    end
    local step = t * 0.6
    local quads = math.ceil(len / step)
    if quads > LINE.maxQuads then
        quads = LINE.maxQuads
        step = len / quads
    end
    local nx, ny = dx / len, dy / len
    for i = 0, quads do
        local px, py = x1 + nx * step * i, y1 + ny * step * i
        if i == quads then px, py = x2, y2 end
        ui:drawTextureScaled(tex, px - half, py - half, t, t, alpha, tintR, tintG, tintB)
    end
end

local function drawMarker(ui, tex, x, y)
    local s = LINE.markerSize
    ui:drawTextureScaled(tex, x - s * 0.5, y - s * 0.5, s, s, 1.0, tintR, tintG, tintB)
end

-- Bearing/range caption above the midpoint of the plotted line.
local function drawLineLabel(ui, x, y)
    if not Spotter._lineLabel then return end
    local font = UIFont and UIFont.Small
    if not font then return end
    local w = getTextManager():MeasureStringX(font, Spotter._lineLabel)
    local h = getTextManager():getFontHeight(font)
    local lx, ly = x - w * 0.5, y - h - 6
    ui:drawText(Spotter._lineLabel, lx + 1, ly + 1, 0, 0, 0, 0.8, font)
    ui:drawText(Spotter._lineLabel, lx, ly, 1.0, 0.85, 0.8, 1.0, font)
end

-- Per-frame plot drawing. Runs inside ISWorldMap:render (i.e. after the map
-- content has painted), with all endpoints converted world -> UI each frame.
local function renderPlot(map)
    local obs = Spotter._observer
    if not obs then return end
    local tex = resolveLineTexture()
    if not tex then return end
    local api = getMapAPI(map)
    local ox, oy = worldToUI(api, obs.x, obs.y)
    if not ox then
        if not Spotter._warnedOnce.worldToUI then
            Spotter._warnedOnce.worldToUI = true
            Log.warn("Spotter: world->UI conversion unavailable; plot line hidden.")
        end
        return
    end

    local tgt = Spotter._plotTarget
    if tgt then
        local tx, ty = worldToUI(api, tgt.x, tgt.y)
        if tx then
            drawPlotLine(map, tex, ox, oy, tx, ty, LINE.alpha)
            drawMarker(map, tex, tx, ty)
            drawLineLabel(map, (ox + tx) * 0.5, (oy + ty) * 0.5)
        end
    elseif Spotter._plotting then
        -- Observer picked, target pending: rubber-band line to the cursor.
        local mx, my = map:getMouseX(), map:getMouseY()
        if mx and my and mx >= 0 and my >= 0
                and mx <= map:getWidth() and my <= map:getHeight() then
            drawPlotLine(map, tex, ox, oy, mx, my, LINE.previewAlpha)
        end
    end
    drawMarker(map, tex, ox, oy)
end

--=======================================================================--
-- MAP UI INSTALLATION
--=======================================================================--

local function install()
    if not ISWorldMap then
        Log.debug("Spotter: ISWorldMap not present; map plotting unavailable.")
        return
    end
    if ISWorldMap._MortarSpotterInstalled then return end
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

    -- Capture clicks while plotting (onMouseUp only). Never return true —
    -- consuming the event prevents the map from releasing mouse capture.
    local origMouseUp = ISWorldMap.onMouseUp
    function ISWorldMap:onMouseUp(x, y)
        if Spotter._plotting then
            pcall(function() MortarMod.Spotter.handlePlotClick(self, x, y) end)
        end
        if origMouseUp then return origMouseUp(self, x, y) end
    end

    -- Plot line rendering. Hooked into render (NOT prerender) so the quads
    -- paint on top of the map content. If the map API drifts and drawing
    -- throws, disable it once and leave the rest of the mod working.
    local origRender = ISWorldMap.render
    function ISWorldMap:render(...)
        if origRender then origRender(self, ...) end
        if Spotter._renderDisabled then return end
        if not Spotter._observer then return end
        local ok, err = pcall(renderPlot, self)
        if not ok then
            Spotter._renderDisabled = true
            Log.warn("Spotter: plot line rendering disabled (%s).", tostring(err))
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
