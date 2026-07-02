--***********************************************************************--
-- Mortar System  -  MortarOperateAction.lua   (CLIENT timed action)
--
-- PURPOSE
--   The short "settle in behind the tube" step queued AFTER the walk-to (design
--   3.3): face the mortar, drop to a crouch, mark the mortar busy, and open the
--   firing UI. Splitting this from the walk keeps the queue ordering clean.
--
-- DATA FLOW
--   Depends on Config + the UI module (opened on perform). The UI's close
--   handler is responsible for clearing the crouch + busy flag.
--***********************************************************************--

require "TimedActions/ISBaseTimedAction"
require "Mortar/MortarConfig"

local Config = MortarMod.Config
local Log = MortarMod.Log

MortarOperateAction = ISBaseTimedAction:derive("MortarOperateAction")

function MortarOperateAction:isValid()
    return self.mortarObject ~= nil and self.mortarObject:getObject() ~= nil
end

function MortarOperateAction:update()
    local x, y = self.mortarObject:getOriginCoords()
    self.character:faceLocation(x, y)
end

function MortarOperateAction:start()
    local x, y = self.mortarObject:getOriginCoords()
    self.character:faceLocation(x, y)
end

function MortarOperateAction:perform()
    local character = self.character

    -- Crouch / sneak stance while operating (best-effort across builds).
    pcall(function() character:setSneaking(true) end)

    -- Flag the mortar as in use so others can't break it down mid-mission.
    local operatorId = (character.getOnlineID and character:getOnlineID()) or 0
    self.mortarObject:setBusy(true, operatorId)

    -- Open the firing UI.
    if MortarMod.UI and MortarMod.UI.open then
        MortarMod.UI.open(character, self.mortarObject)
    else
        Log.error("Operate: firing UI module not available.")
    end

    ISBaseTimedAction.perform(self)
end

function MortarOperateAction:new(character, mortarObject)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.mortarObject = mortarObject
    o.stopOnWalk = false
    o.stopOnRun = true
    o.maxTime = 2  -- effectively instant; just sequences after the walk
    return o
end

return MortarOperateAction
