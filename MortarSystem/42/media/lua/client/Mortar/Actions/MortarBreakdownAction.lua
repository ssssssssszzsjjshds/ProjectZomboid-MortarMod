--***********************************************************************--
-- Mortar System  -  MortarBreakdownAction.lua   (CLIENT timed action)
--
-- PURPOSE
--   "Break Down Mortar": reverse of setup (design 3.2). On completion removes
--   the deployed object and returns a carried mortar item carrying the deployed
--   object's current condition. Awards Nimble XP.
--
-- DATA FLOW
--   Depends on Config, Utils, Object (wrap/remove), Inventory (item condition),
--   XP. Object removal transmits to MP clients.
--***********************************************************************--

require "TimedActions/ISBaseTimedAction"
require "Mortar/MortarConfig"
require "Mortar/MortarUtils"
require "Mortar/MortarObject"
require "Mortar/MortarInventory"
require "Mortar/MortarXP"

local Config = MortarMod.Config
local Utils = MortarMod.Utils
local MObj = MortarMod.Object
local Inv = MortarMod.Inventory
local XP = MortarMod.XP
local Log = MortarMod.Log

MortarBreakdownAction = ISBaseTimedAction:derive("MortarBreakdownAction")

function MortarBreakdownAction:isValid()
    -- The object must still exist and not be in use by someone.
    if not self.mortarObject or not self.mortarObject:getObject() then return false end
    if self.mortarObject:isBusy() then return false end
    return true
end

function MortarBreakdownAction:waitToStart()
    local x, y = self.mortarObject:getOriginCoords()
    self.character:faceLocation(x, y)
    return self.character:shouldBeTurning()
end

function MortarBreakdownAction:update()
    local x, y = self.mortarObject:getOriginCoords()
    self.character:faceLocation(x, y)
end

function MortarBreakdownAction:start()
    self:setActionAnim(Config.ACTION.anim.breakdown)
    self.character:SetVariable("LootPosition", "Low")
    self.sound = self.character:playSound("PutItemInBag")
end

function MortarBreakdownAction:stop()
    ISBaseTimedAction.stop(self)
end

function MortarBreakdownAction:perform()
    local character = self.character
    local condition = self.mortarObject:getCondition()

    -- Remove the world object first (transmits removal in MP).
    self.mortarObject:remove()

    -- Hand back a carry item carrying the same condition.
    local item = character:getInventory():AddItem(Config.ITEMS.MORTAR)
    if item then
        Inv.setItemCondition(item, condition)
    end
    XP.awardSetupBreakdown(character)
    Log.info("Mortar broken down (condition %.0f).", condition)

    ISBaseTimedAction.perform(self)
end

function MortarBreakdownAction:new(character, mortarObject)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.mortarObject = mortarObject
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = Utils.skilledActionTicks(character, Config.DEPLOY.breakdownSeconds)
    return o
end

return MortarBreakdownAction
