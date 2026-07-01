<<<<<<< HEAD
--***********************************************************************--
-- Mortar System  -  MortarFireUI.lua   (CLIENT)
--
-- PURPOSE
--   The firing HUD (design 4). A compact lower-centre panel with three columns
--   -- Bearing | Charge/Range | Shell -- plus a Drop Round button, a live
--   scatter-spread estimate, tool-tier warnings, and a "use plotted solution"
--   button fed by the spotter/map system.
--
-- BEHAVIOUR
--   * Bearing: +-1 / +-10 steppers; also adopts the character's facing if the
--     player physically rotates (design 4.2).
--   * Charge: cycles charges; Range: fine steppers clamped to the charge band.
--     Numeric range is shown only with a proper plotting kit (design 4.6).
--   * Shell: cycles HE/Smoke/Illum with live inventory counts.
--   * Fire: builds a fire SOLUTION and runs MortarFireAction, which sends it to
--     the authority. The UI stays open for subsequent rounds (design 4.5).
--   * The authority replies via MortarMod.UI.onFireResult (status + re-enable).
--
-- DATA FLOW
--   Depends on Config, Inventory, Shells, Targeting, Scatter, the fire action,
--   Operate (teardown on close), and the theme. Holds no authority logic.
--***********************************************************************--

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "Mortar/MortarConfig"
require "Mortar/MortarMath"
require "Mortar/MortarUtils"
require "Mortar/MortarInventory"
require "Mortar/MortarShells"
require "Mortar/MortarTargeting"
require "Mortar/MortarScatter"
require "Mortar/MortarObject"
require "Mortar/MortarOperate"
require "Mortar/Actions/MortarFireAction"
require "Mortar/UI/MortarUITheme"

local Config = MortarMod.Config
local Inv = MortarMod.Inventory
local Shells = MortarMod.Shells
local Targeting = MortarMod.Targeting
local Scatter = MortarMod.Scatter
local Theme = MortarMod.UITheme
local Log = MortarMod.Log

MortarFireUI = ISPanel:derive("MortarFireUI")

-- Static controller / singleton access.
MortarMod.UI = MortarMod.UI or {}
local UI = MortarMod.UI

local FONT = UIFont and UIFont.Small or 1

--=======================================================================--
-- CONSTRUCTION
--=======================================================================--

function MortarFireUI:new(character, mortar)
    local w, h = 480, 232
    local x = getCore():getScreenWidth() / 2 - w / 2
    local y = getCore():getScreenHeight() - h - 60
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self

    o.character = character
    o.mortar = mortar
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.moveWithMouse = true

    -- Firing state.
    o.bearing = mortar:getBearing()
    o.chargeId = Targeting.bestChargeForRange((Config.CHARGES[1].minRange + Config.CHARGES[1].maxRange) / 2)
    local c0 = Config.getCharge(o.chargeId)
    o.range = math.floor((c0.minRange + c0.maxRange) / 2)
    o.shellIndex = 1
    o.spotterPlotTier = nil
    o.inFlight = false
    o.statusKey = nil
    o.statusColor = "textDim"

    -- Pick the first shell type the player actually has.
    local snap = Inv.shellSnapshot(character)
    for i, entry in ipairs(snap.list) do
        if entry.count > 0 then o.shellIndex = i break end
    end

    return o
end

--=======================================================================--
-- HELPERS
--=======================================================================--

-- Our translation strings use printf specifiers (%d/%s), so format them with
-- string.format rather than PZ's %1/%2 getText substitution.
local function tr(key, ...)
    if not getText then return key end
    if select("#", ...) > 0 then
        local ok, s = pcall(string.format, getText(key), ...)
        return ok and s or getText(key)
    end
    return getText(key)
end

function MortarFireUI:currentShell()
    local list = Shells.all()
    local def = list[self.shellIndex] or list[1]
    return def
end

function MortarFireUI:charBearing()
    -- Map the character's 8-way facing to a bearing (design 4.2 "aim by looking").
    local dir = self.character:getDir()
    local map = { N = 0, NE = 45, E = 90, SE = 135, S = 180, SW = 225, W = 270, NW = 315 }
    return map[tostring(dir)] or self.bearing
end

-- Mark that the player changed the solution by hand (drops spotter accuracy).
function MortarFireUI:manualEdit()
    self.spotterPlotTier = nil
end

--=======================================================================--
-- CONTROL MUTATORS
--=======================================================================--

function MortarFireUI:changeBearing(delta)
    self.bearing = MortarMod.Math.normalizeBearing(self.bearing + delta)
    self._lastCharBearing = self:charBearing()  -- don't immediately re-snap
    self:manualEdit()
end

function MortarFireUI:changeCharge(delta)
    local n = Config.chargeCount()
    local idx
    for i, c in ipairs(Config.CHARGES) do if c.id == self.chargeId then idx = i break end end
    idx = MortarMod.Math.clamp((idx or 1) + delta, 1, n)
    self.chargeId = Config.CHARGES[idx].id
    -- Clamp range into the new band (default toward its midpoint if outside).
    self.range = Targeting.clampRangeToCharge(self.range, self.chargeId)
    self:manualEdit()
end

function MortarFireUI:changeRange(delta)
    self.range = Targeting.clampRangeToCharge(self.range + delta, self.chargeId)
    self:manualEdit()
end

function MortarFireUI:cycleShell(delta)
    local n = #Shells.all()
    self.shellIndex = ((self.shellIndex - 1 + delta) % n) + 1
end

function MortarFireUI:useSpotter()
    local s = Targeting.getPendingSolution(self.character)
    if not s then self:setStatus("IGUI_Mortar_Spotter_None", "warn") return end
    -- Clear the map plot line and module state.
    if MortarMod.Spotter and MortarMod.Spotter.clearPlot then
        MortarMod.Spotter.clearPlot()
    end
    -- Recompute from THIS mortar's tube to the plotted target tile so the
    -- bearing/range are correct for the actual emplacement (the observer who
    -- plotted it may not have stood exactly on the mortar).
    local ox, oy, oz = self.mortar:getOriginCoords()
    local recomputed = Targeting.fromPoints(ox, oy, oz, s.targetX, s.targetY, s.spotterPlotTier)
    if not recomputed then
        self:setStatus("IGUI_Mortar_InvalidTarget", "warn")
        return
    end
    self.bearing = recomputed.bearing
    self.chargeId = recomputed.chargeId
    self.range = MortarMod.Math.round(recomputed.range)
    self.spotterPlotTier = s.spotterPlotTier
    self:setStatus("IGUI_Mortar_Spotter_Use", "good")
end

function MortarFireUI:setStatus(key, color)
    self.statusKey = key
    self.statusColor = color or "textDim"
end

--=======================================================================--
-- FIRE
--=======================================================================--

function MortarFireUI:onFire()
    if self.inFlight then return end

    -- Tool gate (design 4.6: no tools => cannot fire).
    local mult, tier = Inv.getToolMultiplier(self.character)
    if tier == "NONE" then
        self:setStatus("IGUI_Mortar_Warn_NoTools", "bad")
        return
    end

    local shell = self:currentShell()
    if Inv.count(self.character, shell.itemType) <= 0 then
        self:setStatus("IGUI_Mortar_Err_NoShell", "bad")
        return
    end

    local ox, oy, oz = self.mortar:getOriginCoords()
    local solution = Targeting.fromBearingRange(ox, oy, oz, self.bearing, self.range,
        self.chargeId, shell.key)
    solution.spotterPlotTier = self.spotterPlotTier

    local ok, reason = Targeting.validate(solution)
    if not ok then
        self:setStatus(reason, "bad")
        return
    end

    -- Queue the drop-round animation; it sends the request on completion.
    self.inFlight = true
    self:setStatus("IGUI_Mortar_Firing", "warn")
    ISTimedActionQueue.add(MortarFireAction:new(self.character, self.mortar, solution, {
        onCancel = function() self.inFlight = false self:setStatus(nil) end,
    }))
end

-- Called by the authority's reply (via the client command handler).
function MortarFireUI:onFireResult(result)
    self.inFlight = false
    if not result then return end
    if result.misfire then
        self:setStatus(result.reason or "IGUI_Mortar_Misfire", "bad")
    elseif result.ok then
        self.lastImpact = { x = result.impactX, y = result.impactY, z = result.impactZ }
        self:setStatus("IGUI_Mortar_Fired", "good")
    else
        self:setStatus(result.reason or "IGUI_Mortar_Err_NoSolution", "bad")
    end
end

--=======================================================================--
-- CLOSE
--=======================================================================--

function MortarFireUI:onClose()
    self:close()
end

function MortarFireUI:close()
    MortarMod.Operate.finish(self.character, self.mortar)
    self:removeFromUIManager()
    if UI.instance == self then UI.instance = nil end
end

-- Close on ESC.
function MortarFireUI:onKeyRelease(key)
    if key == Keyboard.KEY_ESCAPE then self:close() end
end

--=======================================================================--
-- CHILD WIDGETS
--=======================================================================--

local SMALL_BTN = { w = 30, h = 18 }

function MortarFireUI:addBtn(x, y, w, h, label, fn)
    local b = ISButton:new(x, y, w, h, label, self, fn)
    b.font = FONT
    b:initialise()
    b:instantiate()
    b.borderColor = { r = 0.5, g = 0.55, b = 0.4, a = 0.8 }
    self:addChild(b)
    return b
end

function MortarFireUI:createChildren()
    local W = self.width
    local sb = SMALL_BTN

    -- Close (top-right).
    self.btnClose = self:addBtn(W - 80, 6, 74, 18, tr("IGUI_Mortar_Close"),
        function(t) t:onClose() end)

    -- Column anchors.
    local colY = 70
    local bx, cx, sx = 14, 178, 338

    -- Bearing steppers.
    self:addBtn(bx,         colY, sb.w, sb.h, "-10", function(t) t:changeBearing(-10) end)
    self:addBtn(bx + 34,    colY, sb.w, sb.h, "-1",  function(t) t:changeBearing(-1) end)
    self:addBtn(bx + 80,    colY, sb.w, sb.h, "+1",  function(t) t:changeBearing(1) end)
    self:addBtn(bx + 114,   colY, sb.w, sb.h, "+10", function(t) t:changeBearing(10) end)

    -- Charge prev/next.
    self:addBtn(cx,         colY, sb.w, sb.h, "<", function(t) t:changeCharge(-1) end)
    self:addBtn(cx + 114,   colY, sb.w, sb.h, ">", function(t) t:changeCharge(1) end)

    -- Range steppers (row below charge).
    self:addBtn(cx,         colY + 30, sb.w, sb.h, "-5", function(t) t:changeRange(-5) end)
    self:addBtn(cx + 34,    colY + 30, sb.w, sb.h, "-1", function(t) t:changeRange(-1) end)
    self:addBtn(cx + 80,    colY + 30, sb.w, sb.h, "+1", function(t) t:changeRange(1) end)
    self:addBtn(cx + 114,   colY + 30, sb.w, sb.h, "+5", function(t) t:changeRange(5) end)

    -- Shell prev/next.
    self:addBtn(sx,         colY, sb.w, sb.h, "<", function(t) t:cycleShell(-1) end)
    self:addBtn(sx + 100,   colY, sb.w, sb.h, ">", function(t) t:cycleShell(1) end)

    -- Spotter (left of fire). Always present; warns if no mission plotted.
    self.btnSpotter = self:addBtn(14, self.height - 34, 150, 24,
        tr("IGUI_Mortar_Spotter_Use"), function(t) t:useSpotter() end)

    -- Fire (centre-bottom).
    self.btnFire = self:addBtn(W / 2 - 80, self.height - 34, 160, 26,
        tr("IGUI_Mortar_Fire"), function(t) t:onFire() end)
    self.btnFire.backgroundColor = { r = Theme.colors.fire[1], g = Theme.colors.fire[2],
        b = Theme.colors.fire[3], a = 1 }
end

--=======================================================================--
-- PER-FRAME STATE
--=======================================================================--

function MortarFireUI:update()
    -- Adopt physical rotation if the player turned the character.
    local cb = self:charBearing()
    if self._lastCharBearing ~= nil and math.abs(cb - self._lastCharBearing) > 0.5 then
        self.bearing = cb
        self:manualEdit()
    end
    self._lastCharBearing = cb

    -- Keep the operator facing the firing line.
    local vx, vy = MortarMod.Math.bearingToVector(self.bearing)
    local ox, oy = self.mortar:getOriginCoords()
    pcall(function() self.character:faceLocation(ox + vx * 3, oy + vy * 3) end)

    -- If the mortar is gone (broken down elsewhere) close the UI.
    if not self.mortar:getObject() then self:close() end

    -- Disable fire while a round is in flight or no shell of the selected type.
    if self.btnFire then
        local shell = self:currentShell()
        local haveShell = Inv.count(self.character, shell.itemType) > 0
        self.btnFire.enable = (not self.inFlight) and haveShell
    end
end

--=======================================================================--
-- RENDER
--=======================================================================--

function MortarFireUI:prerender()
    -- Panel background + border.
    self:drawRect(0, 0, self.width, self.height, Theme.colors.bg[4], Theme.c("bg"))
    self:drawRectBorder(0, 0, self.width, self.height, 1, Theme.c("border"))

    -- Cache live derived values for render().
    self._mult, self._tier = Inv.getToolMultiplier(self.character)
    self._preview = Scatter.computeRadius({
        player = self.character,
        chargeId = self.chargeId,
        toolTier = self._tier,
        conditionFraction = self.mortar:getConditionFraction(),
        spotterPlotTier = self.spotterPlotTier,
    })
end

function MortarFireUI:render()
    local W = self.width
    local function txt(s, x, y, cName)
        self:drawText(s, x, y, select(1, Theme.c(cName)), select(2, Theme.c(cName)),
            select(3, Theme.c(cName)), select(4, Theme.c(cName)), FONT)
    end

    -- Title + condition.
    txt(tr("IGUI_Mortar_Title"), 14, 6, "value")
    local frac = self.mortar:getConditionFraction()
    local cc = Theme.conditionColor(frac)
    self:drawText(tr("IGUI_Mortar_Condition", math.floor(frac * 100)), 14, 28,
        cc[1], cc[2], cc[3], cc[4], FONT)

    -- Column headers.
    local bx, cx, sx, hy = 14, 178, 338, 50
    txt(tr("IGUI_Mortar_Bearing"), bx, hy, "textDim")
    txt(tr("IGUI_Mortar_Charge") .. " / " .. tr("IGUI_Mortar_Range"), cx, hy, "textDim")
    txt(tr("IGUI_Mortar_Shell"), sx, hy, "textDim")

    -- Bearing value (big).
    txt(string.format("%03d", math.floor(self.bearing)) .. " " ..
        tr("IGUI_Mortar_BearingUnit"), bx, 92, "value")

    -- Charge value.
    local charge = Config.getCharge(self.chargeId)
    txt(charge and charge.name or "?", cx, 92, "value")

    -- Range value (numeric only with a proper kit; else "unknown").
    if Inv.tierShowsRange(self._tier) then
        txt(tr("IGUI_Mortar_RangeTiles", self.range), cx, 112, "value")
    else
        txt(tr("IGUI_Mortar_RangeUnknown"), cx, 112, "textDim")
    end

    -- Shell value + count.
    local shell = self:currentShell()
    local count = Inv.count(self.character, shell.itemType)
    local shellName = tr(shell.nameKey)
    local shellCol = count > 0 and "value" or "bad"
    txt(string.format("%s  x%d", shellName, count), sx, 92, shellCol)

    -- Tool tier + scatter spread estimate.
    local tierName = self._tier or "NONE"
    txt(tr("IGUI_Mortar_Tool") .. ": " .. tierName, bx, 134, "textDim")
    txt(tr("IGUI_Mortar_ScatterPreview", math.floor(self._preview + 0.5)), bx, 152, "warn")

    -- Tool warning, if any.
    local warnKey = Inv.tierWarningKey(self._tier)
    if self._tier == "NONE" then warnKey = "IGUI_Mortar_Warn_NoTools" end
    if warnKey then txt(tr(warnKey), cx, 134, "warn") end

    -- Status line.
    if self.statusKey then
        txt(tr(self.statusKey), 14, self.height - 56, self.statusColor)
    end

    -- Spotter availability hint.
    local hasMission = Targeting.getPendingSolution(self.character) ~= nil
    if self.btnSpotter then self.btnSpotter.enable = hasMission end
end

--=======================================================================--
-- STATIC CONTROLLER
--=======================================================================--

function UI.open(character, mortar)
    if UI.instance then UI.instance:close() end
    local panel = MortarFireUI:new(character, mortar)
    panel:initialise()
    panel:addToUIManager()
    panel:setVisible(true)
    UI.instance = panel
    Log.debug("Firing UI opened.")
    return panel
end

function UI.close()
    if UI.instance then UI.instance:close() end
end

-- Routed here by the client command handler on a fire reply.
function UI.onFireResult(result)
    if UI.instance then UI.instance:onFireResult(result) end
end

return MortarFireUI
=======
--***********************************************************************--
-- Mortar System  -  MortarFireUI.lua   (CLIENT)
--
-- PURPOSE
--   The firing HUD (design 4). A compact lower-centre panel with three columns
--   -- Bearing | Charge/Range | Shell -- plus a Drop Round button, a live
--   scatter-spread estimate, tool-tier warnings, and a "use plotted solution"
--   button fed by the spotter/map system.
--
-- BEHAVIOUR
--   * Bearing: +-1 / +-10 steppers; also adopts the character's facing if the
--     player physically rotates (design 4.2).
--   * Charge: cycles charges; Range: fine steppers clamped to the charge band.
--     Numeric range is shown only with a proper plotting kit (design 4.6).
--   * Shell: cycles HE/Smoke/Illum with live inventory counts.
--   * Fire: builds a fire SOLUTION and runs MortarFireAction, which sends it to
--     the authority. The UI stays open for subsequent rounds (design 4.5).
--   * The authority replies via MortarMod.UI.onFireResult (status + re-enable).
--
-- DATA FLOW
--   Depends on Config, Inventory, Shells, Targeting, Scatter, the fire action,
--   Operate (teardown on close), and the theme. Holds no authority logic.
--***********************************************************************--

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "Mortar/MortarConfig"
require "Mortar/MortarMath"
require "Mortar/MortarUtils"
require "Mortar/MortarInventory"
require "Mortar/MortarShells"
require "Mortar/MortarTargeting"
require "Mortar/MortarScatter"
require "Mortar/MortarObject"
require "Mortar/MortarOperate"
require "Mortar/Actions/MortarFireAction"
require "Mortar/UI/MortarUITheme"

local Config = MortarMod.Config
local Inv = MortarMod.Inventory
local Shells = MortarMod.Shells
local Targeting = MortarMod.Targeting
local Scatter = MortarMod.Scatter
local Theme = MortarMod.UITheme
local Log = MortarMod.Log

MortarFireUI = ISPanel:derive("MortarFireUI")

-- Static controller / singleton access.
MortarMod.UI = MortarMod.UI or {}
local UI = MortarMod.UI

local FONT = UIFont and UIFont.Small or 1

--=======================================================================--
-- CONSTRUCTION
--=======================================================================--

function MortarFireUI:new(character, mortar)
    local w, h = 480, 232
    local x = getCore():getScreenWidth() / 2 - w / 2
    local y = getCore():getScreenHeight() - h - 60
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self

    o.character = character
    o.mortar = mortar
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.moveWithMouse = true

    -- Firing state.
    o.bearing = mortar:getBearing()
    o.chargeId = Targeting.bestChargeForRange((Config.CHARGES[1].minRange + Config.CHARGES[1].maxRange) / 2)
    local c0 = Config.getCharge(o.chargeId)
    o.range = math.floor((c0.minRange + c0.maxRange) / 2)
    o.shellIndex = 1
    o.spotterPlotTier = nil
    o.inFlight = false
    o.statusKey = nil
    o.statusColor = "textDim"

    -- Pick the first shell type the player actually has.
    local snap = Inv.shellSnapshot(character)
    for i, entry in ipairs(snap.list) do
        if entry.count > 0 then o.shellIndex = i break end
    end

    return o
end

--=======================================================================--
-- HELPERS
--=======================================================================--

-- Our translation strings use printf specifiers (%d/%s), so format them with
-- string.format rather than PZ's %1/%2 getText substitution.
local function tr(key, ...)
    if not getText then return key end
    if select("#", ...) > 0 then
        local ok, s = pcall(string.format, getText(key), ...)
        return ok and s or getText(key)
    end
    return getText(key)
end

function MortarFireUI:currentShell()
    local list = Shells.all()
    local def = list[self.shellIndex] or list[1]
    return def
end

function MortarFireUI:charBearing()
    -- Map the character's 8-way facing to a bearing (design 4.2 "aim by looking").
    local dir = self.character:getDir()
    local map = { N = 0, NE = 45, E = 90, SE = 135, S = 180, SW = 225, W = 270, NW = 315 }
    return map[tostring(dir)] or self.bearing
end

-- Mark that the player changed the solution by hand (drops spotter accuracy).
function MortarFireUI:manualEdit()
    self.spotterPlotTier = nil
end

--=======================================================================--
-- CONTROL MUTATORS
--=======================================================================--

function MortarFireUI:changeBearing(delta)
    self.bearing = MortarMod.Math.normalizeBearing(self.bearing + delta)
    self._lastCharBearing = self:charBearing()  -- don't immediately re-snap
    self:manualEdit()
end

function MortarFireUI:changeCharge(delta)
    local n = Config.chargeCount()
    local idx
    for i, c in ipairs(Config.CHARGES) do if c.id == self.chargeId then idx = i break end end
    idx = MortarMod.Math.clamp((idx or 1) + delta, 1, n)
    self.chargeId = Config.CHARGES[idx].id
    -- Clamp range into the new band (default toward its midpoint if outside).
    self.range = Targeting.clampRangeToCharge(self.range, self.chargeId)
    self:manualEdit()
end

function MortarFireUI:changeRange(delta)
    self.range = Targeting.clampRangeToCharge(self.range + delta, self.chargeId)
    self:manualEdit()
end

function MortarFireUI:cycleShell(delta)
    local n = #Shells.all()
    self.shellIndex = ((self.shellIndex - 1 + delta) % n) + 1
end

function MortarFireUI:useSpotter()
    local s = Targeting.getPendingSolution(self.character)
    if not s then self:setStatus("IGUI_Mortar_Spotter_None", "warn") return end
    -- Clear the map plot line and module state.
    if MortarMod.Spotter and MortarMod.Spotter.clearPlot then
        MortarMod.Spotter.clearPlot()
    end
    -- Recompute from THIS mortar's tube to the plotted target tile so the
    -- bearing/range are correct for the actual emplacement (the observer who
    -- plotted it may not have stood exactly on the mortar).
    local ox, oy, oz = self.mortar:getOriginCoords()
    local recomputed = Targeting.fromPoints(ox, oy, oz, s.targetX, s.targetY, s.spotterPlotTier)
    if not recomputed then
        self:setStatus("IGUI_Mortar_InvalidTarget", "warn")
        return
    end
    self.bearing = recomputed.bearing
    self.chargeId = recomputed.chargeId
    self.range = MortarMod.Math.round(recomputed.range)
    self.spotterPlotTier = s.spotterPlotTier
    self:setStatus("IGUI_Mortar_Spotter_Use", "good")
end

function MortarFireUI:setStatus(key, color)
    self.statusKey = key
    self.statusColor = color or "textDim"
end

--=======================================================================--
-- FIRE
--=======================================================================--

function MortarFireUI:onFire()
    if self.inFlight then return end

    -- Tool gate (design 4.6: no tools => cannot fire).
    local mult, tier = Inv.getToolMultiplier(self.character)
    if tier == "NONE" then
        self:setStatus("IGUI_Mortar_Warn_NoTools", "bad")
        return
    end

    local shell = self:currentShell()
    if Inv.count(self.character, shell.itemType) <= 0 then
        self:setStatus("IGUI_Mortar_Err_NoShell", "bad")
        return
    end

    local ox, oy, oz = self.mortar:getOriginCoords()
    local solution = Targeting.fromBearingRange(ox, oy, oz, self.bearing, self.range,
        self.chargeId, shell.key)
    solution.spotterPlotTier = self.spotterPlotTier

    local ok, reason = Targeting.validate(solution)
    if not ok then
        self:setStatus(reason, "bad")
        return
    end

    -- Queue the drop-round animation; it sends the request on completion.
    self.inFlight = true
    self:setStatus("IGUI_Mortar_Firing", "warn")
    ISTimedActionQueue.add(MortarFireAction:new(self.character, self.mortar, solution, {
        onCancel = function() self.inFlight = false self:setStatus(nil) end,
    }))
end

-- Called by the authority's reply (via the client command handler).
function MortarFireUI:onFireResult(result)
    self.inFlight = false
    if not result then return end
    if result.misfire then
        self:setStatus(result.reason or "IGUI_Mortar_Misfire", "bad")
    elseif result.ok then
        self.lastImpact = { x = result.impactX, y = result.impactY, z = result.impactZ }
        self:setStatus("IGUI_Mortar_Fired", "good")
    else
        self:setStatus(result.reason or "IGUI_Mortar_Err_NoSolution", "bad")
    end
end

--=======================================================================--
-- CLOSE
--=======================================================================--

function MortarFireUI:onClose()
    self:close()
end

function MortarFireUI:close()
    MortarMod.Operate.finish(self.character, self.mortar)
    self:removeFromUIManager()
    if UI.instance == self then UI.instance = nil end
end

-- Close on ESC.
function MortarFireUI:onKeyRelease(key)
    if key == Keyboard.KEY_ESCAPE then self:close() end
end

--=======================================================================--
-- CHILD WIDGETS
--=======================================================================--

local SMALL_BTN = { w = 30, h = 18 }

function MortarFireUI:addBtn(x, y, w, h, label, fn)
    local b = ISButton:new(x, y, w, h, label, self, fn)
    b.font = FONT
    b:initialise()
    b:instantiate()
    b.borderColor = { r = 0.5, g = 0.55, b = 0.4, a = 0.8 }
    self:addChild(b)
    return b
end

function MortarFireUI:createChildren()
    local W = self.width
    local sb = SMALL_BTN

    -- Close (top-right).
    self.btnClose = self:addBtn(W - 80, 6, 74, 18, tr("IGUI_Mortar_Close"),
        function(t) t:onClose() end)

    -- Column anchors.
    local colY = 70
    local bx, cx, sx = 14, 178, 338

    -- Bearing steppers.
    self:addBtn(bx,         colY, sb.w, sb.h, "-10", function(t) t:changeBearing(-10) end)
    self:addBtn(bx + 34,    colY, sb.w, sb.h, "-1",  function(t) t:changeBearing(-1) end)
    self:addBtn(bx + 80,    colY, sb.w, sb.h, "+1",  function(t) t:changeBearing(1) end)
    self:addBtn(bx + 114,   colY, sb.w, sb.h, "+10", function(t) t:changeBearing(10) end)

    -- Charge prev/next.
    self:addBtn(cx,         colY, sb.w, sb.h, "<", function(t) t:changeCharge(-1) end)
    self:addBtn(cx + 114,   colY, sb.w, sb.h, ">", function(t) t:changeCharge(1) end)

    -- Range steppers (row below charge).
    self:addBtn(cx,         colY + 30, sb.w, sb.h, "-5", function(t) t:changeRange(-5) end)
    self:addBtn(cx + 34,    colY + 30, sb.w, sb.h, "-1", function(t) t:changeRange(-1) end)
    self:addBtn(cx + 80,    colY + 30, sb.w, sb.h, "+1", function(t) t:changeRange(1) end)
    self:addBtn(cx + 114,   colY + 30, sb.w, sb.h, "+5", function(t) t:changeRange(5) end)

    -- Shell prev/next.
    self:addBtn(sx,         colY, sb.w, sb.h, "<", function(t) t:cycleShell(-1) end)
    self:addBtn(sx + 100,   colY, sb.w, sb.h, ">", function(t) t:cycleShell(1) end)

    -- Spotter (left of fire). Always present; warns if no mission plotted.
    self.btnSpotter = self:addBtn(14, self.height - 34, 150, 24,
        tr("IGUI_Mortar_Spotter_Use"), function(t) t:useSpotter() end)

    -- Fire (centre-bottom).
    self.btnFire = self:addBtn(W / 2 - 80, self.height - 34, 160, 26,
        tr("IGUI_Mortar_Fire"), function(t) t:onFire() end)
    self.btnFire.backgroundColor = { r = Theme.colors.fire[1], g = Theme.colors.fire[2],
        b = Theme.colors.fire[3], a = 1 }
end

--=======================================================================--
-- PER-FRAME STATE
--=======================================================================--

function MortarFireUI:update()
    -- Adopt physical rotation if the player turned the character.
    local cb = self:charBearing()
    if self._lastCharBearing ~= nil and math.abs(cb - self._lastCharBearing) > 0.5 then
        self.bearing = cb
        self:manualEdit()
    end
    self._lastCharBearing = cb

    -- Keep the operator facing the firing line.
    local vx, vy = MortarMod.Math.bearingToVector(self.bearing)
    local ox, oy = self.mortar:getOriginCoords()
    pcall(function() self.character:faceLocation(ox + vx * 3, oy + vy * 3) end)

    -- If the mortar is gone (broken down elsewhere) close the UI.
    if not self.mortar:getObject() then self:close() end

    -- Disable fire while a round is in flight or no shell of the selected type.
    if self.btnFire then
        local shell = self:currentShell()
        local haveShell = Inv.count(self.character, shell.itemType) > 0
        self.btnFire.enable = (not self.inFlight) and haveShell
    end
end

--=======================================================================--
-- RENDER
--=======================================================================--

function MortarFireUI:prerender()
    -- Panel background + border.
    self:drawRect(0, 0, self.width, self.height, Theme.colors.bg[4], Theme.c("bg"))
    self:drawRectBorder(0, 0, self.width, self.height, 1, Theme.c("border"))

    -- Cache live derived values for render().
    self._mult, self._tier = Inv.getToolMultiplier(self.character)
    self._preview = Scatter.computeRadius({
        player = self.character,
        chargeId = self.chargeId,
        toolTier = self._tier,
        conditionFraction = self.mortar:getConditionFraction(),
        spotterPlotTier = self.spotterPlotTier,
    })
end

function MortarFireUI:render()
    local W = self.width
    local function txt(s, x, y, cName)
        self:drawText(s, x, y, select(1, Theme.c(cName)), select(2, Theme.c(cName)),
            select(3, Theme.c(cName)), select(4, Theme.c(cName)), FONT)
    end

    -- Title + condition.
    txt(tr("IGUI_Mortar_Title"), 14, 6, "value")
    local frac = self.mortar:getConditionFraction()
    local cc = Theme.conditionColor(frac)
    self:drawText(tr("IGUI_Mortar_Condition", math.floor(frac * 100)), 14, 28,
        cc[1], cc[2], cc[3], cc[4], FONT)

    -- Column headers.
    local bx, cx, sx, hy = 14, 178, 338, 50
    txt(tr("IGUI_Mortar_Bearing"), bx, hy, "textDim")
    txt(tr("IGUI_Mortar_Charge") .. " / " .. tr("IGUI_Mortar_Range"), cx, hy, "textDim")
    txt(tr("IGUI_Mortar_Shell"), sx, hy, "textDim")

    -- Bearing value (big).
    txt(string.format("%03d", math.floor(self.bearing)) .. " " ..
        tr("IGUI_Mortar_BearingUnit"), bx, 92, "value")

    -- Charge value.
    local charge = Config.getCharge(self.chargeId)
    txt(charge and charge.name or "?", cx, 92, "value")

    -- Range value (numeric only with a proper kit; else "unknown").
    if Inv.tierShowsRange(self._tier) then
        txt(tr("IGUI_Mortar_RangeTiles", self.range), cx, 112, "value")
    else
        txt(tr("IGUI_Mortar_RangeUnknown"), cx, 112, "textDim")
    end

    -- Shell value + count.
    local shell = self:currentShell()
    local count = Inv.count(self.character, shell.itemType)
    local shellName = tr(shell.nameKey)
    local shellCol = count > 0 and "value" or "bad"
    txt(string.format("%s  x%d", shellName, count), sx, 92, shellCol)

    -- Tool tier + scatter spread estimate.
    local tierName = self._tier or "NONE"
    txt(tr("IGUI_Mortar_Tool") .. ": " .. tierName, bx, 134, "textDim")
    txt(tr("IGUI_Mortar_ScatterPreview", math.floor(self._preview + 0.5)), bx, 152, "warn")

    -- Tool warning, if any.
    local warnKey = Inv.tierWarningKey(self._tier)
    if self._tier == "NONE" then warnKey = "IGUI_Mortar_Warn_NoTools" end
    if warnKey then txt(tr(warnKey), cx, 134, "warn") end

    -- Status line.
    if self.statusKey then
        txt(tr(self.statusKey), 14, self.height - 56, self.statusColor)
    end

    -- Spotter availability hint.
    local hasMission = Targeting.getPendingSolution(self.character) ~= nil
    if self.btnSpotter then self.btnSpotter.enable = hasMission end
end

--=======================================================================--
-- STATIC CONTROLLER
--=======================================================================--

function UI.open(character, mortar)
    if UI.instance then UI.instance:close() end
    local panel = MortarFireUI:new(character, mortar)
    panel:initialise()
    panel:addToUIManager()
    panel:setVisible(true)
    UI.instance = panel
    Log.debug("Firing UI opened.")
    return panel
end

function UI.close()
    if UI.instance then UI.instance:close() end
end

-- Routed here by the client command handler on a fire reply.
function UI.onFireResult(result)
    if UI.instance then UI.instance:onFireResult(result) end
end

return MortarFireUI
>>>>>>> adfaaa6 (minimal working version)
