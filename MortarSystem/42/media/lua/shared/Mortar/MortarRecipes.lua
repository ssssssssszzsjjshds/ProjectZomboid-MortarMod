--***********************************************************************--
-- Mortar System  -  MortarRecipes.lua   (SHARED)
--
-- PURPOSE
--   Lua hooks for the crafting/repair recipes (recipes_mortar.txt). Defined as a
--   global function because the B42 crafting system resolves OnCreate/OnTest by
--   name. Kept in shared/ so it exists wherever crafting executes (SP + MP).
--
-- B42 SIGNATURE
--   OnCreate(craftRecipeData, character)   -- TWO args in B42 (B41 used three).
--
-- DATA FLOW
--   Depends on Config + Inventory (item condition). The repair restores tube
--   condition on the crafted mortar. A fresh item already defaults to full
--   condition, so this also serves as the place to implement partial repair.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarInventory"

local Config = MortarMod.Config
local Log = MortarMod.Log
local Inv = MortarMod.Inventory

-- Pull created items out of the recipe data across possible B42 method names.
local function createdItems(recipeData)
    if not recipeData then return nil end
    for _, name in ipairs({ "getAllCreatedItems", "getOutputItems", "getCreatedItems" }) do
        if type(recipeData[name]) == "function" then
            local ok, list = pcall(recipeData[name], recipeData)
            if ok and list then return list end
        end
    end
    return nil
end

-- OnCreate hook for RepairM224Mortar: ensure the repaired tube comes out at full
-- (or restored) condition. Defensive: if the items can't be enumerated, a fresh
-- mortar already defaults to full condition, so the repair still "works".
function MortarRecipes_OnRepair(recipeData, character)
    local items = createdItems(recipeData)
    if not items or not items.size then
        Log.debug("Repair OnCreate: created items not enumerable; fresh item is full condition.")
        return
    end
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and item.getFullType and item:getFullType() == Config.ITEMS.MORTAR then
            -- Full restore for now; for PARTIAL repair, read the consumed input's
            -- stored condition and set min(max, input + Config.CONDITION.repairAmount).
            Inv.setItemCondition(item, Config.CONDITION.max)
            Log.info("Repaired mortar to full condition.")
        end
    end
end
