--***********************************************************************--
-- Mortar System  -  MortarSetupAction.lua   (CLIENT timed action)
--
-- PURPOSE
--   "Set Up Mortar": an interruptible timed action that, on completion, removes
--   the carried mortar item and spawns the deployed composite object facing the
--   character (design 3.2). Duration scales with Nimble/Strength.
--
-- LIFECYCLE
--   isValid  - item still carried + square still eligible (re-checked each tick)
--   start    - play the build animation
--   perform  - create object, remove item (carrying condition across), award XP
--
-- DATA FLOW
--   Depends on Config, Utils, Object (create), Inventory (item condition), XP.
--   Object creation transmits to MP clients, so this is MP-safe.
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

MortarSetupAction = ISBaseTimedAction:derive("MortarSetupAction")

function MortarSetupAction:isValid()
    -- Item must still be carried and the target tile still clear.
    if not self.character:getInventory():contains(self.mortarItem) then
        return false
    end
    if not self.square then return false end
    -- Eligibility is validated up-front by the context menu; re-check it is not
    -- now occupied by another mortar (race with a second player in MP).
    if MObj.findAt(self.square:getX(), self.square:getY(), self.square:getZ()) then
        return false
    end
    return true
end

function MortarSetupAction:waitToStart()
    self.character:faceLocation(self.square:getX(), self.square:getY())
    return self.character:shouldBeTurning()
end

function MortarSetupAction:update()
    self.character:faceLocation(self.square:getX(), self.square:getY())
end

function MortarSetupAction:start()
    self:setActionAnim(Config.ACTION.anim.setup)
    self.character:SetVariable("LootPosition", "Low")
    -- Placeholder SFX hook (vanilla rummage); swap for a real assembly sound.
    self.sound = self.character:playSound("PutItemInBag")
end

function MortarSetupAction:stop()
    ISBaseTimedAction.stop(self)
end

function MortarSetupAction:perform()
    local character = self.character

    -- Carry the item's condition into the deployed object.
    local conditionValue = Inv.getItemCondition(self.mortarItem)
    local deployerName = (character.getUsername and character:getUsername()) or "Survivor"

    -- Spawn the composite world object facing the character.
    local facing = character:getDir()  -- IsoDirections
    local wrapper = MObj.create(self.square, tostring(facing), conditionValue, deployerName)

    if wrapper then
        -- Consume the carried item only on success.
        character:getInventory():Remove(self.mortarItem)
        XP.awardSetupBreakdown(character)
        Log.info("Mortar deployed by %s.", deployerName)
    else
        Log.error("Setup failed: object not created; item retained.")
    end

    ISBaseTimedAction.perform(self)
end

function MortarSetupAction:new(character, mortarItem, square)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.mortarItem = mortarItem
    o.square = square
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = Utils.skilledActionTicks(character, Config.DEPLOY.setupSeconds)
    return o
end

return MortarSetupAction
