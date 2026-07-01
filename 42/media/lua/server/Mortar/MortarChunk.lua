--***********************************************************************--
-- Mortar System  -  MortarChunk.lua   (SERVER / authority)
--
-- PURPOSE
--   Decide whether an impact's terrain is currently simulated. Build 42 exposes
--   NO Lua call to force-load arbitrary off-screen chunks (verified against the
--   42.19 source -- getOrLoadChunkForLua / getOrLoadChunk do not exist). So
--   instead of pretending to force-load, this module honestly answers "is the
--   impact area loaded?" and the firing pipeline either detonates now or DEFERS
--   the blast until the terrain streams in (see MortarPending).
--
-- DATA FLOW
--   Depends on Config, Log, Utils. Used by MortarFire to gate detonation and by
--   the debug overlay to report nearby loaded chunks.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarUtils"

MortarMod = MortarMod or {}
MortarMod.Chunk = MortarMod.Chunk or {}

local Chunk = MortarMod.Chunk
local Config = MortarMod.Config
local Log = MortarMod.Log
local Utils = MortarMod.Utils

-- B42 chunks are 8x8 squares (B41 were 10x10). Query the engine if it exposes
-- the size; otherwise fall back to 8.
local cachedSize = nil
function Chunk.size()
    if cachedSize then return cachedSize end
    local cell = Utils.getCell()
    if cell and type(cell.getChunkSizeInSquares) == "function" then
        local ok, n = pcall(function() return cell:getChunkSizeInSquares() end)
        if ok and type(n) == "number" and n > 0 then cachedSize = n return n end
    end
    -- Some builds expose IsoChunkMap.ChunkGridWidth or a constant; default 8.
    cachedSize = 8
    return cachedSize
end

-- Is the terrain at (x,y,z) currently streamed in?
function Chunk.isLoaded(x, y, z)
    -- A resolvable grid square is the strongest signal.
    if Utils.getSquare(x, y, z) ~= nil then return true end
    -- Fall back to asking for the already-streamed chunk (never loads from disk).
    local cell = Utils.getCell()
    if cell and type(cell.getChunk) == "function" then
        local size = Chunk.size()
        local cx = math.floor(x / size)
        local cy = math.floor(y / size)
        local ok, ch = pcall(function() return cell:getChunk(cx, cy) end)
        if ok and ch ~= nil then return true end
    end
    return false
end

--=======================================================================--
-- DEBUG: nearby loaded chunk count (best-effort)
--=======================================================================--

function Chunk.debugLoadedChunks(centerX, centerY, spanChunks)
    local out = {}
    local cell = Utils.getCell()
    if not cell then return out end
    local size = Chunk.size()
    spanChunks = spanChunks or 3
    local ccx = math.floor(centerX / size)
    local ccy = math.floor(centerY / size)
    for cx = ccx - spanChunks, ccx + spanChunks do
        for cy = ccy - spanChunks, ccy + spanChunks do
            local loaded = false
            if type(cell.getChunk) == "function" then
                local ok, ch = pcall(function() return cell:getChunk(cx, cy) end)
                loaded = ok and ch ~= nil
            else
                loaded = Utils.getSquare(cx * size, cy * size, 0) ~= nil
            end
            if loaded then out[#out + 1] = { wx = cx, wy = cy } end
        end
    end
    return out
end

return Chunk
