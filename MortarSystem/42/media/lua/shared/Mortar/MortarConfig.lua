--***********************************************************************--
-- Mortar System  -  MortarConfig.lua
--
-- PURPOSE
--   Single source of truth for every gameplay value in the mod. No balancing
--   number should ever be hardcoded anywhere else in the project; if a system
--   needs a tunable value, it belongs here.
--
-- RESPONSIBILITIES
--   * Declare the global `MortarMod` namespace that every module attaches to.
--   * Hold all default gameplay constants grouped by subsystem.
--   * Overlay user-facing Sandbox options on top of the defaults at runtime
--     (see refreshFromSandbox), so server admins can tune balance in-game.
--
-- EXTENSION POINTS
--   * Add a new field here, optionally expose it through media/sandbox-options.txt
--     and map it inside refreshFromSandbox().
--   * Shell-specific values (blast radius, fire chance ...) live in the shell
--     definitions (MortarShells.lua) so a new shell only needs one registration.
--
-- DATA FLOW
--   MortarConfig is required by virtually every other module. It must remain
--   dependency-free (it may not require any other Mortar module) to avoid load
--   order problems. Heavy/Sandbox-dependent values are resolved at runtime via
--   refreshFromSandbox(), wired from MortarConfig hooks below.
--***********************************************************************--

MortarMod = MortarMod or {}
MortarMod.Config = MortarMod.Config or {}

local Config = MortarMod.Config

--=======================================================================--
-- IDENTITY
--=======================================================================--

-- Network command module name + Sandbox table name + script module name.
-- Keep these in sync with media/scripts/*.txt (module MortarSystem) and
-- media/sandbox-options.txt (option group MortarSystem).
Config.MODULE  = "MortarSystem"
Config.VERSION = "1.0.0"

--=======================================================================--
-- DEBUG / LOGGING
--=======================================================================--

-- Master debug switch. When true, MortarDebug renders overlays and verbose
-- logs are emitted. Can be toggled in-game (default key configurable below)
-- and overridden by the Sandbox option. Ship with this FALSE.
Config.DEBUG = false

-- Logger verbosity. One of: "ERROR", "WARN", "INFO", "DEBUG", "TRACE".
-- INFO is a sensible release default; DEBUG mode bumps this to TRACE at runtime.
Config.LOG_LEVEL = "INFO"

--=======================================================================--
-- ITEM TYPE STRINGS
--   Fully-qualified script item names (module.item). Centralised so the rest
--   of the code never hardcodes a raw item string. Must match items_mortar.txt.
--=======================================================================--

Config.ITEMS = {
    -- The broken-down mortar carried as a single inventory item.
    MORTAR        = "MortarSystem.M224Mortar",

    -- Shells (see MortarShells.lua for per-shell behaviour).
    SHELL_HE      = "MortarSystem.Shell_HE_60",
    SHELL_SMOKE   = "MortarSystem.Shell_Smoke_60",
    SHELL_ILLUM   = "MortarSystem.Shell_Illum_60",

    -- Military-grade plotting tools (best accuracy).
    PLOTTING_BOARD = "MortarSystem.PlottingBoard",
    AIMING_CIRCLE  = "MortarSystem.AimingCircle",
    FIRING_TABLES  = "MortarSystem.FiringTables",

    -- Civilian navigation aids (army surplus, higher scatter).
    COMPASS        = "MortarSystem.OrienteeringCompass",
    MAP_RULER      = "MortarSystem.MapRuler",
}

--=======================================================================--
-- DEPLOYMENT / SETUP
--=======================================================================--

Config.DEPLOY = {
    -- Base durations in REAL seconds (converted to action ticks via Utils).
    setupSeconds      = 8.0,   -- "Set Up Mortar"
    breakdownSeconds  = 6.0,   -- "Break Down Mortar"

    -- Sandbox "Use Nimble/Strength": when false setup/breakdown always take
    -- the base time (no skill speed-up).
    useSkillSpeed     = true,

    -- Skill-based duration scaling. Each level of the skill multiplies the
    -- duration by (1 - perLevel), clamped to `minFactor`.
    nimblePerLevel    = 0.04,  -- Nimble speeds up setup/breakdown
    strengthPerLevel  = 0.02,  -- Strength helps a little too
    minDurationFactor = 0.35,  -- never faster than 35% of base

    -- Footprint of the deployed mortar, expressed as a list of {dx, dy}
    -- offsets from the anchor tile (the tile the player places it on).
    -- TODAY this is a single tile {0,0}. Designed so a future multi-tile
    -- mortar only needs more offsets here -- nothing else assumes 1 tile.
    footprint = {
        { dx = 0, dy = 0 },
    },

    -- Ground eligibility checks performed before "Set Up Mortar" is offered.
    requireOutdoors   = true,  -- no ceiling above (cannot deploy indoors)
    forbidWater       = true,
    forbidFurniture   = true,  -- no existing solid object/furniture on tile
    forbidVehicle     = true,
    forbidStairs      = true,

    -- Strength threshold below which the carried mortar encumbers the player.
    -- (Informational; encumbrance itself comes from item Weight in the script.)
    encumbranceStrength = 7,
}

--=======================================================================--
-- ACTION TIMING / ANIMATION
--=======================================================================--

Config.ACTION = {
    -- Approximate timed-action ticks per real second at normal game speed.
    -- PZ scales action time by framerate/game speed, so treat this as a tuning
    -- knob: if setup feels too fast/slow, adjust this OR the *Seconds values.
    ticksPerSecond = 60,

    -- "Drop Round" animation length before the round actually leaves the tube.
    fireAnimSeconds = 1.5,

    -- Placeholder animation identifiers. Swap for bespoke anims later.
    -- (PZ ships these vanilla anim names; documented in ASSET_CHECKLIST.md.)
    anim = {
        setup    = "Loot",        -- crouched rummage/build loop (placeholder)
        breakdown= "Loot",        -- (placeholder)
        fire     = "PourLiquid",  -- repurposed fuel-pour loop (per design 4.5)
    },
}

--=======================================================================--
-- DEPLOYED MORTAR SPRITES (PLACEHOLDER)
--   Directional sprite names for the world object. These are PLACEHOLDERS.
--   A missing sprite will not crash the game (object stays interactable), but
--   you should replace these with a real 4-direction tile sheet. See
--   ASSET_CHECKLIST.md. Index by IsoDirections name.
--=======================================================================--

Config.SPRITE = {
    -- Placeholder: reuse an existing vanilla object sprite per facing.
    -- Replace `MortarSystem_deployed_*` once a real tile pack exists, and set
    -- usePlaceholderVanilla = false to switch to your custom names.
    usePlaceholderVanilla = true,

    -- Custom (final) sprite base names, one per cardinal facing.
    custom = {
        N = "MortarSystem_deployed_0",
        E = "MortarSystem_deployed_1",
        S = "MortarSystem_deployed_2",
        W = "MortarSystem_deployed_3",
    },

    -- Placeholder vanilla sprite names (visible immediately, no asset pack).
    -- These are generic industrial/utility props; correctness of appearance is
    -- not important for a placeholder, only that something renders.
    placeholder = {
        N = "industry_railroad_01_24",
        E = "industry_railroad_01_25",
        S = "industry_railroad_01_26",
        W = "industry_railroad_01_27",
    },
}

--=======================================================================--
-- CHARGES (ELEVATION / RANGE)
--   Each charge = a propellant increment mapping to a tile range band and a
--   base scatter radius. The firing UI exposes Charge (coarse) plus a fine
--   range slider clamped to [minRange, maxRange]. A new charge is one row.
--=======================================================================--

-- User-facing, these are ELEVATION settings (played as tube angle: steep =
-- close, shallow = far), matching the visual tube pitch. Internally the id
-- still selects the range band + base dispersion exactly as before.
Config.CHARGES = {
    { id = 0, name = "E85", minRange = 10,  maxRange = 60,   baseScatter = 2 },
    { id = 1, name = "E75", minRange = 50,  maxRange = 160,  baseScatter = 3 },
    { id = 2, name = "E65", minRange = 140, maxRange = 350,  baseScatter = 5 },
    { id = 3, name = "E55", minRange = 320, maxRange = 650,  baseScatter = 8 },
    { id = 4, name = "E45", minRange = 600, maxRange = 1000, baseScatter = 12 },
}

Config.RANGE = {
    -- Hard global minimum (design 9.2: ~73 m / ~10 tiles min safe distance).
    -- A fire solution closer than this to the tube is rejected.
    minRangeTiles = 10,

    -- Hard global maximum safety clamp (matches the top charge band).
    maxRangeTiles = 1000,
}

--=======================================================================--
-- SHELL FLIGHT TIME (distance-based; the round is airborne for real seconds)
--=======================================================================--

Config.FLIGHT = {
    enabled = true,

    -- t = factor * sqrt(2 * range / 9.81) seconds -- the ideal 45-degree
    -- ballistic arc at 1 tile = 1 m, with `factor` fudging in drag and the
    -- high lob of a real 60mm round. Roughly 7 s at 100 tiles and ~21 s at
    -- 1000 tiles with factor 1.5 (comparable to real mortar flight times).
    factor = 1.5,

    minSeconds = 2.0,
    maxSeconds = 45.0,
}

--=======================================================================--
-- SCATTER MODIFIERS
--   The final scatter radius is:
--     baseScatter[charge]
--       * toolMult * skillMult * conditionMult
--       * product(active moodle mults) * product(active weather mults)
--   All factors are multiplicative (design 5.3). See MortarScatter.lua.
--=======================================================================--

Config.SCATTER = {
    -- Plotting tool tiers (best available kit wins). Keys map to tool tiers
    -- resolved in MortarInventory.getToolTier().
    tool = {
        FULL_KIT     = 1.0,  -- board + aiming circle + firing tables
        BOARD_TABLES = 1.3,  -- board + tables (no aiming circle)
        COMPASS      = 2.0,  -- orienteering compass only
        RULER        = 2.5,  -- map ruler only
        -- NONE => cannot fire (handled separately; not a multiplier)
    },

    -- Sandbox "Use Aiming skill": when false the skill multiplier is a flat
    -- 1.0 regardless of the operator's Aiming level.
    useAimingSkill = true,

    -- Aiming skill bands -> multiplier. Evaluated by MortarScatter.
    skill = {
        { min = 6, max = 10, mult = 0.75 },
        { min = 3, max = 5,  mult = 1.00 },
        { min = 0, max = 2,  mult = 1.50 },
    },

    -- Moodle multipliers. Each entry is applied if its predicate (in
    -- MortarMoodles) is currently true. Stored as data so balancing is here.
    moodle = {
        panicModerate = 1.30,
        panicExtreme  = 1.70,
        tiredVery     = 1.20,
        drunk         = 1.60,
        injured       = 1.20,
        thermal       = 1.30,  -- hyperthermia OR hypothermia active
    },

    -- Weather multipliers (see MortarWeather for thresholds & resolution).
    weather = {
        windCalm   = 1.00,  -- < windLightMph
        windLight  = 1.15,  -- windLightMph .. windModerateMph
        windStrong = 1.40,  -- windModerateMph .. windStormMph
        windStorm  = 1.80,  -- > windStormMph
        rainLight  = 1.05,
        rainHeavy  = 1.20,
        fog        = 1.10,
    },

    -- Condition (durability) influence on scatter. At full condition the
    -- multiplier is 1.0; at zero condition it reaches maxConditionMult.
    -- Interpolated linearly by MortarScatter using the deployed mortar's
    -- condition fraction (0..1).
    maxConditionMult = 1.5,

    -- Distance factor: accuracy degrades with range (closer = tighter).
    -- Final multiplier = lerp(distanceMinMult, distanceMaxMult,
    --                         range / RANGE.maxRangeTiles).
    distanceMinMult = 0.25,
    distanceMaxMult = 1.60,

    -- Absolute clamp on the final radius so extreme stacking can't produce an
    -- absurd (or zero) value.
    minRadius = 0.5,
    maxRadius = 60.0,
}

--=======================================================================--
-- WEATHER THRESHOLDS
--   Raw climate readings are bucketed here. MortarWeather reads these.
--=======================================================================--

Config.WEATHER = {
    -- Wind speed thresholds in MPH (climate manager value is normalised 0..1
    -- and converted to an approximate MPH inside MortarWeather).
    windLightMph    = 5,
    windModerateMph = 15,
    windStormMph    = 30,
    windMaxMph      = 60,   -- assumed wind speed at climate intensity 1.0

    -- Rain intensity (0..1) thresholds.
    rainLight = 0.15,
    rainHeavy = 0.55,

    -- Fog intensity (0..1) threshold for the "foggy" multiplier.
    fog = 0.35,
}

--=======================================================================--
-- EXPLOSION (generic; per-shell specifics live in MortarShells.lua)
--=======================================================================--

Config.EXPLOSION = {
    -- Native blast power passed to IsoFireManager.explode(cell, square, power).
    -- Vanilla uses ~100 for a normal blast. Tune for feel; per-shell override
    -- via shell.power. Only used on the native path; the manual fallback uses
    -- the shell blast radius instead.
    power = 110,

    -- Probability (0..1) a tile within the blast becomes fire when the shell's
    -- fireSpread flag is set. Final per-shell chance = this * shell.fireChance.
    baseFireChance = 0.35,

    -- Fire intensity/lifetime passed to the fire manager.
    fireIntensity  = 60,

    -- Chance (0..1) a destructible structure object (window/door/light wall)
    -- inside the blast is destroyed.
    structureDamageChance = 0.6,

    -- Character damage model inside the blast. Damage falls off linearly with
    -- distance from impact. Zombies are killed within killRadiusFraction of the
    -- blast radius; beyond that they take `outerDamage`.
    killRadiusFraction = 0.6,
    outerZombieDamage  = 40,   -- health damage to zombies in the outer ring
    playerCoreDamage   = 90,   -- catastrophic to players near ground zero
    playerOuterDamage  = 25,   -- players in the outer ring

    -- Top-down structural destruction (reworked):
    --   fullRadius    tiles around impact where the top `levelsFromTop` floor
    --                 levels of any structure are levelled outright, and where
    --                 ground charring permanently swaps the floor sprite.
    --   damageRadius  tiles around impact where structures take heavy damage
    --                 (windows/doors/furniture); charring here is a REMOVABLE
    --                 burnt overlay object instead of a floor sprite swap.
    destroy = {
        fullRadius    = 2,
        damageRadius  = 5,
        levelsFromTop = 2,
        maxScanZ      = 31,   -- highest level scanned for "top of building"
    },
}

--=======================================================================--
-- NOISE (zombie attraction)  -  intentionally enormous (design 1.1 / 9.7)
--=======================================================================--

Config.NOISE = {
    -- World-sound radius (tiles) and volume. A mortar impact is meant to draw
    -- zombies from a very wide area. Tune for balance.
    radius = 250,
    volume = 250,

    -- Smaller, local sound made by the tube firing (at the mortar position).
    fireRadius = 40,
    fireVolume = 40,
}

--=======================================================================--
-- CHUNK FORCE-LOADING (so off-screen impacts actually detonate; design 6.1)
--=======================================================================--

Config.CHUNK = {
    -- B42 has NO Lua API to force-load arbitrary off-screen terrain (verified).
    -- So when a round lands on an UNLOADED chunk we defer the physical blast
    -- until that terrain streams in (LoadGridsquare), while the huge noise event
    -- still fires immediately (it is coordinate-based and needs no terrain).
    --
    -- How long (in-game minutes) a deferred detonation waits for its terrain to
    -- load before it is discarded. Prevents a fire mission into the far map from
    -- detonating days later when a player finally wanders past.
    deferTtlMinutes = 20,
}

--=======================================================================--
-- CONDITION / DURABILITY
--=======================================================================--

Config.CONDITION = {
    -- Condition scale. Stored on both the inventory item and deployed object.
    max = 100,

    -- Condition lost per fired round (HE/smoke/illum all wear the tube).
    wearPerFire = 1.0,

    -- Below this condition the mortar may misfire (round fails to leave tube,
    -- shell wasted, no explosion). 0 disables misfires.
    misfireBelow = 25,

    -- Misfire probability at 0 condition (scales linearly from misfireBelow).
    misfireMaxChance = 0.25,

    -- Condition restored by a full repair recipe (see recipes_mortar.txt).
    repairAmount = 50,
}

--=======================================================================--
-- XP (design 7.2)
--=======================================================================--

Config.XP = {
    -- Master switch (Sandbox "Gain skill XP"): when false no XP is awarded.
    gainXP            = true,

    firePerimeterPerk = "Aiming",  -- perk awarded on every fire
    firePerk          = "Aiming",
    nimblePerk        = "Nimble",

    fireXP            = 20,   -- successful fire (any shell)
    accuracyBonusXP   = 15,   -- impact within accuracyTiles of intended target
    accuracyTiles     = 3,
    setupBreakdownXP  = 5,    -- Nimble XP for setup OR breakdown
}

--=======================================================================--
-- SMOKE SHELL (design 6.2 / 6.3)
--=======================================================================--

Config.SMOKE = {
    durationMinutes = 60,   -- in-game minutes the cloud persists
    radius          = 3,    -- tiles of smoke around impact
    -- Placeholder smoke sprite used if no native smoke spawner is available.
    placeholderSprite = "MortarSystem_smoke_0",
}

--=======================================================================--
-- ILLUMINATION SHELL (design 9.6 -- functional, not just a stub)
--=======================================================================--

Config.ILLUM = {
    durationMinutes = 30,   -- in-game minutes the flare burns
    radius          = 50,   -- light radius (tiles) => ~100-tile lit diameter
    -- Warm flare colour (0..1 RGB) and brightness.
    r = 1.0, g = 0.92, b = 0.70,
    intensity = 1.0,
    -- Slight drift each in-game minute to mimic a descending parachute flare.
    driftTilesPerMinute = 0.2,
    -- Fading: full brightness until this fraction of the burn has elapsed,
    -- then the lit radius shrinks linearly down to minFadeRadius at expiry.
    fadeStartFraction = 0.6,
    minFadeRadius     = 6,
    -- The engine renders one huge light poorly (visually caps out well below
    -- `radius`), so the flare's coverage is built from a grid of overlapping
    -- lamp-sized lights. This is the per-lamp radius.
    lampRadius        = 22,
    -- Illum-specific maximum range (tiles); enforced via the shell definition
    -- (MortarShells.lua reads this), not by new targeting logic.
    maxRangeTiles     = 500,
}

--=======================================================================--
-- LOOT SPAWNING (see server/Mortar/MortarDistributions.lua)
--   Relative multipliers applied to every spawn weight in that file's
--   buckets. 0 disables that category entirely. Sandbox-tunable.
--=======================================================================--

Config.LOOT = {
    hardwareMult = 1.0,   -- mortar + military plotting kit
    ammoMult     = 1.0,   -- all shells
    toolsMult    = 1.0,   -- civilian compass / map ruler
}

--=======================================================================--
-- SPOTTER / MAP PLOTTING (target acquisition abstraction; design 9.8)
--=======================================================================--

Config.SPOTTER = {
    enabled = true,

    -- A plotted fire mission expires after this many in-game minutes so stale
    -- coordinates aren't reused indefinitely.
    solutionTtlMinutes = 30,

    -- Extra scatter applied to spotter-provided solutions, by the tool used to
    -- plot. Multiplies the normal tool tier. 1.0 = no extra penalty.
    plotAccuracyByTool = {
        FULL_KIT     = 1.0,
        BOARD_TABLES = 1.05,
        COMPASS      = 1.2,
        RULER        = 1.35,
    },
}

--=======================================================================--
-- 3D MODELS (deployed mortar visuals; see media/scripts/models_mortar.txt)
--=======================================================================--

Config.MODEL = {
    -- Master switch. When true the deployed mortar renders as two 3D parts
    -- (static baseplate + tube assembly rotated to the aim bearing) via world
    -- items with WorldStaticModel, and the interactable anchor object uses an
    -- invisible sprite. When false, everything behaves like the legacy 2D
    -- placeholder-sprite mortar.
    enabled = true,

    -- Item types whose WorldStaticModel carries each deployed part visual.
    baseplateItem = "MortarSystem.MortarBaseplatePart",
    tubeItem      = "MortarSystem.MortarTubePart",

    -- World item Z-rotation applied to the tube part:
    --   yaw = tubeYawSign * bearing + tubeYawOffset   (degrees)
    -- If in-game the tube visually points 90/180 degrees away from the aim
    -- bearing, correct it here instead of re-exporting the mesh.
    -- 150 = playtested: the mesh ships facing 180 deg backwards and 45 deg
    -- clockwise of the bearing (+180 - 45 = 135), plus a further 15 deg
    -- clockwise trim requested after testing.
    tubeYawSign   = 1,
    tubeYawOffset = 150,

    -- Visual tube elevation. World items cannot be pitched at runtime, so
    -- the tube mesh ships baked at several elevations (rotated around the
    -- hinge) and the deployed part is swapped to the nearest step:
    --   elevation = maxDeg at minimum range -> minDeg at maximum range,
    -- interpolated linearly (closer target = steeper tube, like real
    -- high-angle mortar fire). A mortar with no solution yet uses the
    -- middle step.
    tubeElevation = {
        minDeg = 45,
        maxDeg = 85,
        items = {
            { deg = 45, item = "MortarSystem.MortarTubePart_E45" },
            { deg = 55, item = "MortarSystem.MortarTubePart_E55" },
            { deg = 65, item = "MortarSystem.MortarTubePart_E65" },
            { deg = 75, item = "MortarSystem.MortarTubePart_E75" },
            { deg = 85, item = "MortarSystem.MortarTubePart_E85" },
        },
    },
}

--=======================================================================--
-- SHELL FLIGHT ANIMATION (client-side eye candy; see MortarShellFlight.lua)
--   The round is briefly visible climbing out of the tube along the aim
--   bearing, despawns for the cruise phase, then reappears nose-down above
--   the impact point and falls in just before the blast.
--=======================================================================--

Config.SHELLFLIGHT = {
    enabled = true,

    -- Launch phase (fast: a real round leaves the muzzle violently).
    ascentSeconds = 0.6,   -- capped at 45% of the flight time
    ascentHeight  = 9.0,   -- render-height units climbed before despawning
    ascentDrift   = 3.0,   -- tiles travelled along the bearing while climbing

    -- Terminal phase (ends exactly at the impact tile at landing time).
    descentSeconds = 0.7,  -- capped at 45% of the flight time
    descentHeight  = 8.0,
    descentDrift   = 1.5,

    -- Visual yaw of the puppet = bearing + yawOffset (same convention as the
    -- tube; the meshes are exported from the same axis setup).
    yawOffset = 150,

    -- Reposition the puppet every N render ticks (1 = every frame).
    updateTicks = 2,

    -- Puppet item types by shell key (color-matched up/down pairs).
    puppets = {
        HE    = { up = "MortarSystem.ShellPuppetUp_HE",    down = "MortarSystem.ShellPuppetDown_HE" },
        SMOKE = { up = "MortarSystem.ShellPuppetUp_Smoke", down = "MortarSystem.ShellPuppetDown_Smoke" },
        ILLUM = { up = "MortarSystem.ShellPuppetUp_Illum", down = "MortarSystem.ShellPuppetDown_Illum" },
    },
}

--=======================================================================--
-- FIRE-CONTROL HUD
--=======================================================================--

Config.UI = {
    -- The HUD stands down automatically when the operator moves farther than
    -- this many tiles (centre-to-centre) from the gun. Adjacent operation
    -- (including diagonals, ~1.4) stays open; stepping a tile away closes it.
    closeDistanceTiles = 1.9,
}

--=======================================================================--
-- SHELL AUDIO / LAUNCH VFX (client-side; see MortarShellFlight.lua)
--=======================================================================--

Config.SHELLFX = {
    enabled = true,

    -- Sound script names (media/scripts/sounds_mortar.txt -> media/sound/).
    sounds = {
        fire      = "MortarFire",       -- launch thump at the tube
        incoming  = "MortarIncoming",   -- descent whistle at the target
        explosion = "MortarExplosion",  -- HE impact heard up close
        smokePop  = "MortarSmokePop",   -- smoke shell burst
        distant   = "MortarDistant",    -- far-off boom (HE afar + illum airburst)
    },

    -- Player-to-impact distance (tiles) beyond which an HE impact plays the
    -- distant boom instead of the close explosion. (Smoke never goes distant.)
    nearDistance = 90,

    -- How long before impact the incoming whistle starts. Matched to the
    -- whistle clip length (~1.65 s) so it ENDS at the blast instead of
    -- masking it.
    incomingLeadSeconds = 1.7,

    -- Launch effects at the tube.
    muzzleFlash = {
        enabled = true,
        seconds = 0.06,                    -- 1-2 frames of orange flash
        r = 1.0, g = 0.55, b = 0.22,
        radius  = 10,
    },
    muzzleSmoke = true,                    -- white powder puff (engine smoke fx)
    recoil = {
        enabled = true,
        seconds = 0.45,                    -- damped tube kick after firing
        degrees = 4,                       -- peak yaw deflection of the visual
    },

    -- Illumination airburst: the round pops in the sky over the target (no
    -- landing animation); this is the brief pop flash - the lasting light
    -- comes from the illumination system itself.
    illumFlash = {
        enabled = true,
        seconds = 1.5,
        r = 1.0, g = 0.95, b = 0.80,
        radius  = 14,
    },
}

--=======================================================================--
-- KEYBINDS (defaults; remappable in-game options)
--=======================================================================--

Config.KEYBINDS = {
    toggleDebug = "F8",   -- toggle debug overlays (only when DEBUG features on)
}

--=======================================================================--
-- SANDBOX OVERLAY
--   Map server-tunable Sandbox options onto the defaults above. Called on
--   game boot/start. Safe to call repeatedly. Any option absent leaves the
--   coded default untouched, so the mod works even without sandbox-options.txt.
--=======================================================================--

function Config.refreshFromSandbox()
    local SV = SandboxVars and SandboxVars.MortarSystem
    if not SV then return end

    local function num(v, fallback)
        if v == nil then return fallback end
        return v
    end

    -- Debug / logging
    if SV.DebugMode ~= nil then Config.DEBUG = SV.DebugMode end
    if Config.DEBUG then Config.LOG_LEVEL = "TRACE" end

    -- Deployment timing
    Config.DEPLOY.setupSeconds     = num(SV.SetupSeconds,     Config.DEPLOY.setupSeconds)
    Config.DEPLOY.breakdownSeconds = num(SV.BreakdownSeconds, Config.DEPLOY.breakdownSeconds)

    -- Range
    Config.RANGE.minRangeTiles = num(SV.MinRangeTiles, Config.RANGE.minRangeTiles)

    -- Noise
    Config.NOISE.radius = num(SV.NoiseRadius, Config.NOISE.radius)
    Config.NOISE.volume = num(SV.NoiseVolume, Config.NOISE.volume)

    -- Chunk loading
    Config.CHUNK.radius = num(SV.ChunkRadius, Config.CHUNK.radius)

    -- Condition
    Config.CONDITION.wearPerFire  = num(SV.ConditionWearPerFire, Config.CONDITION.wearPerFire)
    Config.CONDITION.misfireBelow = num(SV.MisfireBelow,         Config.CONDITION.misfireBelow)

    -- XP
    Config.XP.fireXP          = num(SV.FireXP,         Config.XP.fireXP)
    Config.XP.accuracyBonusXP = num(SV.AccuracyBonusXP, Config.XP.accuracyBonusXP)
    if SV.GainSkillXP ~= nil then Config.XP.gainXP = SV.GainSkillXP end

    -- Skill usage toggles
    if SV.UseAimingSkill ~= nil then Config.SCATTER.useAimingSkill = SV.UseAimingSkill end
    if SV.UseNimbleStrength ~= nil then Config.DEPLOY.useSkillSpeed = SV.UseNimbleStrength end

    -- Loot spawn multipliers
    Config.LOOT.hardwareMult = num(SV.HardwareSpawnMult, Config.LOOT.hardwareMult)
    Config.LOOT.ammoMult     = num(SV.AmmoSpawnMult,     Config.LOOT.ammoMult)
    Config.LOOT.toolsMult    = num(SV.ToolSpawnMult,     Config.LOOT.toolsMult)

    -- Global scatter scalar (a single "difficulty" knob multiplying everything)
    Config.scatterGlobalScalar = num(SV.ScatterGlobalScalar, 1.0)

    -- Smoke / illum duration
    Config.SMOKE.durationMinutes = num(SV.SmokeMinutes, Config.SMOKE.durationMinutes)
    Config.ILLUM.durationMinutes = num(SV.IllumMinutes, Config.ILLUM.durationMinutes)
end

-- Global scatter scalar default (used even if sandbox not present).
Config.scatterGlobalScalar = Config.scatterGlobalScalar or 1.0

--=======================================================================--
-- CHARGE LOOKUP HELPERS (pure; no external deps)
--=======================================================================--

-- Return the charge definition table for a numeric charge id, or nil.
function Config.getCharge(chargeId)
    for _, c in ipairs(Config.CHARGES) do
        if c.id == chargeId then return c end
    end
    return nil
end

-- Number of defined charges.
function Config.chargeCount()
    return #Config.CHARGES
end

return Config
