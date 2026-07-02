--***********************************************************************--
-- Mortar System  -  MortarFireUI.lua   (CLIENT)
--
-- PURPOSE
--   The fire-control HUD, skinned as a military optic (media/ui/
--   Mortar_FireHUD.png): all readouts and controls are rendered inside the
--   device's green phosphor screen.
--
-- CONTROLS (military naming; see IG_UI_EN.txt)
--   AZIMUTH    -10/-5/-1/+1/+5/+10 deg steppers (also adopts the operator's
--              physical facing, design 4.2).
--   ELEVATION  the propellant/angle setting (formerly "charge"): E85 steep &
--              close ... E45 shallow & far; the deployed tube's visual pitch
--              tracks it via the fire solution range.
--   RANGE      fine adjust inside the elevation band (numeric only with a
--              proper plotting kit, design 4.6).
--   ROUND      HE / SMOKE / ILLUM with live counts.
--   LOAD FIRE MISSION  pulls the map-plotted solution into the sight AND
--              lays the gun on it.
--   LAY GUN    slews the deployed tube (yaw + pitch) to the CURRENTLY
--              selected azimuth/elevation without firing.
--   FIRE       drops the round; the authority replies via onFireResult.
--
-- DATA FLOW
--   Depends on Config, Inventory, Shells, Targeting, Scatter, the fire
--   action, Operate (teardown on close), Theme. Holds no authority logic.
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
-- HUD SKIN
--   The optic housing texture and the pixel rect of its green screen
--   (measured on the 558x447 source image). All readouts stay inside it.
--=======================================================================--

local HUD_TEXTURE = "media/ui/Mortar_FireHUD.png"
local PANEL_W, PANEL_H = 558, 447
local SCREEN = { x = 52, y = 58, w = 342, h = 322 }

-- Phosphor palette (r, g, b, a) drawn over the green CRT.
local PHOS = {
    text   = { 0.62, 0.96, 0.50, 1.0 },   -- readout values
    dim    = { 0.42, 0.70, 0.38, 0.9 },   -- labels / secondary
    warn   = { 0.95, 0.80, 0.35, 1.0 },
    bad    = { 1.00, 0.45, 0.30, 1.0 },
    good   = { 0.70, 1.00, 0.55, 1.0 },
    line   = { 0.35, 0.60, 0.32, 0.55 },
}

local function phos(name) return PHOS[name] or PHOS.text end

--=======================================================================--
-- CONSTRUCTION
--=======================================================================--

function MortarFireUI:new(character, mortar)
    local w, h = PANEL_W, PANEL_H
    local x = getCore():getScreenWidth() / 2 - w / 2
    local y = getCore():getScreenHeight() - h - 40
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self

    o.character = character
    o.mortar = mortar
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    o.borderColor = { r = 0, g = 0, b = 0, a = 0 }
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
    o.statusColor = "dim"

    -- Pick the first round type the operator actually has.
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

-- Continuous visual tube elevation for a range (same mapping the deployed
-- tube uses: steep when close, shallow when far).
local function elevationDegForRange(range)
    local elev = Config.MODEL and Config.MODEL.tubeElevation
    local maxD = (elev and elev.maxDeg) or 85
    local minD = (elev and elev.minDeg) or 45
    local minR = Config.RANGE.minRangeTiles or 10
    local maxR = Config.RANGE.maxRangeTiles or 1000
    local t = MortarMod.Math.clamp(((range or minR) - minR) / math.max(maxR - minR, 1), 0, 1)
    return math.floor(maxD - (maxD - minD) * t + 0.5)
end

-- Mark that the operator changed the solution by hand (drops spotter accuracy).
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

-- LOAD FIRE MISSION: pull the map-plotted solution into the sight and lay
-- the gun on it.
function MortarFireUI:useSpotter()
    local s = Targeting.getPendingSolution(self.character)
    if not s then self:setStatus("IGUI_Mortar_Spotter_None", "warn") return end
    -- Clear the map plot line and module state.
    if MortarMod.Spotter and MortarMod.Spotter.clearPlot then
        MortarMod.Spotter.clearPlot()
    end
    -- Recompute from THIS mortar's tube to the plotted target tile so the
    -- azimuth/range are correct for the actual emplacement (the observer who
    -- plotted it may not have stood exactly on the gun).
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
    -- Physically slew the deployed tube to the plotted solution right away
    -- (yaw around the hinge + elevation step for the range).
    self.mortar:setAim(recomputed.bearing, recomputed.range)
    self.mortar:syncModData()
    self:setStatus("IGUI_Mortar_Spotter_Use", "good")
end

-- LAY GUN: slew the deployed tube to the CURRENTLY selected azimuth and
-- elevation/range without firing.
function MortarFireUI:layGun()
    self.mortar:setAim(self.bearing, self.range)
    self.mortar:syncModData()
    local setting = Config.getCharge(self.chargeId)
    self:setStatus("IGUI_Mortar_GunLaid", "good",
        math.floor(self.bearing), setting and setting.name or "?")
end

function MortarFireUI:setStatus(key, color, ...)
    self.statusKey = key
    self.statusColor = color or "dim"
    self.statusArgs = select("#", ...) > 0 and { ... } or nil
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
        if result.flightSeconds and result.flightSeconds >= 1 then
            self:setStatus("IGUI_Mortar_Fired_Flight", "good",
                math.floor(result.flightSeconds + 0.5))
        else
            self:setStatus("IGUI_Mortar_Fired", "good")
        end
        -- Kick off the cosmetic shell-flight animation (launch + descent).
        local SFlight = MortarMod.ShellFlight
        if SFlight and SFlight.onFired then
            local ox, oy, oz = self.mortar:getOriginCoords()
            pcall(function()
                SFlight.onFired(ox, oy, oz, self.bearing,
                    result.impactX, result.impactY, result.impactZ,
                    result.flightSeconds or 0, result.shellKey)
            end)
        end
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

-- Small phosphor-styled button inside the screen.
function MortarFireUI:addBtn(x, y, w, h, label, fn)
    local b = ISButton:new(x, y, w, h, label, self, fn)
    b.font = FONT
    b:initialise()
    b:instantiate()
    b.backgroundColor         = { r = 0.05, g = 0.13, b = 0.05, a = 0.80 }
    b.backgroundColorMouseOver= { r = 0.10, g = 0.24, b = 0.09, a = 0.90 }
    b.borderColor             = { r = 0.35, g = 0.62, b = 0.32, a = 0.90 }
    b.textColor               = { r = 0.62, g = 0.96, b = 0.50, a = 1.0 }
    self:addChild(b)
    return b
end

function MortarFireUI:createChildren()
    local S = SCREEN
    local pad = 12
    local left = S.x + pad
    local right = S.x + S.w - pad

    -- STAND DOWN (top-right corner of the screen).
    self.btnClose = self:addBtn(right - 26, S.y + 4, 26, 16, "X",
        function(t) t:onClose() end)

    local bw, bh = 34, 17

   -- AZIMUTH steppers: -10 -5 -1 | BEARING | +1 +5 +10
local ay = S.y + 40

local bw = 30
local bh = 17
local spacing = 4
local centerGap = 65

local centerX = S.x + (S.w / 2)

local az = { "-10", "-5", "-1", "+1", "+5", "+10" }
local deltas = { -10, -5, -1, 1, 5, 10 }

local positions = {
    centerX - centerGap - bw * 3 - spacing * 2,
    centerX - centerGap - bw * 2 - spacing,
    centerX - centerGap - bw,

    centerX + centerGap,
    centerX + centerGap + bw + spacing,
    centerX + centerGap + (bw + spacing) * 2,
}

for i = 1, 6 do
    local d = deltas[i]
    self:addBtn(positions[i], ay, bw, bh, az[i],
        function(t)
            t:changeBearing(d)
        end)
end

    -- ELEVATION setting prev/next.
    local ey = S.y + 80
    self:addBtn(left,        ey, bw, bh, "<", function(t) t:changeCharge(-1) end)
    self:addBtn(right - bw,  ey, bw, bh, ">", function(t) t:changeCharge(1) end)

    -- RANGE steppers.
    local ry = S.y + 120
    self:addBtn(left,             ry, bw + 6, bh, "-50", function(t) t:changeRange(-50) end)
    self:addBtn(left + bw + 10,   ry, bw, bh,     "-5",  function(t) t:changeRange(-5) end)
    self:addBtn(right - 2*bw - 10, ry, bw, bh,    "+5",  function(t) t:changeRange(5) end)
    self:addBtn(right - bw + 4,   ry, bw + 6, bh, "+50", function(t) t:changeRange(50) end)

    -- ROUND prev/next.
    local sy = S.y + 160
    self:addBtn(left,       sy, bw, bh, "<", function(t) t:cycleShell(-1) end)
    self:addBtn(right - bw, sy, bw, bh, ">", function(t) t:cycleShell(1) end)

    -- LOAD FIRE MISSION | LAY GUN.
    local by = S.y + S.h - 92
    local half = math.floor((S.w - pad * 2 - 8) / 2)
    self.btnSpotter = self:addBtn(left, by, half, 22,
        tr("IGUI_Mortar_Spotter_Use"), function(t) t:useSpotter() end)
    self.btnLay = self:addBtn(left + half + 8, by, half, 22,
        tr("IGUI_Mortar_LayGun"), function(t) t:layGun() end)

    -- FIRE (big, centred).
    self.btnFire = self:addBtn(S.x + S.w / 2 - 90, by + 28, 180, 26,
        tr("IGUI_Mortar_Fire"), function(t) t:onFire() end)
    self.btnFire.backgroundColor = { r = 0.22, g = 0.07, b = 0.04, a = 0.9 }
    self.btnFire.borderColor     = { r = 0.85, g = 0.45, b = 0.25, a = 0.9 }
    self.btnFire.textColor       = { r = 1.0,  g = 0.65, b = 0.40, a = 1.0 }
end

--=======================================================================--
-- PER-FRAME STATE
--=======================================================================--

function MortarFireUI:update()
    -- Stand down automatically if the operator steps away from the gun.
    local mx, my = self.mortar:getOriginCoords()
    if mx then
        local dx = self.character:getX() - (mx + 0.5)
        local dy = self.character:getY() - (my + 0.5)
        local maxD = (Config.UI and Config.UI.closeDistanceTiles) or 1.9
        if dx * dx + dy * dy > maxD * maxD then
            self:close()
            return
        end
    end

    -- Adopt physical rotation if the operator turned the character.
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

    -- Disable FIRE while a round is out or no round of the selected type.
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
    -- Optic housing skin (fallback to a plain panel if the texture is missing).
    if self._hudTex == nil then
        self._hudTex = getTexture(HUD_TEXTURE) or false
    end
    if self._hudTex then
        self:drawTextureScaled(self._hudTex, 0, 0, self.width, self.height, 1, 1, 1, 1)
    else
        self:drawRect(0, 0, self.width, self.height, 0.92, 0.10, 0.14, 0.09)
        self:drawRectBorder(0, 0, self.width, self.height, 1, 0.4, 0.5, 0.35)
    end

    -- Cache live derived values for render().
    self._mult, self._tier = Inv.getToolMultiplier(self.character)
    self._preview = Scatter.computeRadius({
        player = self.character,
        chargeId = self.chargeId,
        toolTier = self._tier,
        conditionFraction = self.mortar:getConditionFraction(),
        spotterPlotTier = self.spotterPlotTier,
        range = self.range,
    })
end

function MortarFireUI:render()
    local S = SCREEN
    local pad = 12
    local left = S.x + pad
    local right = S.x + S.w - pad

    local function txt(s, x, y, c)
        local col = phos(c)
        self:drawText(s, x, y, col[1], col[2], col[3], col[4], FONT)
    end
    local function txtRight(s, x, y, c)
        local w = getTextManager():MeasureStringX(FONT, s)
        txt(s, x - w, y, c)
    end
    local function txtCentre(s, y, c)
        local w = getTextManager():MeasureStringX(FONT, s)
        txt(s, S.x + (S.w - w) / 2, y, c)
    end
    local function rule(y)
        local l = phos("line")
        self:drawRect(left, y, S.w - pad * 2, 1, l[4], l[1], l[2], l[3])
    end

    -- Header: title + tube condition.
    txt(tr("IGUI_Mortar_Title"), left, S.y + 4, "text")
    local frac = self.mortar:getConditionFraction()
    local condCol = frac > 0.5 and "dim" or (frac > 0.25 and "warn" or "bad")
    txtRight(tr("IGUI_Mortar_Condition", math.floor(frac * 100)), right - 32, S.y + 4, condCol)
    rule(S.y + 22)

    -- AZIMUTH row: label above, value centred between the - and + steppers.
    txt(tr("IGUI_Mortar_Azimuth"), left, S.y + 26, "dim")
    -- Built in code: PZ's translation loader mangles printf width specifiers
    -- like %03d, so no format strings live in the translation for these.
    txtCentre(string.format("%03d %s", math.floor(self.bearing),
        tr("IGUI_Mortar_BearingUnit")), S.y + 41, "text")

    -- ELEVATION row: setting name + projected tube angle for current range.
    local setting = Config.getCharge(self.chargeId)
    txt(tr("IGUI_Mortar_Elevation"), left, S.y + 66, "dim")
    txtRight(tr("IGUI_Mortar_RangeBand", setting.minRange, setting.maxRange),
        right, S.y + 66, "dim")
    txtCentre(string.format("%s / %d %s", setting.name or "?",
        elevationDegForRange(self.range), tr("IGUI_Mortar_BearingUnit")),
        S.y + 81, "text")

    -- RANGE row (numeric only with a proper kit).
    txt(tr("IGUI_Mortar_Range"), left, S.y + 106, "dim")
    if Inv.tierShowsRange(self._tier) then
        txtCentre(tr("IGUI_Mortar_RangeTiles", self.range), S.y + 121, "text")
    else
        txtCentre(tr("IGUI_Mortar_RangeUnknown"), S.y + 121, "warn")
    end

    -- ROUND row.
    local shell = self:currentShell()
    local count = Inv.count(self.character, shell.itemType)
    txt(tr("IGUI_Mortar_Round"), left, S.y + 146, "dim")
    txtCentre(string.format("%s  x%d", tr(shell.nameKey), count),
        S.y + 161, count > 0 and "text" or "bad")
    rule(S.y + 186)

    -- Data line: dispersion estimate + plotting kit tier (+ warning).
    txt(tr("IGUI_Mortar_ScatterPreview", math.floor(self._preview + 0.5)), left, S.y + 192, "warn")
    txtRight(tr("IGUI_Mortar_Tool") .. ": " .. (self._tier or "NONE"), right, S.y + 192, "dim")
    local warnKey = Inv.tierWarningKey(self._tier)
    if self._tier == "NONE" then warnKey = "IGUI_Mortar_Warn_NoTools" end
    if warnKey then txt(tr(warnKey), left, S.y + 208, "warn") end

    -- Status line (above the mission/lay buttons).
    if self.statusKey then
        local status = self.statusArgs
            and tr(self.statusKey, unpack(self.statusArgs))
            or tr(self.statusKey)
        txtCentre(status, S.y + S.h - 108, self.statusColor)
    end

    -- LOAD FIRE MISSION availability.
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
