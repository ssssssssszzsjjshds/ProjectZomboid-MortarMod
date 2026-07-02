--***********************************************************************--
-- Mortar System  -  MortarShellFlight.lua   (CLIENT)
--
-- PURPOSE
--   Cosmetic shell flight + launch/impact effects. PZ has no scriptable
--   projectile renderer, so the round is puppeteered with short-lived world
--   inventory items whose WorldStaticModel supplies a 3D shell mesh:
--
--     LAUNCH   fire thump (MortarFire), a 1-2 frame orange muzzle flash,
--              a white powder puff (engine smoke fx), a damped recoil kick
--              on the tube visual, and a nose-up shell climbing fast along
--              the aim bearing before despawning ("too high to see").
--     TERMINAL HE/SMOKE: just before landing the incoming whistle plays and
--              a nose-down shell drops onto the impact tile; at landing the
--              impact sound fires (HE: explosion up close / distant boom
--              afar; SMOKE: its own pop, never the distant boom).
--     ILLUM    NO landing animation - the round pops in the SKY over the
--              target: distant boom + a brief warm flash; the lasting light
--              is MortarIllumination's job.
--
--   The puppet is moved by remove-and-respawn every few ticks: world items
--   have no movement API, but at this rate it reads as smooth flight. Runs
--   only on the firing client (pure eye candy; other MP players get the
--   world-sound and the blast).
--
-- DATA FLOW
--   Config.SHELLFLIGHT (flight tuning) + Config.SHELLFX (audio/VFX).
--   Triggered by MortarFireUI:onFireResult. Fails soft everywhere.
--***********************************************************************--

require "Mortar/MortarConfig"
require "Mortar/MortarLogger"
require "Mortar/MortarUtils"
require "Mortar/MortarMath"

local Config = MortarMod.Config
local Log = MortarMod.Log
local Utils = MortarMod.Utils
local Mth = MortarMod.Math

MortarMod = MortarMod or {}
MortarMod.ShellFlight = MortarMod.ShellFlight or {}
local Flight = MortarMod.ShellFlight

Flight._anims = Flight._anims or {}
local MAX_ANIMS = 40          -- concurrent effect cap (rapid fire safety)

--=======================================================================--
-- CLOCK
--=======================================================================--

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, v = pcall(getTimestampMs)
        if ok and type(v) == "number" then return v end
    end
    if type(getTimestamp) == "function" then
        local ok, v = pcall(getTimestamp)
        if ok and type(v) == "number" then return v * 1000 end
    end
    return 0  -- no wall clock: onTick falls back to ~60 ticks/second
end

--=======================================================================--
-- AUDIO / LIGHT PRIMITIVES
--=======================================================================--

-- Positional one-shot through a free world emitter (falls back to the sound
-- manager if emitters are unavailable on this build).
local function playAt(name, x, y, z)
    if not name then return end
    local played = pcall(function()
        local em = getWorld():getFreeEmitter(x + 0.5, y + 0.5, z or 0)
        em:playSound(name)
    end)
    if not played then
        pcall(function()
            getSoundManager():PlayWorldSound(name, Utils.getSquare(x, y, z or 0),
                0, 60, 1, false)
        end)
    end
end

-- The distant boom must stay audible even when the impact sits on far-away,
-- unstreamed terrain (an emitter parked on an unloaded square can be culled
-- by the engine). So it plays from a few tiles ahead of the PLAYER, panned
-- toward the impact, instead of from the impact itself.
local function playDistantBoom(name, impactX, impactY)
    if not name then return end
    local px, py, pz = impactX, impactY, 0
    pcall(function()
        local pl = Utils.getPlayer()
        if pl then px, py, pz = pl:getX(), pl:getY(), pl:getZ() end
    end)
    local dx, dy = impactX - px, impactY - py
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 12 then
        playAt(name, impactX, impactY, 0)
        return
    end
    local off = 8
    playAt(name, px + dx / len * off, py + dy / len * off, pz)
end

local function addLight(x, y, z, spec)
    local light
    local ok = pcall(function()
        light = IsoLightSource.new(math.floor(x), math.floor(y), math.floor(z or 0),
            spec.r or 1, spec.g or 1, spec.b or 1, spec.radius or 10)
        getCell():addLamppost(light)
    end)
    return ok and light or nil
end

local function removeLight(light)
    if not light then return end
    pcall(function()
        if light.setActive then light:setActive(false) end
        getCell():removeLamppost(light)
    end)
end

--=======================================================================--
-- PUPPET HANDLING
--=======================================================================--

local function despawn(anim)
    if not anim.wobj then return end
    pcall(function()
        local sq = anim.wobj:getSquare()
        if sq then sq:transmitRemoveItemFromSquare(anim.wobj) end
    end)
    anim.wobj = nil
end

-- Place (or move) the puppet at float world coords + render height.
local function place(anim, wx, wy, h)
    despawn(anim)
    local sq = Utils.getSquare(math.floor(wx), math.floor(wy), anim.z)
    if not sq then return end  -- terrain not streamed; stay invisible this step
    local ok = pcall(function()
        local item = sq:AddWorldInventoryItem(anim.itemType,
            wx - math.floor(wx), wy - math.floor(wy), h)
        if item then
            item:getModData().MortarShellPuppet = true
            if item.setWorldZRotation then
                item:setWorldZRotation(math.floor(Mth.normalizeBearing(
                    anim.bearing + (Config.SHELLFLIGHT.yawOffset or 0)) + 0.5))
            end
            anim.wobj = item:getWorldItem()
        end
    end)
    if not ok and not Flight._warnedOnce then
        Flight._warnedOnce = true
        Log.warn("ShellFlight: puppet placement failed; animation degraded.")
    end
end

--=======================================================================--
-- ANIMATION KINDS
--   puppet  - flying shell (phase "up" climbs, "down" falls)
--   light   - transient light source (muzzle flash / illum pop)
--   recoil  - damped yaw kick on the deployed tube visual
--   oneshot - run fn() once when the delay expires (impact sounds etc.)
--=======================================================================--

-- Advance one animation. Returns true when it is finished.
local function updateAnim(anim)
    if anim.kind == "oneshot" then
        pcall(anim.fn)
        return true
    end

    if anim.kind == "light" then
        if not anim.light then
            anim.light = addLight(anim.x, anim.y, anim.z, anim.spec)
            if not anim.light then return true end
        end
        if anim.elapsed >= anim.duration then
            removeLight(anim.light)
            return true
        end
        return false
    end

    if anim.kind == "recoil" then
        local t = anim.elapsed / anim.duration
        if t >= 1 then
            pcall(function() anim.item:setWorldZRotation(anim.base) end)
            return true
        end
        -- damped oscillation: kick, overshoot back, settle
        local off = anim.kick * math.sin(t * math.pi * 3) * (1 - t)
        pcall(function() anim.item:setWorldZRotation(math.floor(anim.base + off + 0.5)) end)
        return false
    end

    -- puppet
    local t = anim.elapsed / anim.duration
    if t >= 1 then
        despawn(anim)
        return true
    end
    local wx, wy = Mth.projectBearing(anim.x, anim.y, anim.bearing, anim.drift * t)
    local h
    if anim.phase == "up" then
        h = anim.height * t * (2 - t)      -- decelerating climb
    else
        h = anim.height * (1 - t * t)      -- accelerating fall
    end
    place(anim, wx, wy, h)
    return false
end

--=======================================================================--
-- TICKER
--=======================================================================--

local tickCounter = 0
local lastMs = nil

local function onTick()
    local anims = Flight._anims
    if #anims == 0 then
        lastMs = nil
        return
    end
    local N = Config.SHELLFLIGHT.updateTicks or 2
    tickCounter = tickCounter + 1
    if tickCounter % N ~= 0 then return end

    local t = nowMs()
    local dt
    if t > 0 and lastMs and t > lastMs then
        dt = (t - lastMs) / 1000.0
    else
        dt = N / 60.0
    end
    if t > 0 then lastMs = t end
    if dt > 0.5 then dt = 0.5 end  -- clamp hitches so puppets don't teleport

    for i = #anims, 1, -1 do
        local a = anims[i]
        if a.delay > 0 then
            a.delay = a.delay - dt
        else
            a.elapsed = a.elapsed + dt
            local done = false
            local ok = pcall(function() done = updateAnim(a) end)
            if not ok or done then
                pcall(function() despawn(a) end)
                if a.light then removeLight(a.light) end
                table.remove(anims, i)
            end
        end
    end
end

local function push(anim)
    if #Flight._anims >= MAX_ANIMS then return end
    anim.delay = anim.delay or 0
    anim.elapsed = 0
    Flight._anims[#Flight._anims + 1] = anim
end

--=======================================================================--
-- LAUNCH EFFECTS
--=======================================================================--

-- Damped yaw kick on the deployed tube visual (a "recoil shake").
local function startRecoil(originX, originY, originZ)
    local R = Config.SHELLFX and Config.SHELLFX.recoil
    if not (R and R.enabled) then return end
    local MObj = MortarMod.Object
    if not (MObj and MObj.findVisualParts) then return end
    local sq = Utils.getSquare(originX, originY, originZ)
    if not sq then return end
    local tube
    pcall(function() tube = MObj.findVisualParts(sq).TUBE end)
    local item = tube and tube.getItem and tube:getItem()
    if not item or type(item.setWorldZRotation) ~= "function" then return end
    local base
    pcall(function() base = item:getWorldZRotation() end)
    if type(base) ~= "number" then return end
    push({ kind = "recoil", item = item, base = base,
           duration = R.seconds or 0.45, kick = R.degrees or 4 })
end

-- White powder puff at the muzzle (engine smoke, brief parameters).
local function muzzleSmoke(originX, originY, originZ)
    if not (Config.SHELLFX and Config.SHELLFX.muzzleSmoke) then return end
    local sq = Utils.getSquare(originX, originY, originZ)
    if not sq then return end
    pcall(function()
        if IsoFireManager and IsoFireManager.StartSmoke then
            if ZombRandFloat then
                IsoFireManager.StartSmoke(Utils.getCell(), sq, false, 20, 80)
            else
                IsoFireManager.StartSmoke(Utils.getCell(), sq, true, 1)
            end
        end
    end)
end

--=======================================================================--
-- PUBLIC API
--=======================================================================--

-- Kick off launch + terminal effects for a fired round.
-- Called from the firing UI when the authority confirms the shot.
function Flight.onFired(originX, originY, originZ, bearing, impactX, impactY, impactZ, flightSeconds, shellKey)
    local SF = Config.SHELLFLIGHT
    if not SF or not SF.enabled then return end
    local FX = Config.SHELLFX or {}
    local snd = (FX.enabled and FX.sounds) or {}
    local puppets = SF.puppets and (SF.puppets[shellKey] or SF.puppets.HE)
    flightSeconds = flightSeconds or 0
    bearing = bearing or 0

    ------------------------------------------------------------------
    -- LAUNCH: thump + muzzle flash + powder puff + recoil + climb-out.
    ------------------------------------------------------------------
    playAt(snd.fire, originX, originY, originZ)
    local MF = FX.muzzleFlash
    if MF and MF.enabled then
        push({ kind = "light", x = originX, y = originY, z = originZ,
               spec = MF, duration = MF.seconds or 0.06 })
    end
    muzzleSmoke(originX, originY, originZ)
    startRecoil(originX, originY, originZ)

    -- Never let the two visible phases overlap on very short shots.
    local cap = (flightSeconds > 0) and (flightSeconds * 0.45) or nil
    local ascent = math.max(cap and math.min(SF.ascentSeconds, cap) or SF.ascentSeconds, 0.3)
    local descent = math.max(cap and math.min(SF.descentSeconds, cap) or SF.descentSeconds, 0.3)

    if puppets then
        push({ kind = "puppet", phase = "up", itemType = puppets.up,
               x = originX + 0.5, y = originY + 0.5, z = originZ or 0,
               bearing = bearing, duration = ascent,
               drift = SF.ascentDrift or 3.0, height = SF.ascentHeight or 9.0 })
    end

    ------------------------------------------------------------------
    -- TERMINAL. Illumination pops in the SKY: no landing animation.
    ------------------------------------------------------------------
    if shellKey ~= "ILLUM" and puppets then
        local drift = SF.descentDrift or 1.5
        local sx, sy = Mth.projectBearing(impactX + 0.5, impactY + 0.5, bearing, -drift)
        push({ kind = "puppet", phase = "down", itemType = puppets.down,
               x = sx, y = sy, z = impactZ or 0,
               bearing = bearing, duration = descent, drift = drift,
               height = SF.descentHeight or 8.0,
               delay = math.max(flightSeconds - descent, 0.05) })

        -- Incoming whistle, timed so the clip ENDS at the blast instead of
        -- masking it. Short-range (see sounds_mortar.txt): only heard when
        -- the player is near the target.
        push({ kind = "oneshot",
               delay = math.max(flightSeconds - (FX.incomingLeadSeconds or 1.7), 0.1),
               fn = function() playAt(snd.incoming, impactX, impactY, impactZ) end })
    end

    -- Impact/burst audio at landing time.
    push({ kind = "oneshot", delay = math.max(flightSeconds - 0.05, 0.05),
        fn = function()
            if shellKey == "ILLUM" then
                -- Airburst over the target: distant boom + brief pop flash.
                playDistantBoom(snd.distant, impactX, impactY)
                local IF = FX.illumFlash
                if IF and IF.enabled then
                    push({ kind = "light", x = impactX, y = impactY, z = impactZ,
                           spec = IF, duration = IF.seconds or 1.5 })
                end
            elseif shellKey == "SMOKE" then
                -- Smoke pop only; smoke never uses the distant boom.
                playAt(snd.smokePop, impactX, impactY, impactZ)
            else
                -- HE: full blast up close, rolling boom from afar.
                local px, py = originX, originY
                pcall(function()
                    local pl = Utils.getPlayer()
                    if pl then px, py = pl:getX(), pl:getY() end
                end)
                local dx, dy = impactX - px, impactY - py
                local nearDist = FX.nearDistance or 90
                if (dx * dx + dy * dy) <= nearDist * nearDist then
                    playAt(snd.explosion, impactX, impactY, impactZ)
                else
                    playDistantBoom(snd.distant, impactX, impactY)
                end
            end
        end })
end

--=======================================================================--
-- WIRING
--=======================================================================--

if not Flight._wired then
    Flight._wired = true
    if Events and Events.OnTick then
        Events.OnTick.Add(onTick)
        Log.info("ShellFlight: flight animation + FX installed.")
    else
        Log.warn("ShellFlight: Events.OnTick unavailable; animation disabled.")
    end
end

return Flight
