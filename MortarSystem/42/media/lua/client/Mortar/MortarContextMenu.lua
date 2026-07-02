--***********************************************************************--
-- Mortar System  -  MortarContextMenu.lua   (CLIENT)
--
-- PURPOSE
--   Wire the world right-click menu (design 3.2 / 3.3):
--     * Carrying the mortar + right-click eligible ground -> "Set Up Mortar"
--       (greyed with a reason tooltip when the tile is ineligible).
--     * Right-click a deployed mortar -> "Operate Mortar" + "Break Down Mortar".
--
-- DATA FLOW
--   Hooks Events.OnFillWorldObjectContextMenu. Depends on Inventory, Object,
--   Deploy, Operate, and the setup/breakdown actions. All actions path the
--   character adjacent first via luautils.walkAdj.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarUtils"
require "Mortar/MortarInventory"
require "Mortar/MortarObject"
require "Mortar/MortarDeploy"
require "Mortar/MortarOperate"
require "Mortar/Actions/MortarSetupAction"
require "Mortar/Actions/MortarBreakdownAction"
require "Mortar/Actions/MortarOperateAction"

local Config = MortarMod.Config
local Inv = MortarMod.Inventory
local MObj = MortarMod.Object
local Deploy = MortarMod.Deploy
local Operate = MortarMod.Operate
local Log = MortarMod.Log

local function tr(key) return getText and getText(key) or key end

-- Resolve the player object from the event's first argument (index or object).
local function resolvePlayer(p)
    if type(p) == "number" then return getSpecificPlayer(p) end
    return p
end

-- Find the clicked square + any mortar among the clicked world objects.
local function inspect(worldobjects)
    local square, mortar
    for _, o in ipairs(worldobjects) do
        if o and o.getSquare and not square then square = o:getSquare() end
        if not mortar then
            local w = MObj.wrap(o)
            if w then mortar = w end
        end
    end
    -- With 3D part visuals enabled the anchor object is invisible and may not
    -- be among the clicked objects; fall back to a square lookup so clicking
    -- the 3D baseplate/tube still finds the mortar.
    if not mortar and square then
        mortar = MObj.findAt(square:getX(), square:getY(), square:getZ())
    end
    return square, mortar
end

-- Strip vanilla grab/pick-up options when the clicked tile carries our
-- deployed 3D part visuals, so players cannot walk off with the mortar's
-- baseplate/tube world items. Best-effort: unknown option names are ignored.
local function scrubVisualPartOptions(context, square)
    if not square then return end
    local parts = MObj.findVisualParts(square)
    if not (parts.BASEPLATE or parts.TUBE) then return end
    pcall(function()
        local names = { "ContextMenu_Grab", "ContextMenu_GrabOne", "ContextMenu_Grab_One",
                        "ContextMenu_GrabHalf", "ContextMenu_GrabAll" }
        for _, key in ipairs(names) do
            local label = getText and getText(key)
            if label and label ~= key and context.removeOptionByName then
                context:removeOptionByName(label)
            end
        end
    end)
end

--=======================================================================--
-- CLICK HANDLERS
--=======================================================================--

local function doSetUp(player, item, square)
    if luautils and luautils.walkAdj then luautils.walkAdj(player, square, true) end
    ISTimedActionQueue.add(MortarSetupAction:new(player, item, square))
end

local function doOperate(player, mortar)
    Operate.begin(player, mortar)
end

local function doBreakDown(player, mortar)
    local sq = mortar:getObject() and mortar:getObject():getSquare()
    if sq and luautils and luautils.walkAdj then luautils.walkAdj(player, sq, true) end
    ISTimedActionQueue.add(MortarBreakdownAction:new(player, mortar))
end

--=======================================================================--
-- MENU FILL
--=======================================================================--

local function onFill(playerArg, context, worldobjects, test)
    if test then return end
    local player = resolvePlayer(playerArg)
    if not player then return end

    local square, mortar = inspect(worldobjects)
    scrubVisualPartOptions(context, square)

    ------------------------------------------------------------------
    -- Deployed mortar present -> Operate / Break Down.
    ------------------------------------------------------------------
    if mortar then
        context:addOption(tr("ContextMenu_Mortar_Operate"), worldobjects,
            function() doOperate(player, mortar) end)

        local bd = context:addOption(tr("ContextMenu_Mortar_BreakDown"), worldobjects,
            function() doBreakDown(player, mortar) end)
        if mortar:isBusy() then
            bd.notAvailable = true
        end
        return
    end

    ------------------------------------------------------------------
    -- Carrying the mortar -> Set Up (validated, greyed with reason).
    ------------------------------------------------------------------
    local item = Inv.findMortarItem(player)
    if item and square then
        local ok, reasonKey = Deploy.canDeployOn(square, player)
        local opt = context:addOption(tr("ContextMenu_Mortar_SetUp"), worldobjects,
            ok and function() doSetUp(player, item, square) end or nil)
        if not ok then
            opt.notAvailable = true
            -- Attach a reason tooltip.
            local tip = ISWorldObjectContextMenu.addToolTip()
            tip:setName(tr("ContextMenu_Mortar_CantPlace"))
            tip.description = tr(reasonKey or "ContextMenu_Mortar_NeedFlat")
            opt.toolTip = tip
        end
    end
end

if not MortarMod._contextWired then
    MortarMod._contextWired = true
    if Events and Events.OnFillWorldObjectContextMenu then
        Events.OnFillWorldObjectContextMenu.Add(onFill)
    end
end
