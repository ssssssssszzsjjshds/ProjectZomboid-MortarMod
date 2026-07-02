--***********************************************************************--
-- Mortar System  -  MortarDebug.lua   (CLIENT)
--
-- PURPOSE
--   Developer debugging tools (design "Debug Support"): a toggleable overlay
--   that draws the target tile, impact tile, the scatter circle, loaded-chunk
--   info, and a full calculation breakdown. All gated behind Config.DEBUG so it
--   ships dormant and adds ~zero cost when off.
--
-- DRAWING STRATEGY
--   * Tile markers use IsoGridSquare highlighting (robust, in-world).
--   * Numeric/diagnostic text is drawn in a screen-space overlay element.
--   Highlighted squares are tracked and cleared each frame so nothing lingers.
--
-- TOGGLE
--   Keybind (Config.KEYBINDS.toggleDebug) flips Config.DEBUG at runtime; the
--   Sandbox option sets the initial state.
--
-- DATA FLOW
--   Reads the live firing UI (MortarMod.UI.instance) for the current solution
--   and the last fire result. Depends on Config, Math, Scatter, Inventory.
--***********************************************************************--

require "ISUI/ISUIElement"
require "Mortar/MortarConfig"
require "Mortar/MortarUtils"
require "Mortar/MortarMath"
require "Mortar/MortarScatter"
require "Mortar/MortarInventory"

local Config = MortarMod.Config
local Mth = MortarMod.Math
local Scatter = MortarMod.Scatter
local Inv = MortarMod.Inventory
local Utils = MortarMod.Utils
local Log = MortarMod.Log

MortarMod = MortarMod or {}
MortarMod.Debug = MortarMod.Debug or {}
local Debug = MortarMod.Debug

Debug.lastResult = Debug.lastResult or nil
Debug._highlighted = Debug._highlighted or {}

function Debug.enabled() return Config.DEBUG == true end

function Debug.toggle()
    Config.DEBUG = not Config.DEBUG
    Config.LOG_LEVEL = Config.DEBUG and "TRACE" or "INFO"
    Log.info("Debug mode %s.", Config.DEBUG and "ON" or "OFF")
end

-- Store the latest authoritative fire reply for the overlay.
function Debug.onFireResult(result)
    Debug.lastResult = result
end

--=======================================================================--
-- TILE HIGHLIGHTING
--=======================================================================--

local function clearHighlights()
    for _, sq in ipairs(Debug._highlighted) do
        if sq.setHighlighted then
            pcall(function() sq:setHighlighted(false) end)
        end
    end
    Debug._highlighted = {}
end

local function highlightTile(x, y, z, r, g, b)
    local sq = Utils.getSquare(x, y, z)
    if not sq then return end
    if not sq.setHighlighted then return end
    pcall(function()
        sq:setHighlighted(true, false)
        if sq.setHighlightColor then sq:setHighlightColor(r, g, b, 0.55) end
    end)
    Debug._highlighted[#Debug._highlighted + 1] = sq
end

-- Highlight a ring of tiles approximating the scatter circle.
local function highlightCircle(cx, cy, z, radius)
    local steps = 24
    for i = 0, steps - 1 do
        local a = (i / steps) * math.pi * 2
        local x = Mth.round(cx + math.cos(a) * radius)
        local y = Mth.round(cy + math.sin(a) * radius)
        highlightTile(x, y, z, 0.95, 0.75, 0.2)
    end
end

--=======================================================================--
-- OVERLAY ELEMENT
--=======================================================================--

local DebugHUD = ISUIElement:derive("MortarDebugHUD")

function DebugHUD:new()
    local o = ISUIElement:new(8, 120, 360, 220)
    setmetatable(o, self)
    self.__index = self
    o.lines = {}
    return o
end

function DebugHUD:collect()
    local lines = { "== MORTAR DEBUG ==" }
    local ui = MortarMod.UI and MortarMod.UI.instance

    if ui then
        local ox, oy, oz = ui.mortar:getOriginCoords()
        local mult, tier = Inv.getToolMultiplier(ui.character)
        local radius, bd = Scatter.computeRadius({
            player = ui.character, chargeId = ui.chargeId, toolTier = tier,
            conditionFraction = ui.mortar:getConditionFraction(),
            spotterPlotTier = ui.spotterPlotTier,
            range = ui.range,
        })
        local tx, ty = Mth.projectBearing(ox, oy, ui.bearing, ui.range)
        tx, ty = Mth.round(tx), Mth.round(ty)

        lines[#lines+1] = string.format("origin (%d,%d,%d)", ox, oy, oz or 0)
        lines[#lines+1] = string.format("bearing %.0f  charge %d  range %d", ui.bearing, ui.chargeId, ui.range)
        lines[#lines+1] = string.format("target (%d,%d)", tx, ty)
        lines[#lines+1] = string.format("tool=%s  cond=%.0f%%", tostring(tier), ui.mortar:getConditionFraction()*100)
        lines[#lines+1] = string.format("scatter=%.2f tiles", radius)
        lines[#lines+1] = string.format("  base %.1f x tool %.2f x skill %.2f", bd.base, bd.toolMult, bd.skillMult)
        lines[#lines+1] = string.format("  x cond %.2f x moodle %.2f", bd.conditionMult, bd.moodleMult)
        lines[#lines+1] = string.format("  x weather %.2f x spot %.2f x glob %.2f", bd.weatherMult, bd.spotterMult, bd.globalScalar)

        -- Live markers.
        highlightTile(tx, ty, oz, 0.3, 0.8, 0.3)   -- target = green
        highlightCircle(tx, ty, oz, radius)         -- scatter ring = amber

        -- Loaded chunk count near player (SP only; Chunk is authority-side).
        if MortarMod.Chunk and MortarMod.Chunk.debugLoadedChunks then
            local p = Utils.getPlayer()
            if p then
                local list = MortarMod.Chunk.debugLoadedChunks(p:getX(), p:getY(), 3)
                lines[#lines+1] = string.format("loaded chunks ~%d (7x7 probe)", #list)
            end
        end
    else
        lines[#lines+1] = "(open the firing UI to see live targeting)"
    end

    local r = Debug.lastResult
    if r then
        if r.misfire then
            lines[#lines+1] = "last: MISFIRE"
        elseif r.impactX then
            lines[#lines+1] = string.format("last impact (%d,%d) spread=%.1f",
                r.impactX, r.impactY, r.scatterRadius or 0)
            highlightTile(r.impactX, r.impactY, r.impactZ, 0.9, 0.3, 0.25)  -- impact = red
        end
    end

    self.lines = lines
end

function DebugHUD:render()
    if not Debug.enabled() then
        if #Debug._highlighted > 0 then clearHighlights() end
        return
    end
    clearHighlights()
    self:collect()

    -- Backdrop.
    self:drawRect(0, 0, self.width, self.height, 0.7, 0, 0, 0)
    local y = 4
    for _, line in ipairs(self.lines) do
        self:drawText(line, 6, y, 0.85, 0.95, 0.7, 1, UIFont.Small)
        y = y + 16
    end
end

--=======================================================================--
-- WIRING
--=======================================================================--

local hud = nil

local function ensureHUD()
    if hud then return end
    hud = DebugHUD:new()
    hud:initialise()
    hud:addToUIManager()
end

local function onKey(key)
    if Config.KEYBINDS and getKeyName and getCore then
        -- Compare against the configured key name.
        local target = Keyboard and Keyboard["KEY_" .. tostring(Config.KEYBINDS.toggleDebug)]
        if target and key == target then
            Debug.toggle()
        end
    end
end

if not Debug._wired then
    Debug._wired = true
    if Events and Events.OnGameStart then
        Events.OnGameStart.Add(ensureHUD)
    end
    if Events and Events.OnKeyPressed then
        Events.OnKeyPressed.Add(onKey)
    end
end

return Debug
