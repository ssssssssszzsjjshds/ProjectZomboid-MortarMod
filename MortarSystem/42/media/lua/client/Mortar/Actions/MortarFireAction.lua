--***********************************************************************--
-- Mortar System  -  MortarFireAction.lua   (CLIENT timed action)
--
-- PURPOSE
--   "Drop Round": the ~1.5s animation of dropping a round down the tube (design
--   4.5). On completion it sends the fire request to the AUTHORITY (server in
--   MP, local in SP) via the network layer -- it never resolves the shot
--   itself. The authoritative MortarFire pipeline does scatter/consume/explode.
--
-- DATA FLOW
--   Depends on Config, Utils, Inventory, Shells, Network. The fire `solution`
--   is a pure-data table built by the UI at click time.
--***********************************************************************--

require "TimedActions/ISBaseTimedAction"
require "Mortar/MortarConfig"
require "Mortar/MortarUtils"
require "Mortar/MortarInventory"
require "Mortar/MortarShells"
require "Mortar/MortarNetwork"

local Config = MortarMod.Config
local Utils = MortarMod.Utils
local Inv = MortarMod.Inventory
local Shells = MortarMod.Shells
local Net = MortarMod.Network
local Log = MortarMod.Log

MortarFireAction = ISBaseTimedAction:derive("MortarFireAction")

function MortarFireAction:isValid()
    if not self.mortarObject or not self.mortarObject:isServiceable() then
        return false
    end
    -- Still holding the selected shell?
    local shell = Shells.get(self.solution.shellKey)
    if not shell or Inv.count(self.character, shell.itemType) <= 0 then
        return false
    end
    return true
end

function MortarFireAction:waitToStart()
    self.character:faceLocation(self.solution.targetX, self.solution.targetY)
    return self.character:shouldBeTurning()
end

function MortarFireAction:start()
    self:setActionAnim(Config.ACTION.anim.fire)
    -- Placeholder "round into tube" SFX; replace with a real foley cue.
    self.sound = self.character:playSound("PutItemInBag")
end

function MortarFireAction:update()
    self.character:faceLocation(self.solution.targetX, self.solution.targetY)
end

function MortarFireAction:stop()
    if self.onCancel then self.onCancel() end
    ISBaseTimedAction.stop(self)
end

function MortarFireAction:perform()
    -- Hand the shot to the authority. Result comes back via "fireResult".
    Log.debug("Sending fire request: %s",
        MortarMod.Targeting.describe(self.solution))
    Net.toServer("fire", self.solution)
    if self.onFired then self.onFired() end
    ISBaseTimedAction.perform(self)
end

-- character, mortarObject(Wrapper), solution(table), callbacks(optional)
function MortarFireAction:new(character, mortarObject, solution, callbacks)
    local o = ISBaseTimedAction.new(self, character)
    o.character = character
    o.mortarObject = mortarObject
    o.solution = solution
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = Utils.secondsToTicks(Config.ACTION.fireAnimSeconds)
    callbacks = callbacks or {}
    o.onFired = callbacks.onFired
    o.onCancel = callbacks.onCancel
    return o
end

return MortarFireAction
