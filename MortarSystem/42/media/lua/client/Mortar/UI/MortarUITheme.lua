--***********************************************************************--
-- Mortar System  -  MortarUITheme.lua   (CLIENT)
--
-- PURPOSE
--   Central palette + tiny draw helpers for the firing HUD so colours/spacing
--   live in one place (UI polish is the modder's job; this makes it trivial).
--
-- DATA FLOW
--   Pure constants + helpers. No engine deps beyond the ISPanel draw methods
--   passed in by callers.
--***********************************************************************--

MortarMod = MortarMod or {}
MortarMod.UITheme = MortarMod.UITheme or {}

local T = MortarMod.UITheme

-- Colours are {r,g,b,a} in 0..1.
T.colors = {
    bg            = { 0.06, 0.07, 0.05, 0.86 },
    border        = { 0.45, 0.50, 0.35, 1.0 },
    panel         = { 0.10, 0.12, 0.09, 0.80 },
    text          = { 0.86, 0.90, 0.80, 1.0 },
    textDim       = { 0.60, 0.64, 0.55, 1.0 },
    value         = { 0.95, 0.93, 0.70, 1.0 },
    good          = { 0.55, 0.85, 0.45, 1.0 },
    warn          = { 0.95, 0.75, 0.30, 1.0 },
    bad           = { 0.90, 0.40, 0.35, 1.0 },
    fire          = { 0.70, 0.25, 0.20, 1.0 },
    fireHover     = { 0.85, 0.35, 0.28, 1.0 },
}

function T.c(name)
    local c = T.colors[name] or T.colors.text
    return c[1], c[2], c[3], c[4]
end

-- Pick a condition colour by fraction (0..1).
function T.conditionColor(frac)
    if frac > 0.66 then return T.colors.good end
    if frac > 0.33 then return T.colors.warn end
    return T.colors.bad
end

return T
