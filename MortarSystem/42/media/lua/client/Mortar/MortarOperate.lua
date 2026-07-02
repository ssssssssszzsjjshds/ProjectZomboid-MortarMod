--***********************************************************************--
-- Mortar System  -  MortarOperate.lua   (CLIENT)
--
-- PURPOSE
--   Orchestrate the "Operate Mortar" flow (design 3.3): walk the operator to the
--   mortar, then queue the settle-in action that opens the firing UI. Also
--   provides the matching teardown (finish) the UI calls on close.
--
-- DATA FLOW
--   Depends on the operate timed action + walk-to. Uses luautils.walkAdj to path
--   adjacent to the (possibly multi-tile) mortar footprint.
--***********************************************************************--

require "TimedActions/ISBaseTimedAction"
require "TimedActions/ISWalkToTimedAction"
require "Mortar/MortarConfig"
require "Mortar/MortarObject"

local Config = MortarMod.Config
local Log = MortarMod.Log

MortarMod = MortarMod or {}
MortarMod.Operate = MortarMod.Operate or {}
local Operate = MortarMod.Operate

-- Begin operating: path to the mortar then open the UI.
function Operate.begin(character, mortarObject)
    if not character or not mortarObject then return end
    local obj = mortarObject:getObject()
    local square = obj and obj.getSquare and obj:getSquare()
    if not square then
        Log.warn("Operate.begin: mortar has no square.")
        return
    end

    -- Path adjacent to the footprint. walkAdj queues the walk if needed; if it
    -- reports unreachable we still open the UI from the current position so the
    -- player isn't hard-blocked (lenient v1 behaviour).
    local walked = false
    if luautils and luautils.walkAdj then
        walked = luautils.walkAdj(character, square, true)
    end
    if walked == false then
        Log.debug("Operate.begin: walkAdj reported unreachable; opening in place.")
    end

    ISTimedActionQueue.add(MortarOperateAction:new(character, mortarObject))
end

-- Teardown invoked by the UI when it closes (Stand Down / interrupted).
function Operate.finish(character, mortarObject)
    if character then
        pcall(function() character:setSneaking(false) end)
    end
    if mortarObject then
        mortarObject:setBusy(false)
    end
    Log.debug("Operate.finish: stood down.")
end

return Operate
