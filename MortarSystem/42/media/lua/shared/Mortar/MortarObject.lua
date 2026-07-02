--***********************************************************************--
-- Mortar System  -  MortarObject.lua
--
-- PURPOSE
--   The composite mortar model (design override "Mortar Representation"). Even
--   though the player carries one inventory item, a DEPLOYED mortar is modelled
--   as a composite with separate logical sub-states so future upgrades stay
--   cheap:
--       tube       - the firing tube (serviceability, calibre)
--       baseplate  - anchoring / deployment footprint
--       deployment - facing, who deployed it, when
--       rotation   - current aim bearing (persisted)
--       condition  - durability (also tracked on the carried item)
--       operating  - transient runtime state (busy / current operator)
--
--   The state lives in the IsoObject's modData (auto-persisted with the save).
--   This module is a thin OO wrapper over that data + the world object, exposing
--   intention-revealing accessors instead of raw modData pokes.
--
-- MULTI-TILE READINESS (design override)
--   The footprint is a list of {dx,dy} offsets (Config.DEPLOY.footprint). Today
--   it is a single tile, but getFootprintSquares() already returns every covered
--   square, so nothing assumes a 1x1 object.
--
-- DATA FLOW
--   Depends on Config, Log, Math, Utils, Version. Used by the deployment
--   actions (create/remove), the context menu (detect/describe), the firing UI
--   (read condition/bearing), and the firing pipeline (wear, serviceability).
--   World creation/removal performs MP transmits so placement syncs.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarMath"
require "Mortar/MortarUtils"
require "Mortar/MortarVersion"

MortarMod = MortarMod or {}
MortarMod.Object = MortarMod.Object or {}

local MObj = MortarMod.Object
local Config = MortarMod.Config
local Log = MortarMod.Log
local Mth = MortarMod.Math
local Utils = MortarMod.Utils
local Version = MortarMod.Version

-- modData key under which the composite state lives on the IsoObject.
local DATA_KEY = "MortarSystem"

--=======================================================================--
-- FACING <-> BEARING (4-direction sprite mapping)
--=======================================================================--

local CARDINAL_BEARING = { N = 0, E = 90, S = 180, W = 270 }

-- Nearest cardinal facing for a bearing.
local function bearingToFacing(bearing)
    bearing = Mth.normalizeBearing(bearing)
    if bearing >= 315 or bearing < 45 then return "N" end
    if bearing < 135 then return "E" end
    if bearing < 225 then return "S" end
    return "W"
end

-- Map a PZ IsoDirections name (player facing) to our 4-way cardinal.
local function isoDirToFacing(dirName)
    if not dirName then return "S" end
    dirName = tostring(dirName)
    if dirName == "N" or dirName == "NE" or dirName == "NW" then return "N" end
    if dirName == "S" or dirName == "SE" or dirName == "SW" then return "S" end
    if dirName == "E" then return "E" end
    if dirName == "W" then return "W" end
    -- Diagonals already handled; default south.
    return "S"
end

-- Resolve the sprite name for a facing using the placeholder/custom toggle.
-- When the 3D part visuals are enabled the anchor object must not show a
-- placeholder tile, so the (nonexistent -> invisible) custom names are used:
-- a missing sprite does not crash and the object stays interactable.
local function spriteFor(facing)
    local set = (Config.SPRITE.usePlaceholderVanilla and not (Config.MODEL and Config.MODEL.enabled))
        and Config.SPRITE.placeholder
        or Config.SPRITE.custom
    return set[facing] or set.S
end

--=======================================================================--
-- 3D PART VISUALS
--   The deployed mortar is rendered by two world inventory items whose
--   WorldStaticModel supplies the 3D mesh: a static baseplate and a tube
--   assembly that is rotated to the aim bearing (hinge = model origin).
--   World items persist with the save, so visuals survive reload; they are
--   tagged via item modData and re-created if missing (self-healing).
--=======================================================================--

local VISUAL_KEY = "MortarVisualPart"   -- item modData tag: "BASEPLATE" | "TUBE"

local function visualsEnabled()
    return Config.MODEL and Config.MODEL.enabled == true
end

-- True if `item` (an InventoryItem) is one of our deployed part visuals.
function MObj.isVisualPartItem(item)
    if not item or not item.getModData then return false end
    local ok, tag = pcall(function() return item:getModData()[VISUAL_KEY] end)
    return ok and tag ~= nil
end

-- Collect this square's part visuals: { BASEPLATE = IsoWorldInventoryObject, TUBE = ... }
function MObj.findVisualParts(square)
    local parts = {}
    if not square or not square.getWorldObjects then return parts end
    pcall(function()
        local list = square:getWorldObjects()
        for i = 0, list:size() - 1 do
            local wobj = list:get(i)
            local item = wobj and wobj.getItem and wobj:getItem()
            if item then
                local tag = item:getModData()[VISUAL_KEY]
                if tag then parts[tag] = wobj end
            end
        end
    end)
    return parts
end

-- Spawn one part visual centred on the tile. Returns the InventoryItem or nil.
local function spawnVisual(square, fullType, tag)
    local item
    local ok = pcall(function()
        item = square:AddWorldInventoryItem(fullType, 0.5, 0.5, 0.0)
    end)
    if not ok or not item then
        Log.warn("MObj: failed to spawn 3D part visual '%s'.", tostring(fullType))
        return nil
    end
    item:getModData()[VISUAL_KEY] = tag
    -- Push the tag to MP clients (the item was transmitted before we tagged it).
    pcall(function()
        local wobj = item:getWorldItem()
        if wobj then wobj:transmitCompleteItemToClients() end
    end)
    return item
end

-- Bearing -> world item Z rotation (tunable mapping, see Config.MODEL).
local function bearingToModelYaw(bearing)
    local m = Config.MODEL
    return Mth.normalizeBearing((m.tubeYawSign or 1) * bearing + (m.tubeYawOffset or 0))
end

-- Point the tube visual at `bearing`. Probes the rotation API defensively:
-- if this build exposes none, the tube simply stays put (logged once).
function MObj.rotateTubeVisual(square, bearing)
    if not visualsEnabled() then return end
    local wobj = MObj.findVisualParts(square).TUBE
    if not wobj then return end
    local yaw = bearingToModelYaw(bearing or 180)
    local item = wobj:getItem()
    local applied = false
    if item and type(item.setWorldZRotation) == "function" then
        applied = pcall(function() item:setWorldZRotation(math.floor(yaw + 0.5)) end)
    end
    if not applied and type(wobj.setWorldZRotation) == "function" then
        applied = pcall(function() wobj:setWorldZRotation(math.floor(yaw + 0.5)) end)
    end
    if applied then
        pcall(function() wobj:transmitCompleteItemToClients() end)
        Log.debug("MObj: tube visual rotated to yaw %.0f (bearing %.0f).", yaw, bearing or -1)
    elseif not MObj._warnedNoRotation then
        MObj._warnedNoRotation = true
        Log.warn("MObj: no world item rotation API found; tube visual will not turn.")
    end
end

-- Pick the tube part item whose baked elevation best matches `rangeTiles`.
-- Closer targets need a steeper tube (high-angle fire): elevation runs from
-- maxDeg at minimum range down to minDeg at maximum range, then snaps to the
-- nearest baked mesh. nil range (no solution yet) -> the middle step.
local function tubeItemForRange(rangeTiles)
    local elev = Config.MODEL.tubeElevation
    if not elev or not elev.items or #elev.items == 0 then
        return Config.MODEL.tubeItem, nil
    end
    if not rangeTiles then
        local mid = elev.items[math.ceil(#elev.items / 2)]
        return mid.item, mid.deg
    end
    local minR = Config.RANGE.minRangeTiles or 10
    local maxR = Config.RANGE.maxRangeTiles or 1000
    local t = Mth.clamp((rangeTiles - minR) / math.max(maxR - minR, 1), 0, 1)
    local maxD, minD = elev.maxDeg or 85, elev.minDeg or 45
    local deg = maxD - (maxD - minD) * t
    local best, bestGap
    for _, e in ipairs(elev.items) do
        local gap = math.abs(e.deg - deg)
        if not bestGap or gap < bestGap then bestGap, best = gap, e end
    end
    return best.item, best.deg
end

-- Ensure both part visuals exist on the square (idempotent), aimed at
-- `bearing`, with the tube pitched for `rangeTiles` (elevation is baked into
-- per-step meshes, so a step change swaps the tube part item).
function MObj.createVisuals(square, bearing, rangeTiles)
    if not visualsEnabled() or not square then return end
    local parts = MObj.findVisualParts(square)
    if not parts.BASEPLATE then
        spawnVisual(square, Config.MODEL.baseplateItem, "BASEPLATE")
    end
    local wantType, deg = tubeItemForRange(rangeTiles)
    local tube = parts.TUBE
    if tube then
        local curType
        pcall(function() curType = tube:getItem():getFullType() end)
        if curType ~= wantType then
            pcall(function()
                local sq = tube:getSquare() or square
                sq:transmitRemoveItemFromSquare(tube)
            end)
            tube = nil
        end
    end
    if not tube then
        spawnVisual(square, wantType, "TUBE")
        if deg then
            Log.debug("MObj: tube elevation step %d deg (range %s).",
                deg, tostring(rangeTiles))
        end
    end
    MObj.rotateTubeVisual(square, bearing)
end

-- Remove any part visuals from the square (breakdown / cleanup).
function MObj.removeVisuals(square)
    if not square then return end
    for _, wobj in pairs(MObj.findVisualParts(square)) do
        pcall(function()
            local sq = wobj:getSquare() or square
            local removed = pcall(function() sq:transmitRemoveItemFromSquare(wobj) end)
            if not removed then sq:removeWorldObject(wobj) end
        end)
    end
end

--=======================================================================--
-- DEFAULT STATE / NORMALISATION
--=======================================================================--

-- Produce a fresh composite-state table for a newly deployed mortar.
local function defaultState(facing, conditionValue, deployerName, anchorX, anchorY, anchorZ)
    return {
        isMortar = true,
        schema   = Version.DATA_SCHEMA,
        id       = string.format("M_%d_%d_%d_%d", anchorX, anchorY, anchorZ,
                       math.floor(Utils.gameMinutes() * 60)),
        tube = {
            calibre = "60mm",
            model = "M224",
            serviceable = true,
        },
        baseplate = {
            deployed = true,
            anchorX = anchorX, anchorY = anchorY, anchorZ = anchorZ,
        },
        deployment = {
            facing = facing,
            footprint = Utils.deepCopy(Config.DEPLOY.footprint),
            deployedBy = deployerName,
            deployedAtMinutes = Utils.gameMinutes(),
        },
        rotation = {
            bearing = CARDINAL_BEARING[facing] or 180,
        },
        condition = {
            value = conditionValue or Config.CONDITION.max,
            max = Config.CONDITION.max,
        },
        operating = {
            busy = false,
            operatorId = nil,
        },
    }
end

-- Apply version migrations + fill any missing fields so older saves load clean.
function MObj.normalize(data)
    if type(data) ~= "table" then return data end
    local from = data.schema or 0
    while from < Version.DATA_SCHEMA do
        local step = Version.migrations[from]
        if step then step(data) end
        from = from + 1
    end
    data.schema = Version.DATA_SCHEMA
    -- Defensive backfill of sub-tables.
    data.tube       = data.tube       or { calibre = "60mm", model = "M224", serviceable = true }
    data.baseplate  = data.baseplate  or { deployed = true }
    data.deployment = data.deployment or { facing = "S", footprint = Utils.deepCopy(Config.DEPLOY.footprint) }
    data.rotation   = data.rotation   or { bearing = 180 }
    data.condition  = data.condition  or { value = Config.CONDITION.max, max = Config.CONDITION.max }
    data.operating  = data.operating  or { busy = false }
    return data
end

--=======================================================================--
-- WRAPPER OBJECT
--=======================================================================--

local Wrapper = {}
Wrapper.__index = Wrapper

-- Detect whether an arbitrary world IsoObject is one of our mortars.
function MObj.isMortarObject(obj)
    if not obj or not obj.getModData then return false end
    local ok, md = pcall(function() return obj:getModData() end)
    if not ok or not md then return false end
    local d = md[DATA_KEY]
    return type(d) == "table" and d.isMortar == true
end

-- Wrap an existing mortar IsoObject. Returns a Wrapper or nil if not a mortar.
function MObj.wrap(obj)
    if not MObj.isMortarObject(obj) then return nil end
    local self = setmetatable({}, Wrapper)
    self.obj = obj
    self.data = MObj.normalize(obj:getModData()[DATA_KEY])
    return self
end

-- Alias kept for readability at call sites.
MObj.fromWorldObject = MObj.wrap

--=======================================================================--
-- WORLD CREATION / REMOVAL  (authority creates; transmit syncs to MP clients)
--=======================================================================--

-- Create the deployed mortar IsoObject on `square`, facing `facingDir` (an
-- IsoDirections name or cardinal letter), carrying `conditionValue`.
-- Returns a Wrapper or nil on failure.
function MObj.create(square, facingDir, conditionValue, deployerName)
    if not square then
        Log.error("MObj.create: nil square.")
        return nil
    end
    local facing = isoDirToFacing(tostring(facingDir))
    local sprite = spriteFor(facing)

    local cell = Utils.getCell()
    local x, y, z = square:getX(), square:getY(), square:getZ()

    -- Construct the IsoObject. Constructor differs between B41 and B42.
    -- B41: IsoObject.new(cell, square, sprite)
    -- B42: IsoObject.new(square, sprite, "", false)
    local obj
    if ZombRandFloat then
        local ok = pcall(function()
            obj = IsoObject.new(square, sprite, "", false)
        end)
        if not ok or not obj then
            Log.error("MObj.create: B42 IsoObject.new failed for sprite '%s'.", tostring(sprite))
            return nil
        end
    else
        local ok = pcall(function()
            obj = IsoObject.new(cell, square, sprite)
        end)
        if not ok or not obj then
            Log.error("MObj.create: B41 IsoObject.new failed for sprite '%s'.", tostring(sprite))
            return nil
        end
    end

    -- Stamp composite state BEFORE adding so it is present when synced.
    local md = obj:getModData()
    md[DATA_KEY] = defaultState(facing, conditionValue, deployerName, x, y, z)

    -- Add to the square's MAIN object list so it renders + appears in
    -- getObjects() (B42: AddSpecialObject would keep it out of the render list).
    local added = pcall(function() square:AddTileObject(obj) end)
    if not added then
        pcall(function() square:AddSpecialObject(obj) end)
    end

    -- Network the new object to other players (no-op in SP). B42 method is the
    -- plural, no-arg transmitCompleteItemToClients().
    pcall(function() obj:transmitCompleteItemToClients() end)

    -- Spawn the 3D part visuals (baseplate + tube aimed at the initial bearing).
    MObj.createVisuals(square, md[DATA_KEY].rotation.bearing)

    Log.info("Deployed mortar '%s' at (%d,%d,%d) facing %s.",
        md[DATA_KEY].id, x, y, z, facing)
    return MObj.wrap(obj)
end

-- Remove the deployed mortar from the world (breakdown). Transmits removal.
function Wrapper:remove()
    local obj = self.obj
    local sq = obj and obj.getSquare and obj:getSquare()
    if not sq then
        Log.warn("MortarObject:remove: object has no square.")
        return false
    end
    -- Remove the 3D part visuals first, then the anchor object.
    MObj.removeVisuals(sq)

    -- Remove locally + transmit removal for MP.
    local ok = pcall(function() sq:transmitRemoveItemFromSquare(obj) end)
    if not ok then
        pcall(function() sq:RemoveTileObject(obj) end)
    end
    Log.info("Removed mortar '%s'.", self:getId())
    return true
end

--=======================================================================--
-- ACCESSORS
--=======================================================================--

function Wrapper:getObject() return self.obj end
function Wrapper:getData()   return self.data end
function Wrapper:getId()     return self.data.id end

-- Anchor (placement) tile coordinates.
function Wrapper:getAnchorCoords()
    local b = self.data.baseplate
    return b.anchorX, b.anchorY, b.anchorZ
end

-- The tube origin for firing = the anchor tile (centre of footprint today).
function Wrapper:getOriginCoords()
    -- Prefer the live object's square (authoritative after a load), fall back
    -- to the persisted anchor.
    local x, y, z = Utils.objectCoords(self.obj)
    if x then return x, y, z end
    return self:getAnchorCoords()
end

-- Every grid square covered by the footprint (multi-tile ready).
function Wrapper:getFootprintSquares()
    local ax, ay, az = self:getOriginCoords()
    local squares = {}
    local fp = self.data.deployment.footprint or Config.DEPLOY.footprint
    for _, off in ipairs(fp) do
        local sq = Utils.getSquare(ax + off.dx, ay + off.dy, az)
        if sq then squares[#squares + 1] = sq end
    end
    return squares
end

-- Aim bearing.
function Wrapper:getBearing() return self.data.rotation.bearing or 180 end
function Wrapper:setBearing(deg)
    self:setAim(deg, self.data.rotation.range)
end

-- Full aim update: bearing (yaw) + range (visual tube elevation step).
function Wrapper:setAim(deg, rangeTiles)
    self.data.rotation.bearing = Mth.normalizeBearing(deg)
    if rangeTiles then self.data.rotation.range = rangeTiles end
    -- Update sprite to the nearest cardinal so the world object reflects aim.
    local facing = bearingToFacing(self.data.rotation.bearing)
    if facing ~= self.data.deployment.facing then
        self.data.deployment.facing = facing
        self:applySprite(facing)
    end
    -- Swing the 3D tube assembly around its hinge to the new bearing and
    -- swap it to the elevation step for the range. createVisuals is
    -- idempotent and self-heals missing parts first.
    local sq = self.obj and self.obj.getSquare and self.obj:getSquare()
    if sq then
        MObj.createVisuals(sq, self.data.rotation.bearing, self.data.rotation.range)
    end
end

function Wrapper:getFacing() return self.data.deployment.facing end

-- Re-skin the world object to a facing's sprite (placeholder-aware).
function Wrapper:applySprite(facing)
    facing = facing or self.data.deployment.facing
    local name = spriteFor(facing)
    pcall(function()
        local spr = getSprite and getSprite(name)
        if spr and self.obj.setSprite then
            self.obj:setSprite(spr)
            self.obj:transmitCompleteItemToClients()
        end
    end)
end

-- Push this object's modData to MP clients. Object modData is NOT auto-synced
-- in MP (unlike the save), so call this after mutating condition/rotation in a
-- context that must be visible to other players.
function Wrapper:syncModData()
    pcall(function()
        if self.obj.transmitModData then self.obj:transmitModData() end
    end)
end

-- Condition (durability).
function Wrapper:getCondition()     return self.data.condition.value end
function Wrapper:getConditionMax()  return self.data.condition.max or Config.CONDITION.max end
function Wrapper:getConditionFraction()
    local maxv = self:getConditionMax()
    if maxv <= 0 then return 0 end
    return Mth.clamp(self:getCondition() / maxv, 0, 1)
end
function Wrapper:setCondition(v)
    self.data.condition.value = Mth.clamp(v, 0, self:getConditionMax())
end
function Wrapper:addCondition(delta)
    self:setCondition(self:getCondition() + delta)
end

-- Serviceable = tube intact AND condition above zero.
function Wrapper:isServiceable()
    return self.data.tube.serviceable == true and self:getCondition() > 0
end

-- Operating (transient) state.
function Wrapper:isBusy() return self.data.operating.busy == true end
function Wrapper:setBusy(busy, operatorId)
    self.data.operating.busy = busy and true or false
    self.data.operating.operatorId = busy and operatorId or nil
end

-- Display name shown in the world context menu / UI title.
function Wrapper:getDisplayName()
    return getText and getText("IGUI_Mortar_DeployedName") or "M224 Mortar"
end

--=======================================================================--
-- WORLD LOOKUP
--=======================================================================--

-- Scan a list (java ArrayList) of IsoObjects for a mortar; return a Wrapper.
local function scanList(list)
    if not list or not list.size then return nil end
    for i = 0, list:size() - 1 do
        local obj = list:get(i)
        if MObj.isMortarObject(obj) then
            return MObj.wrap(obj)
        end
    end
    return nil
end

-- Find the deployed mortar occupying the tile (x,y,z), or nil. Checks both the
-- special-object list (where deployment adds it) and the general object list.
function MObj.findAt(x, y, z)
    local sq = Utils.getSquare(x, y, z)
    if not sq then return nil end
    local found
    if sq.getSpecialObjects then
        found = scanList(sq:getSpecialObjects())
        if found then return found end
    end
    if sq.getObjects then
        found = scanList(sq:getObjects())
        if found then return found end
    end
    return nil
end

return MObj
