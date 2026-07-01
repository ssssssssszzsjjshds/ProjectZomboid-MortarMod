--***********************************************************************--
-- Mortar System  -  MortarDeploy.lua   (SHARED)
--
-- PURPOSE
--   Decide whether the mortar may be deployed on a given tile (design 3.2 / 3.3
--   override "Future Multi-Tile Support"). Validates EVERY tile of the footprint
--   so the same logic already works when the mortar becomes multi-tile.
--
-- DESIGN
--   Each rule is individually guarded: if a particular engine predicate is not
--   available on this build we SKIP that rule rather than block deployment,
--   preventing false negatives that would make the weapon unusable. Returns
--   (ok, reasonKey) where reasonKey is a ContextMenu translation key.
--
-- DATA FLOW
--   Depends on Config, Utils, Object. Used by the context menu (offer/grey out
--   "Set Up Mortar") and re-checked inside MortarSetupAction.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarUtils"
require "Mortar/MortarObject"

MortarMod = MortarMod or {}
MortarMod.Deploy = MortarMod.Deploy or {}

local Deploy = MortarMod.Deploy
local Config = MortarMod.Config
local Utils = MortarMod.Utils
local MObj = MortarMod.Object

-- Safe boolean predicate call: returns the boolean, or `default` if the method
-- is missing/throws (so an absent API skips the rule).
local function pred(obj, method, default)
    if not obj or type(obj[method]) ~= "function" then return default end
    local ok, v = pcall(obj[method], obj)
    if ok then return v == true end
    return default
end

-- Validate a single tile. Returns ok, reasonKey.
local function checkTile(square)
    if not square then
        return false, "ContextMenu_Mortar_NeedFlat"
    end

    -- Outdoors (no roof above). isOutside is stable across builds.
    if Config.DEPLOY.requireOutdoors and not pred(square, "isOutside", true) then
        return false, "ContextMenu_Mortar_NeedOutdoors"
    end

    -- Water.
    if Config.DEPLOY.forbidWater and pred(square, "isWaterSquare", false) then
        return false, "ContextMenu_Mortar_NeedFlat"
    end

    -- Stairs (skip rule if predicate absent).
    if Config.DEPLOY.forbidStairs and pred(square, "HasStairs", false) then
        return false, "ContextMenu_Mortar_NeedFlat"
    end

    -- Already a mortar here.
    if MObj.findAt(square:getX(), square:getY(), square:getZ()) then
        return false, "ContextMenu_Mortar_Occupied"
    end

    -- Vehicle present.
    if Config.DEPLOY.forbidVehicle then
        local hasVeh = false
        if square.getVehicleContainer then
            local ok, vc = pcall(function() return square:getVehicleContainer() end)
            hasVeh = ok and vc ~= nil
        end
        if not hasVeh then hasVeh = pred(square, "HasVehicle", false) end
        if hasVeh then return false, "ContextMenu_Mortar_Occupied" end
    end

    -- Solid furniture / wall on the tile.
    if Config.DEPLOY.forbidFurniture then
        local blocked = pred(square, "isSolid", false) or pred(square, "isSolidTrans", false)
        if blocked then
            return false, "ContextMenu_Mortar_Occupied"
        end
    end

    return true, nil
end

-- Validate the whole footprint anchored at `anchorSquare`. Returns ok, reasonKey.
function Deploy.canDeployOn(anchorSquare, player)
    if not anchorSquare then
        return false, "ContextMenu_Mortar_NeedFlat"
    end
    local ax, ay, az = anchorSquare:getX(), anchorSquare:getY(), anchorSquare:getZ()
    for _, off in ipairs(Config.DEPLOY.footprint) do
        local sq = Utils.getSquare(ax + off.dx, ay + off.dy, az)
        local ok, reason = checkTile(sq)
        if not ok then return false, reason end
    end
    return true, nil
end

return Deploy
