-- DIExtraction: carrier-extraction custom mode (approach A, natural grab).
-- Waits for VAULT_LOCKED, fires the game's own timer-expiry phase transition
-- into VAULT_UNLOCKED, then teleports the designated carrier next to the live
-- BP_Briefcase so they grab it through the game's own pickup. Everything after
-- that (carrier state, KillCarrier objectives, extraction call, win/lose) is
-- the game's stock endgame flow.
--
-- Safety rules (see spectator-lua-safety): never retain UE4SS UObject wrappers
-- across ticks; reacquire everything by FindAllOf inside each callback; pcall
-- every engine touch; validate phase before mutating.
local OUT = "DIExtraction.log"
local TRIGGER = "DIExtraction.trigger"
local RECON = "DIExtraction.recon"
local LOADOUT = "DIExtraction.loadout"
local DISGUISE = "DIExtraction.disguise"
local RESCUE = "DIExtraction.rescue"

-- EGameplayResourcesType (CXXHeaderDump, build 24975521). Only the entries a
-- player actually spends in a match: intel ("chips"), the four keycards, and
-- every gadget/ability charge. Deliberately EXCLUDED: Mission_Objective (8) is
-- the briefcase itself, and the PowerupModule*/Kill/SpyCache/LimitedEvent
-- entries are internal bookkeeping counters, not player-facing pickups.
local GRANTABLE_RESOURCES = {
    { 1,  "Ammo" },
    { 2,  "Health" },
    { 3,  "Intel" },
    { 4,  "Keycard_Green" },
    { 5,  "Keycard_Blue" },
    { 6,  "Keycard_Purple" },
    { 7,  "Keycard_Orange" },
    { 9,  "Charge_BouncingMat" },
    { 10, "Charge_UmbrellaShield" },
    { 11, "Charge_Turret" },
    { 12, "Charge_Scrambler" },
    { 13, "Charge_HackTrap" },
    { 14, "Charge_Drone" },
    { 15, "Charge_DroneDart" },
    { 16, "Charge_GooPod" },
    { 17, "Charge_Tripwire" },
    { 18, "Charge_SpyGlass" },
    { 19, "Charge_OcclusionGadget" },
    { 20, "Charge_SoundMachine" },
    { 21, "Charge_NPCBug" },
    { 22, "Charge_Active" },
    { 23, "Charge_HealthConsumable" },
    { 24, "Charge_OverchargedNavmode" },
    -- The upgrade "chips": PowerupModule_* are the modules looted from NPCs
    -- that level an equipped powerup, and PowerupModuleLevel_* track the NPC
    -- security tier a module came from. An earlier version wrote these off as
    -- internal counters and granted no chips at all, which is why a grant
    -- produced every keycard but nothing in the powerup row.
    { 25, "PowerupModule_Cover" },
    { 26, "PowerupModule_Ammo" },
    { 27, "PowerupModule_Intel" },
    { 28, "PowerupModule_Hacking" },
    { 29, "PowerupModule_Health" },
    { 30, "PowerupModule_Expertise" },
    { 36, "PowerupModuleLevel_Civilian" },
    { 37, "PowerupModuleLevel_Staff" },
    { 38, "PowerupModuleLevel_Guard" },
    { 39, "PowerupModuleLevel_Technician" },
    { 40, "PowerupModuleLevel_VIP" },
}

-- ESecurityLevel. The game exposes no colour names, but the four keycards run
-- Green < Blue < Purple < Orange while the four non-Civilian tiers run Staff <
-- Guard < Technician < VIP, so purple lines up with Technician. That mapping is
-- an inference from the ordering, not something the dump states outright.
local SECURITY_LEVELS = {
    civilian = 0, staff = 1, guard = 2, technician = 3, vip = 4,
    green = 1, blue = 2, purple = 3, orange = 4,
}
local SECURITY_LEVEL_NAMES = {
    [0] = "Civilian", [1] = "Staff", [2] = "Guard",
    [3] = "Technician", [4] = "VIP",
}
-- Re-applied on deploy while set, so the carrier starts the extraction phase
-- already wearing it rather than having to ask for it after spawning.
local desired_disguise = nil
-- Forward declaration: extraction_tick re-applies the disguise but is defined
-- above apply_disguise, and without this the name would resolve to a nil global
-- there instead of to the local below.
local apply_disguise
local grant_full_resources
local grant_full_resources_pawn
local grant_full_resources_all
-- Set from DIConfig.ini; kitting the carrier out is a once-per-match action, so
-- it is latched rather than repeated every tick.
local auto_loadout = false
local carrier_prepared = false
-- Instant-brawl gathering: when the vault opens, every spy in the level --
-- humans and bots alike -- is dropped in a ring around the objective, so the
-- match resolves as one fight over the case instead of a hunt across the map.
-- [Extraction] GatherAll = 0 restores the carrier-only delivery.
local gather_all = true
local gather_done = false
-- Bot freeze. The fast-forward opens the vault about ten seconds into the
-- match, which can be before a human client has finished loading in -- they
-- then arrive to bots already shooting each other. While any human is still
-- loading, every bot spy is held still and disarmed, and the phase advance
-- waits with them. [Extraction] FreezeBots = 0 turns it off.
local freeze_bots = true
local freeze_grace = 5           -- seconds of calm after the last human is ready
local freeze_max_wait = 30       -- give up waiting and play anyway after this
local bots_released = false
local freeze_wait_started = nil  -- os.time() when the hold began
local humans_ready_since = nil   -- os.time() when every human first read ready
local frozen_modes = {}          -- pawn full name -> EMovementMode before freeze
local freeze_logged = nil        -- last line logged, so the hold does not spam

-- ESpyGamePhase (CXXHeaderDump, build 24975521)
local PHASE_NAMES = {
    [0] = "LOADING", [1] = "PREGAME", [2] = "POSING_SPY_INTRO",
    [3] = "VAULT_LOCKED", [4] = "VAULT_UNLOCKED", [5] = "EXTRACTION_ARRIVING",
    [6] = "EXTRACTION_ARRIVED", [7] = "RESULT_SCREEN", [8] = "GAME_FINISHED",
}
local PHASE_BY_NAME = {}
for value, name in pairs(PHASE_NAMES) do PHASE_BY_NAME[name] = value end

-- armed-mode state. Plain Lua values only (string/bool/number) -- never a
-- UObject wrapper. carrier_filter is a case-insensitive player-name substring;
-- nil designates the first human connection.
local armed = false
local carrier_filter = nil
local advance_attempted = false
local last_logged_phase = nil
local teleport_attempts = 0
local TELEPORT_MAX_ATTEMPTS = 12

-- NOTE ON THREADS, paid for in four crashed servers. LoopAsync runs its
-- callback on its OWN thread, so every UFunction here is a cross-thread call
-- into the engine. `ExecuteInGameThread` exists and looks like the fix, but
-- using it for PART of a tick is worse than not using it at all: the closure
-- runs Lua on the game thread while the tick is still running Lua on the async
-- thread, two threads enter one lua_State, and the server dies with the whole
-- callstack inside ue4ss.dll. Everything in this mod therefore runs on the one
-- async thread, and the operations that cannot survive that (see the bot
-- loadout below) are simply not performed.
local function append(line)
    local fh = io.open(OUT, "a")
    if fh then
        fh:write(os.date("!%Y-%m-%dT%H:%M:%SZ") .. " " .. tostring(line) .. "\n")
        fh:close()
    end
end

-- UE4SS raises errors whose value is sometimes a function rather than a
-- string, which rendered every failed call as an opaque "function: 0x...".
-- Calling it usually yields the real message.
local function describe_error(err)
    if type(err) ~= "function" then return tostring(err) end
    local ok, unwrapped = pcall(err)
    if ok and unwrapped ~= nil then return tostring(unwrapped) end
    return "<function error, message unavailable>"
end

local function full(object)
    if object == nil then return "<nil>" end
    local rendered
    if pcall(function() rendered = object:GetFullName() end) and rendered then return rendered end
    if pcall(function() rendered = object:ToString() end) and rendered then return rendered end
    return "<unrenderable>"
end

local function unwrap(value)
    if value == nil then return nil end
    local kind
    pcall(function() kind = value:type() end)
    if kind == "LocalUnrealParam" or kind == "RemoteUnrealParam" then
        local inner
        pcall(function() inner = value:get() end)
        return inner
    end
    return value
end

-- Render a scalar/enum property as text. Enum properties come back as a number
-- on some paths and as userdata on others, so both are handled.
local function scalar_property(object, name)
    local value = "<unavailable>"
    pcall(function()
        local raw = object[name]
        if raw == nil then
            value = "<nil>"
        elseif type(raw) == "boolean" or type(raw) == "number" or
               type(raw) == "string" then
            value = tostring(raw)
        else
            local rendered
            if pcall(function() rendered = raw:ToString() end) and rendered then
                value = tostring(rendered)
            else
                value = tostring(raw)
            end
        end
    end)
    return value
end

-- UE4SS hands back a Lua wrapper even when the underlying UObject pointer is
-- NULL, so `~= nil` is not a validity test -- and calling a UFunction on one of
-- those exits the server with status 3 and NOTHING in any log. That is exactly
-- how the everyone-loadout died on its first bot: a bot's PlayerState wrapper
-- read non-nil, GetPlayerName() went through it, and the process was gone
-- before the next line could be written. Anything that came from a property
-- read goes through here before it is touched.
local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    if ok and type(result) == "boolean" then return result end
    -- No IsValid on this wrapper: fall back to whether it can name itself.
    local name = full(object)
    return name ~= "<nil>" and name ~= "<unrenderable>"
end

local function is_live(object)
    if not valid(object) then return false end
    local name = full(object)
    return name ~= "<nil>" and name ~= "<unrenderable>" and
           not name:find("Default__", 1, true)
end

local function find_live_game_state()
    local states
    pcall(function() states = FindAllOf("DeceiveIncMatchGameState") end)
    if not states then
        pcall(function() states = FindAllOf("GameStateBase") end)
    end
    if not states then return nil end
    for i = 1, #states do
        if is_live(states[i]) then return states[i] end
    end
    return nil
end

-- GamePhase arrives as a number, an enum userdata, or a rendered string
-- depending on the UE4SS property path; normalize all three to the number.
local function current_phase(game_state)
    local raw
    if not pcall(function() raw = unwrap(game_state.GamePhase) end) then
        return nil
    end
    if raw == nil then return nil end
    if type(raw) == "number" then return raw end
    local n = tonumber(raw)
    if n then return n end
    local text
    pcall(function() text = tostring(raw:ToString()) end)
    if text == nil then pcall(function() text = tostring(raw) end) end
    if type(text) == "string" then
        local bare = text:gsub("^ESpyGamePhase::", "")
        if PHASE_BY_NAME[bare] then return PHASE_BY_NAME[bare] end
    end
    return nil
end

local function phase_label(phase)
    if phase == nil then return "<unknown>" end
    return (PHASE_NAMES[phase] or "?") .. "(" .. tostring(phase) .. ")"
end

-- The short object name, e.g. "BPSpy_Chavez_Main_V1_C_2147472725". Costs no
-- UFunction call, so it is always safe to log even when nothing else about an
-- object can be trusted.
local function short_name(object)
    local name = full(object)
    return name:match("([^.]+)$") or name
end

local function player_name_of(controller)
    local name
    pcall(function()
        local state = unwrap(controller.PlayerState)
        if valid(state) then
            name = tostring(state:GetPlayerName():ToString())
        end
    end)
    return name
end

-- A real remote player, as opposed to one of the game's bot players. The
-- decisive test on a dedicated server is NetConnection: every human arrives
-- over one and no bot has one. ASpy.bIsBot (the game's own flag) and the
-- engine's PlayerState.bIsABot are checked as corroboration, so a bot is
-- rejected even if the connection read fails.
local function is_human(controller)
    local connected = false
    pcall(function() connected = unwrap(controller.NetConnection) ~= nil end)
    if not connected then
        pcall(function() connected = unwrap(controller.Player) ~= nil end)
    end
    if not connected then return false end
    local bot = false
    pcall(function()
        local state = unwrap(controller.PlayerState)
        if state and state.bIsABot == true then bot = true end
    end)
    pcall(function()
        local pawn = unwrap(controller.Pawn)
        if pawn and pawn.bIsBot == true then bot = true end
    end)
    return not bot
end

-- The designated carrier's live controller: name-substring match when a
-- filter was given, otherwise the first human connection.
local function find_carrier_controller()
    local controllers
    pcall(function() controllers = FindAllOf("DeceiveIncPlayerController") end)
    if not controllers then return nil, "no controllers in world" end
    local fallback = nil
    for i = 1, #controllers do
        local controller = controllers[i]
        if is_live(controller) and is_human(controller) then
            local name = player_name_of(controller)
            if carrier_filter == nil then
                return controller, nil
            elseif name and name:lower():find(carrier_filter:lower(), 1, true) then
                return controller, nil
            end
            fallback = fallback or controller
        end
    end
    if carrier_filter and fallback then
        return nil, "no human player matches '" .. carrier_filter ..
                    "' (a human is connected; check the name)"
    end
    return nil, "no human player connected"
end

-- Not every BP_Briefcase_C is the briefcase sitting in the vault. Each spy
-- carries a display-only instance parented under it as the
-- EGameplayResourcesType::Mission_Objective item cache; a live run picked one
-- of those and "teleported" the carrier onto its own position. The real
-- objective is the one owned by the level: no attach parent, and a plain
-- BP_Briefcase_C_<n> object name rather than a spy-prefixed ItemCache name.
local function is_world_briefcase(case)
    if not is_live(case) then return false end
    local name = full(case)
    local short = name:match("([^.]+)$") or name
    if short:find("ItemCache", 1, true) then return false end
    if not short:find("^BP_Briefcase_C") then return false end
    local attached
    pcall(function() attached = unwrap(case:GetAttachParentActor()) end)
    if attached ~= nil then return false end
    return true
end

local function actor_location(actor)
    local location
    pcall(function() location = actor:K2_GetActorLocation() end)
    return location
end

-- A teleport destination is only usable if it is a real point in the level.
-- BP_VaultZone_C is a trigger VOLUME whose actor origin reads (0, 0, 0): the
-- shape lives in its components, not its transform. Teleporting to that origin
-- put a live player under the map on Fragrant Shore. Anything at or near the
-- world origin is therefore rejected outright.
-- Forward declaration: the objective probe below logs positions but sits above
-- this helper's definition, where a bare name would resolve to a nil global.
local vector_text

local function is_usable_location(location)
    if location == nil then return false end
    local x, y, z
    if not pcall(function() x, y, z = location.X, location.Y, location.Z end) then
        return false
    end
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return false
    end
    if x ~= x or y ~= y or z ~= z then return false end -- NaN
    if (x * x + y * y + z * z) < (100 * 100) then return false end
    return true
end

-- Where to deliver the carrier: the real world briefcase, or the level's
-- objective pedestal. Volume-style actors are deliberately NOT used as
-- fallbacks. If nothing usable exists the mode waits rather than teleporting
-- somewhere invented -- doing nothing is always better than dropping a player
-- out of the world.
local function find_objective_target()
    local cases
    pcall(function() cases = FindAllOf("BP_Briefcase_C") end)
    if cases then
        for i = 1, #cases do
            if is_live(cases[i]) then
                append("  briefcase candidate: " .. full(cases[i]) ..
                       " world=" .. tostring(is_world_briefcase(cases[i])) ..
                       " loc_ok=" ..
                       tostring(is_usable_location(actor_location(cases[i]))))
            end
        end
        for i = 1, #cases do
            if is_world_briefcase(cases[i]) and
               is_usable_location(actor_location(cases[i])) then
                return cases[i], "briefcase"
            end
        end
    end
    -- Pedestal first where it exists (Diamondspire), then the objective
    -- terminal. Note the terminal's odd casing -- lowercase 'p' in "Bp_" -- and
    -- that it is the only anchor present on EVERY map probed so far: Fragrant
    -- Shore has no pedestal at all.
    for _, class_name in ipairs({ "BP_DS_ObjectivePedestal_C",
                                  "Bp_Objective_Terminal_C" }) do
        local actors
        pcall(function() actors = FindAllOf(class_name) end)
        if actors then
            for i = 1, #actors do
                if is_live(actors[i]) and
                   is_usable_location(actor_location(actors[i])) then
                    append("  using target " .. class_name .. ": " ..
                           full(actors[i]))
                    return actors[i], class_name
                end
            end
        end
    end
    return nil, nil
end

-- Ran once when VAULT_UNLOCKED arrives without a usable objective target. On
-- Fragrant Shore the only candidate was the vault-zone volume, so the real
-- objective actor for that map is still unidentified; enumerate the plausible
-- classes with their positions so the next run names it instead of guessing.
local objective_probe_done = false
local function probe_objective_classes()
    if objective_probe_done then return end
    objective_probe_done = true
    append("---- objective probe (no usable target found) ----")
    for _, class_name in ipairs({
        "BP_Briefcase_C", "BP_CarriedBriefcase_C", "BP_Briefcase_Display_C",
        "BP_DS_ObjectivePedestal_C", "BP_VaultZone_C", "BP_VaultDoorBase_C",
        "BP_VaultUnlockTerminal_C", "BP_ObjectSpawn_VaultPrinter_C",
        "Bp_Objective_Terminal_C", "BriefcaseLoot",
    }) do
        local actors
        pcall(function() actors = FindAllOf(class_name) end)
        local count = actors and #actors or 0
        append("  " .. class_name .. ": " .. count)
        if actors then
            for i = 1, math.min(count, 4) do
                if is_live(actors[i]) then
                    append("    " .. full(actors[i]) .. " at " ..
                           vector_text(actor_location(actors[i])))
                end
            end
        end
    end
    append("---- objective probe end ----")
end

-- Rescue destination for a player who has fallen out of the world. A live NPC
-- is the most reliable "known-good floor" in the level: it is standing on
-- navmesh by definition. Falls back to another live spy.
local function find_safe_location()
    for _, class_name in ipairs({ "NPCCharacter", "Spy" }) do
        local actors
        pcall(function() actors = FindAllOf(class_name) end)
        if actors then
            for i = 1, #actors do
                local actor = actors[i]
                if is_live(actor) then
                    local location = actor_location(actor)
                    if is_usable_location(location) then
                        return location, full(actor)
                    end
                end
            end
        end
    end
    return nil, nil
end

vector_text = function(vec)
    if vec == nil then return "<nil>" end
    local x, y, z
    pcall(function() x, y, z = vec.X, vec.Y, vec.Z end)
    if x == nil then return "<unreadable>" end
    return string.format("(%.0f, %.0f, %.0f)", x, y, z)
end

-- Lua 5.3 folded math.atan2 into a two-argument math.atan, and UE4SS has
-- shipped runtimes on both sides of that change.
local function atan2(y, x)
    if math.atan2 then return math.atan2(y, x) end
    return math.atan(y, x)
end

-- Candidate destinations for one pawn, relative to the objective. Slot 0 is the
-- carrier: straight above the case, so they drop onto it and grab it through
-- the game's own pickup. Every other slot owns its own arc of a ring around it.
-- The per-slot arc matters because K2_TeleportTo sweeps for collision and
-- refuses a spot another pawn already occupies -- without it every gathered spy
-- walks the same candidate list and the tail of the lobby lands ever further
-- out, or not at all.
local function destination_offsets(slot, slots)
    local offsets = {}
    if slot == 0 then
        offsets[1] = { 0, 0, 300 }
        offsets[2] = { 0, 0, 500 }
    end
    local base = 0.0
    if slot > 0 and slots > 0 then
        base = 2 * math.pi * (slot - 1) / slots
    end
    for _, radius in ipairs({ 350, 550, 800 }) do
        for _, spin in ipairs({ 0, 0.3, -0.3, 0.7, -0.7, math.pi }) do
            local angle = base + spin
            offsets[#offsets + 1] = { math.cos(angle) * radius,
                                      math.sin(angle) * radius, 250 }
        end
    end
    return offsets
end

-- Move one pawn to the first candidate the engine accepts. A single fixed
-- offset once put the carrier inside the Diamondspire pedestal and failed
-- forever, hence the spread. Yaw faces the objective, so everyone arrives
-- looking at the case -- and at each other.
local function place_pawn(pawn, location, offsets)
    local last_error = nil
    for _, offset in ipairs(offsets) do
        local dest = { X = location.X + offset[1],
                       Y = location.Y + offset[2],
                       Z = location.Z + offset[3] }
        local yaw = 180.0
        if offset[1] ~= 0 or offset[2] ~= 0 then
            yaw = atan2(-offset[2], -offset[1]) * 180.0 / math.pi
        end
        local moved = false
        local ok, err = pcall(function()
            moved = pawn:K2_TeleportTo(dest,
                                       { Pitch = 0.0, Yaw = yaw, Roll = 0.0 })
        end)
        if ok and moved then
            return true, string.format("(+%.0f,+%.0f,+%.0f)",
                                       offset[1], offset[2], offset[3])
        end
        if not ok then last_error = describe_error(err) end
    end
    return false, nil, last_error or "K2_TeleportTo refused every candidate"
end

-- Every live spy pawn in the level, players and bots alike. Both sources are
-- swept and merged by full name because each covers the other's blind spot: the
-- ASpy sweep catches a bot whose controller class is not the one we enumerate,
-- and the controller sweep catches a player pawn should the class lookup come
-- back empty. Missing a pawn here means one spy is left across the map while
-- everyone else brawls, so neither source is trusted alone.
local function live_spy_pawns()
    local pawns, seen = {}, {}
    local function add(pawn)
        if pawn == nil or not is_live(pawn) then return end
        local id = full(pawn)
        if seen[id] then return end
        seen[id] = true
        pawns[#pawns + 1] = pawn
    end

    local found
    pcall(function() found = FindAllOf("Spy") end)
    if found then
        for i = 1, #found do add(found[i]) end
    end

    local controllers
    pcall(function() controllers = FindAllOf("DeceiveIncPlayerController") end)
    if controllers then
        for i = 1, #controllers do
            if is_live(controllers[i]) then
                local pawn
                pcall(function() pawn = unwrap(controllers[i].Pawn) end)
                add(pawn)
            end
        end
    end
    return pawns
end

-- The game's own per-pawn bot flag. Unlike the controller-side NetConnection
-- test this reads straight off the pawn in hand -- and bots turned out not to
-- be DeceiveIncPlayerController instances at all, so there is often no player
-- controller to ask about them in the first place.
local function is_bot_spy(pawn)
    local bot = false
    pcall(function() bot = (pawn.bIsBot == true) end)
    return bot
end

-- "PlayerName (bot)" for a log line. The name comes off the pawn's own
-- PlayerState: the first gathered run named every bot by its raw object path
-- because it looked them up through the player controllers, which bots do not
-- have.
local function spy_label(pawn)
    local name
    pcall(function()
        local state = unwrap(pawn.PlayerState)
        if valid(state) then
            name = tostring(state:GetPlayerName():ToString())
        end
    end)
    if name == nil or name == "" then name = short_name(pawn) end
    return name .. (is_bot_spy(pawn) and " (bot)" or " (human)")
end

-- Drop everyone who is not the carrier into the ring. Best effort by design:
-- a spy the sweep cannot fit is left where they are and logged, because the
-- match is still playable with one straggler and is not playable with a body
-- shoved through the floor.
local function gather_other_spies(carrier_pawn, location)
    local carrier_id = carrier_pawn and full(carrier_pawn) or nil
    local others = {}
    for _, pawn in ipairs(live_spy_pawns()) do
        if full(pawn) ~= carrier_id then others[#others + 1] = pawn end
    end
    append("---- gathering " .. #others .. " other spy pawn(s) to the objective ----")
    local placed = 0
    for index, pawn in ipairs(others) do
        local ok, used, err =
            place_pawn(pawn, location, destination_offsets(index, #others))
        if ok then placed = placed + 1 end
        append("  gather " .. spy_label(pawn) ..
               " ok=" .. tostring(ok) ..
               (ok and (" offset=" .. tostring(used))
                    or (" error=" .. tostring(err))))
    end
    append("---- gather complete: " .. placed .. "/" .. #others .. " placed ----")
end

-- Deliver the carrier onto the briefcase and, once per match, pull every other
-- spy in around it. The carrier is what gates the mode's handoff; the gather is
-- latched separately so a carrier the sweep cannot place still gets a brawl.
local function deliver_carrier_and_gather()
    local controller, why = find_carrier_controller()
    if controller == nil then return false, why end
    local pawn
    pcall(function() pawn = unwrap(controller.Pawn) end)
    if pawn == nil or not is_live(pawn) then
        return false, "carrier has no live pawn (not deployed yet?)"
    end
    local briefcase, kind = find_objective_target()
    if briefcase == nil then
        return false, "no world briefcase / objective pedestal / objective terminal yet"
    end
    local location = actor_location(briefcase)
    if not is_usable_location(location) then
        return false, kind .. " has no usable location (" ..
               vector_text(location) .. ")"
    end
    -- Refuse a target that is the carrier's own position: that means the
    -- attached-instance bug resurfaced and the teleport would do nothing.
    local here = actor_location(pawn)
    if here ~= nil then
        local dx, dy, dz = 0, 0, 0
        pcall(function()
            dx, dy, dz = location.X - here.X, location.Y - here.Y,
                         location.Z - here.Z
        end)
        if (dx * dx + dy * dy + dz * dz) < (200 * 200) then
            return false, "resolved " .. kind ..
                   " is at the carrier's own position; not a world objective"
        end
    end

    local ok, used, err = place_pawn(pawn, location, destination_offsets(0, 0))
    append("teleport carrier=" .. tostring(player_name_of(controller)) ..
           " pawn=" .. full(pawn) ..
           " target(" .. kind .. ")=" .. full(briefcase) ..
           " at " .. vector_text(location) ..
           " ok=" .. tostring(ok) .. " offset=" .. tostring(used) ..
           " error=" .. tostring(err))

    -- After the carrier, so the spot on the case is claimed before the ring
    -- fills in around it.
    if gather_all and not gather_done then
        gather_done = true
        pcall(function() gather_other_spies(pawn, location) end)
    end

    if not ok then return false, tostring(err) end
    return true, nil
end

-- How many humans are in, and how many are actually playing.
-- ADeceiveIncPlayerController.bIsReady is the flag behind the client's own
-- Server_ClientIsReady RPC, which is the closest thing the server has to "this
-- player has finished loading"; a live pawn is required alongside it because
-- ready without a pawn is still not someone who can defend themselves.
local function humans_ready_state()
    local controllers
    pcall(function() controllers = FindAllOf("DeceiveIncPlayerController") end)
    local total, ready, detail = 0, 0, {}
    if controllers then
        for i = 1, #controllers do
            local controller = controllers[i]
            if is_live(controller) and is_human(controller) then
                total = total + 1
                local flag, pawn = false, nil
                pcall(function() flag = (controller.bIsReady == true) end)
                pcall(function() pawn = unwrap(controller.Pawn) end)
                local deployed = pawn ~= nil and is_live(pawn)
                if flag and deployed then ready = ready + 1 end
                detail[#detail + 1] = tostring(player_name_of(controller)) ..
                    "(ready=" .. tostring(flag) ..
                    " deployed=" .. tostring(deployed) .. ")"
            end
        end
    end
    return total, ready, table.concat(detail, " ")
end

-- Freeze or thaw one bot. Movement goes through the character movement
-- component's own MOVE_None; the pre-freeze mode is remembered by pawn NAME (a
-- plain string, never a retained UObject wrapper) so the thaw restores what the
-- pawn actually had.
--
-- There is NO weapon half any more, and both candidates are ruled out by live
-- runs: `ASpy::AllowWeapon` is client-side ("This is made to work on local
-- spies only" once per bot per tick), and writing `bWeaponDisabled` left
-- IsShootingBlocked() reading false every tick of the hold -- a no-op, and a
-- cross-thread write to a bot pawn, which is the exact category that has been
-- killing this server. So a frozen bot can still shoot; it just cannot move or
-- chase, and it cannot reach the objective before the humans do.
local function set_bot_frozen(pawn, freeze)
    local id = full(pawn)
    local move
    pcall(function() move = unwrap(pawn.CharacterMovement) end)
    if not is_live(move) then return false end
    if freeze then
        if frozen_modes[id] == nil then
            local mode
            pcall(function() mode = tonumber(unwrap(move.MovementMode)) end)
            frozen_modes[id] = mode or 1 -- MOVE_Walking
        end
        pcall(function() move:DisableMovement() end)
    else
        local mode = frozen_modes[id] or 1
        if mode == 0 then mode = 1 end -- never restore INTO the frozen mode
        frozen_modes[id] = nil
        pcall(function() move:SetMovementMode(mode, 0) end)
    end
    return true
end

local function apply_bot_freeze(freeze)
    local touched = 0
    for _, pawn in ipairs(live_spy_pawns()) do
        if is_bot_spy(pawn) and set_bot_frozen(pawn, freeze) then
            touched = touched + 1
        end
    end
    return touched
end

-- Returns true once the bots are free to play. Until then it re-applies the
-- freeze every tick, because a bot's own movement code will happily set itself
-- walking again between ticks.
local function maintain_bot_freeze()
    if not freeze_bots or bots_released then return true end
    local now = os.time()
    freeze_wait_started = freeze_wait_started or now
    local total, ready, detail = humans_ready_state()
    if total > 0 and ready == total then
        humans_ready_since = humans_ready_since or now
    else
        humans_ready_since = nil
    end

    local settled = humans_ready_since ~= nil and
                    (now - humans_ready_since) >= freeze_grace
    local timed_out = (now - freeze_wait_started) >= freeze_max_wait
    if settled or timed_out then
        bots_released = true
        local thawed = apply_bot_freeze(false)
        append("bots released (" ..
               (settled and ("all " .. total .. " human(s) ready")
                         or ("timed out after " .. freeze_max_wait .. "s")) ..
               "): " .. thawed .. " bot(s) thawed")
        freeze_logged = nil
        return true
    end

    local frozen = apply_bot_freeze(true)
    local line = "holding " .. frozen .. " bot(s) still; humans ready " ..
                 ready .. "/" .. total .. " " .. detail
    if line ~= freeze_logged then
        freeze_logged = line
        append(line)
    end
    return false
end

-- One armed-mode tick. Reacquires all live state, waits out the stock
-- pregame/intro, fires exactly one AdvancePhase at VAULT_LOCKED (bViaTimer =
-- true, the proven genuine timer-expiry branch; see route31 in
-- DINativeStage2), then completes at VAULT_UNLOCKED with the teleport.
local function extraction_tick()
    if not armed then return end
    local game_state = find_live_game_state()
    if game_state == nil then return end
    local phase = current_phase(game_state)
    if phase ~= last_logged_phase then
        append("armed; phase=" .. phase_label(phase) ..
               " carrier_filter=" .. tostring(carrier_filter))
        last_logged_phase = phase
    end
    if phase == nil then return end

    if phase < PHASE_BY_NAME.POSING_SPY_INTRO then
        return -- stock lobby flow gets the players spawned first
    end

    -- From the intro onwards there are bots on the map who will start fighting
    -- the moment they can. Hold them until the humans are actually in.
    local bots_ready = maintain_bot_freeze()

    if phase < PHASE_BY_NAME.VAULT_LOCKED then
        return -- stock intro flow still running
    end

    if phase == PHASE_BY_NAME.VAULT_LOCKED then
        -- Refuse the transition while the designated carrier cannot act on it.
        local controller, why = find_carrier_controller()
        if controller == nil then
            append("holding at VAULT_LOCKED: " .. tostring(why))
            return
        end
        local pawn
        pcall(function() pawn = unwrap(controller.Pawn) end)
        if pawn == nil or not is_live(pawn) then
            append("holding at VAULT_LOCKED: carrier not deployed yet")
            return
        end
        -- Opening the vault is what starts the brawl, so it waits on the same
        -- readiness the freeze does. Otherwise thawed bots would sprint for a
        -- case whose owner is still on a loading screen.
        if not bots_ready then return end
        if advance_attempted then return end -- verify on a later tick
        advance_attempted = true
        local ok, err = pcall(function() game_state:AdvancePhase(true) end)
        append("AdvancePhase(true) at VAULT_LOCKED ok=" .. tostring(ok) ..
               " error=" .. tostring(err))
        return
    end

    if phase == PHASE_BY_NAME.VAULT_UNLOCKED then
        -- Kit the carrier out BEFORE attempting the teleport, and only once.
        -- Doing it here rather than after a successful delivery means a
        -- teleport that cannot find a clear spot no longer costs the player
        -- their loadout and disguise too.
        if not carrier_prepared then
            local controller = find_carrier_controller()
            local pawn
            if controller then
                pcall(function() pawn = unwrap(controller.Pawn) end)
            end
            if controller and pawn ~= nil and is_live(pawn) then
                carrier_prepared = true
                if auto_loadout then
                    -- Everyone in the brawl gets kitted, bots included: a fight
                    -- the carrier enters with full charges against bots on
                    -- spawn ammo is not a fight. Carrier-only delivery
                    -- (GatherAll = 0) keeps the grant carrier-only to match.
                    if gather_all then
                        append("---- auto loadout on vault open (everyone) ----")
                        pcall(grant_full_resources_all)
                    else
                        append("---- auto loadout on vault open (carrier) ----")
                        pcall(function() grant_full_resources(controller) end)
                    end
                end
                if desired_disguise ~= nil then
                    pcall(function()
                        apply_disguise(controller, desired_disguise)
                    end)
                end
            end
        end

        local ok, why = deliver_carrier_and_gather()
        if not ok then pcall(probe_objective_classes) end
        if ok then
            armed = false
            advance_attempted = false
            append("carrier delivered to briefcase" ..
                   (gather_all and " and the lobby gathered around it" or "") ..
                   "; mode handoff complete -- grab, call extraction, and the " ..
                   "stock endgame takes over")
        else
            -- Retrying is right while the world is still settling, but the
            -- Diamondspire run failed identically every two seconds forever and
            -- buried the log. Give it a bounded number of tries, then stop and
            -- say so once.
            teleport_attempts = teleport_attempts + 1
            if teleport_attempts <= TELEPORT_MAX_ATTEMPTS then
                append("VAULT_UNLOCKED but teleport pending (" ..
                       teleport_attempts .. "/" .. TELEPORT_MAX_ATTEMPTS ..
                       "): " .. tostring(why))
            elseif teleport_attempts == TELEPORT_MAX_ATTEMPTS + 1 then
                append("giving up on the teleport after " ..
                       TELEPORT_MAX_ATTEMPTS .. " attempts: " .. tostring(why) ..
                       " -- the vault phase is open, walk to the objective; " ..
                       "run extraction-recon for the live layout")
                armed = false
            end
        end
        return
    end

    -- Already past the window (rearmed late, or the match moved on).
    append("disarming: phase " .. phase_label(phase) ..
           " is beyond VAULT_UNLOCKED")
    armed = false
    advance_attempted = false
end

-- Top up every grantable resource on one spy to the game's OWN max for that
-- resource. Filling to GetMaxAmount rather than a hand-picked number means the
-- grant can never exceed what the game considers a full pouch, so no HUD or
-- spend path sees an impossible value. A max of 0 means this spy/agent does not
-- use that resource at all (e.g. charges for a gadget they did not equip), and
-- it is skipped.
-- The pawn half of the grant. Everything below the controller is the same for
-- a human and a bot, and only the pawn is common to both -- bots have no
-- ADeceiveIncPlayerController at all.
grant_full_resources_pawn = function(pawn, name)
    if pawn == nil or not is_live(pawn) then
        return false, "no live pawn for " .. tostring(name) .. " (not deployed?)"
    end
    local resources
    pcall(function() resources = unwrap(pawn.GameplayResourcesComponent) end)
    if resources == nil or not is_live(resources) then
        return false, "no GameplayResourcesComponent on " .. full(pawn)
    end

    local granted, skipped, failed = 0, 0, 0
    for _, entry in ipairs(GRANTABLE_RESOURCES) do
        local id, label = entry[1], entry[2]
        local max_amount, current
        local read_ok = pcall(function()
            max_amount = resources:GetMaxAmount(id)
            current = resources:GetResourceAmount(id)
        end)
        if not read_ok or type(max_amount) ~= "number" or
           type(current) ~= "number" then
            failed = failed + 1
        elseif max_amount <= 0 or current >= max_amount then
            skipped = skipped + 1
        else
            -- bGiveXpForResource = false: this is a debug grant, it must not
            -- feed the match's XP/progression accounting.
            local ok, err = pcall(function()
                resources:AddResource(id, max_amount - current, false)
            end)
            if ok then
                granted = granted + 1
                append("  granted " .. label .. " " .. current .. " -> " ..
                       max_amount)
            else
                failed = failed + 1
                append("  FAILED " .. label .. " error=" .. tostring(err))
            end
        end
    end
    append("loadout grant for " .. tostring(name) .. " pawn=" .. full(pawn) ..
           " granted=" .. granted .. " skipped=" .. skipped ..
           " failed=" .. failed)
    return true, nil
end

-- Controller-shaped entry point, for the marker commands that resolve a player
-- by name.
grant_full_resources = function(controller)
    local pawn
    pcall(function() pawn = unwrap(controller.Pawn) end)
    return grant_full_resources_pawn(pawn, player_name_of(controller))
end

-- ASpy::CheatDisguiseGiveSecurityLevelSrv(ESecurityLevel) is the game's own
-- server-side entry point for handing a spy a disguise clearance. It is
-- Cheat-prefixed, and this build compiles some cheat bodies out to a bare
-- `ret` on the server (the whole spectator free-move family is), so the call
-- is treated as unproven: GetDisguise() is sampled either side and logged, and
-- a silent no-op is reported as such rather than as success.
-- Every NPC currently worn as a disguise by some spy, so the swap never steals
-- another player's cover out from under them.
local function disguises_in_use()
    local taken = {}
    local spies
    pcall(function() spies = FindAllOf("Spy") end)
    if spies then
        for i = 1, #spies do
            if is_live(spies[i]) then
                local worn
                pcall(function() worn = unwrap(spies[i]:GetDisguise()) end)
                if worn ~= nil then taken[full(worn)] = true end
            end
        end
    end
    return taken
end

-- Point the spy's replicated DisguiseData at a live NPC of the wanted tier.
-- DisguiseData is an FDisguiseReplicationData with its own OnRep_Disguise, so a
-- successful write reaches the client through the game's own path.
local function swap_disguise_to_tier(pawn, level, name)
    local npcs
    pcall(function() npcs = FindAllOf("NPCCharacter") end)
    if npcs == nil then return false end
    local taken = disguises_in_use()

    local chosen = nil
    for i = 1, #npcs do
        local npc = npcs[i]
        if is_live(npc) and not taken[full(npc)] then
            local tier = tonumber(scalar_property(npc, "SecurityLevel"))
            if tier == level then chosen = npc break end
        end
    end
    if chosen == nil then
        append("  no free NPC at tier " .. (SECURITY_LEVEL_NAMES[level] or level))
        return false
    end

    local before = "<none>"
    pcall(function() before = full(unwrap(pawn:GetDisguise())) end)

    -- Try the nested member write first, then a read-modify-write of the whole
    -- struct: UE4SS does not always mark a nested assignment dirty.
    local wrote = false
    pcall(function()
        pawn.DisguiseData.Disguise = chosen
        wrote = true
    end)
    if not wrote then
        pcall(function()
            local data = pawn.DisguiseData
            data.Disguise = chosen
            pawn.DisguiseData = data
            wrote = true
        end)
    end
    -- Ask the game to play its own change-disguise feedback so the client
    -- refreshes rather than waiting to notice the property.
    pcall(function()
        pawn:NetMulticast_TriggerChangeDisguiseVisualFeedback(chosen)
    end)
    pcall(function() pawn:ForceNetUpdate() end)

    local after = "<none>"
    pcall(function() after = full(unwrap(pawn:GetDisguise())) end)
    append("disguise swap for " .. name .. " to tier " ..
           (SECURITY_LEVEL_NAMES[level] or level) ..
           " wrote=" .. tostring(wrote) ..
           " chosen=" .. full(chosen) ..
           " chosen_tier=" .. scalar_property(chosen, "SecurityLevel") ..
           " before=" .. before .. " after=" .. after)
    return wrote and after ~= before
end

apply_disguise = function(controller, level)
    local name = tostring(player_name_of(controller))
    local pawn
    pcall(function() pawn = unwrap(controller.Pawn) end)
    if pawn == nil or not is_live(pawn) then
        return false, "no live pawn for " .. name .. " (not deployed?)"
    end
    local before = "<unreadable>"
    pcall(function() before = full(unwrap(pawn:GetDisguise())) end)

    -- Writing SecurityLevel on the CURRENT disguise provably changes the value
    -- server-side (logged 0 -> 3 -> 4) yet the client never reflects it, so the
    -- client is not reading that per-instance field: it derives the tier from
    -- the disguise actor itself (its class, or its NPC pool via
    -- USecurityLevelData.SecurityLevelForPool).
    --
    -- So swap the disguise for an NPC that ALREADY IS the wanted tier. A real
    -- Technician has the right level, pool and mesh, which sidesteps the
    -- question of which field the client actually consults.
    local disguise
    pcall(function() disguise = unwrap(pawn:GetDisguise()) end)

    if swap_disguise_to_tier(pawn, level, name) then
        pcall(function() pawn:ForceNetUpdate() end)
        return true, nil
    end
    append("  tier swap unavailable; falling back to editing the current " ..
           "disguise's SecurityLevel (known not to reach the client)")
    if disguise ~= nil and is_live(disguise) then
        local previous = "<unreadable>"
        pcall(function()
            previous = tostring(scalar_property(disguise, "SecurityLevel"))
        end)
        local set_ok, set_err = pcall(function()
            disguise.SecurityLevel = level
            disguise:ForceNetUpdate()
        end)
        local now = "<unreadable>"
        pcall(function()
            now = tostring(scalar_property(disguise, "SecurityLevel"))
        end)
        append("disguise " .. (SECURITY_LEVEL_NAMES[level] or level) ..
               "(" .. level .. ") for " .. name ..
               " via ANPCCharacter.SecurityLevel ok=" .. tostring(set_ok) ..
               " " .. previous .. " -> " .. now ..
               " error=" .. tostring(set_err) ..
               " disguise=" .. full(disguise))
        pcall(function() pawn:ForceNetUpdate() end)
        if set_ok then return true, nil end
    else
        append("disguise: no live ANPCCharacter disguise on " .. name ..
               " (spy is out of cover?); falling through to the cheat call")
    end
    -- A first live run returned call_ok=false with an opaque error, so report
    -- what the member actually is before invoking it: "nil" means this pawn
    -- class does not expose the function at all, which is a different problem
    -- from a call that exists and throws.
    for _, candidate in ipairs({ "CheatDisguiseGiveSecurityLevelSrv",
                                 "CheatDisguiseGiveSecurityLevel" }) do
        local kind = "<absent>"
        pcall(function() kind = type(pawn[candidate]) end)
        append("  member " .. candidate .. " = " .. tostring(kind))
    end
    local ok, err = pcall(function()
        pawn:CheatDisguiseGiveSecurityLevelSrv(level)
    end)
    if not ok then
        -- Retry the client-side twin; on this build the pair often share one
        -- implementation and only one of them is reachable by reflection.
        local retry_ok, retry_err = pcall(function()
            pawn:CheatDisguiseGiveSecurityLevel(level)
        end)
        append("  Srv call failed; CheatDisguiseGiveSecurityLevel ok=" ..
               tostring(retry_ok) .. " error=" .. describe_error(retry_err))
        if retry_ok then ok, err = true, nil end
    end
    local after = "<unreadable>"
    pcall(function() after = full(unwrap(pawn:GetDisguise())) end)
    append("disguise " .. (SECURITY_LEVEL_NAMES[level] or level) ..
           "(" .. level .. ") for " .. name ..
           " call_ok=" .. tostring(ok) .. " error=" .. describe_error(err) ..
           " disguise_before=" .. before .. " disguise_after=" .. after)
    if not ok then return false, describe_error(err) end
    if before == after then
        append("  NOTE: GetDisguise() unchanged -- the cheat may be a compiled" ..
               "-out stub on this server build, or it grants clearance without" ..
               " swapping the NPC body. Check the client HUD to tell which.")
    end
    return true, nil
end

local function consume_disguise()
    local fh = io.open(DISGUISE, "r")
    if fh == nil then return end
    local payload = fh:read("*l")
    fh:close()
    os.remove(DISGUISE)
    if payload then payload = payload:gsub("^%s+", ""):gsub("%s+$", "") end

    local level_text, target = nil, nil
    if payload then level_text, target = payload:match("^(%S+)%s*(.*)$") end
    if target == "" then target = nil end
    append("---- disguise requested level=" .. tostring(level_text) ..
           " target=" .. tostring(target) .. " ----")

    if level_text == "off" then
        desired_disguise = nil
        append("disguise auto-apply cleared")
        return
    end
    local level = SECURITY_LEVELS[tostring(level_text):lower()]
    if level == nil then level = tonumber(level_text) end
    if level == nil or level < 0 or level > 4 then
        append("disguise refused: unknown security level '" ..
               tostring(level_text) .. "'")
        return
    end
    -- Remembered so the next deploy re-applies it; that is what makes it read
    -- as "spawn with the disguise" rather than a one-shot.
    desired_disguise = level

    local saved = carrier_filter
    carrier_filter = target
    local controller, why = find_carrier_controller()
    carrier_filter = saved
    if controller == nil then
        append("disguise armed for next deploy (" .. tostring(why) .. ")")
        return
    end
    local ok, err = apply_disguise(controller, level)
    if not ok then
        append("disguise not applied now (" .. tostring(err) ..
               "); armed for next deploy")
    end
end

-- Put a player who has fallen out of the world back on solid ground.
local function consume_rescue()
    local fh = io.open(RESCUE, "r")
    if fh == nil then return end
    local payload = fh:read("*l")
    fh:close()
    os.remove(RESCUE)
    if payload then payload = payload:gsub("^%s+", ""):gsub("%s+$", "") end

    append("---- rescue requested target=" .. tostring(payload) .. " ----")
    local saved = carrier_filter
    carrier_filter = (payload ~= nil and payload ~= "") and payload or nil
    local controller, why = find_carrier_controller()
    carrier_filter = saved
    if controller == nil then
        append("rescue refused: " .. tostring(why))
        return
    end
    local pawn
    pcall(function() pawn = unwrap(controller.Pawn) end)
    if pawn == nil or not is_live(pawn) then
        append("rescue refused: no live pawn")
        return
    end
    local location, source = find_safe_location()
    if location == nil then
        append("rescue refused: no live NPC or spy to anchor a safe spot on")
        return
    end
    local dest = { X = location.X, Y = location.Y, Z = location.Z + 120.0 }
    local moved = false
    local ok, err = pcall(function()
        moved = pawn:K2_TeleportTo(dest, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 })
    end)
    append("rescue " .. tostring(player_name_of(controller)) ..
           " from " .. vector_text(actor_location(pawn)) ..
           " to " .. vector_text(location) .. " (anchor " .. tostring(source) ..
           ") ok=" .. tostring(ok and moved) .. " error=" .. tostring(err))
end

-- Fill every live player in the match, humans and bots alike. Shared by the
-- `grant-loadout all` marker and by the vault-open grant, so the two can never
-- disagree about who counts as "everyone".
-- Fill every live HUMAN in the match.
--
-- Bots are deliberately excluded, and this is not caution -- it is measured.
-- `AddResource` on a bot kills the server outright: the bots' own weapon code
-- decrements the same Ammo counter on the game thread while this runs on the
-- async one, and the two racing exits the process (status-3, no callstack,
-- immediately after the engine logged the add). Handing the grant to
-- ExecuteInGameThread to fix that made it worse, not better -- see the thread
-- note at the top of this file. The game already kits bots at spawn (ammo,
-- charges, intel), so the practical cost of skipping them is small.
--
-- Doing this properly needs the native ProcessEvent invoker (docs/11), not Lua.
grant_full_resources_all = function()
    local pawns = live_spy_pawns()
    if #pawns == 0 then
        append("loadout grant: no live spies in world")
        return 0
    end
    -- One live run swept NINE spies for eight players. Until that is explained,
    -- name them: a stale pawn nobody is driving is a plausible source of the
    -- next unexplained crash.
    local names = {}
    for _, pawn in ipairs(pawns) do names[#names + 1] = short_name(pawn) end
    append("loadout sweep found " .. #pawns .. " spies: " ..
           table.concat(names, ", "))
    local done, skipped = 0, 0
    for _, pawn in ipairs(pawns) do
        -- Logged before the pawn is touched, not after: a status-3 exit writes
        -- nothing, so the last name in the log is the pawn that killed it.
        append("  loadout target " .. spy_label(pawn))
        if is_bot_spy(pawn) then
            skipped = skipped + 1
            append("    skipped: bots cannot take AddResource on this build")
        else
            local ok, why = grant_full_resources_pawn(pawn, spy_label(pawn))
            if ok then done = done + 1
            else append("loadout skip: " .. tostring(why)) end
        end
    end
    append("loadout grant complete for " .. done .. " human(s), " ..
           skipped .. " bot(s) skipped")
    return done
end

local function consume_loadout()
    local fh = io.open(LOADOUT, "r")
    if fh == nil then return end
    local payload = fh:read("*l")
    fh:close()
    os.remove(LOADOUT)
    if payload then payload = payload:gsub("^%s+", ""):gsub("%s+$", "") end

    append("---- loadout grant requested target=" .. tostring(payload) .. " ----")
    if payload == "all" then
        grant_full_resources_all()
        return
    end

    -- Named or default target reuses the carrier resolver, so "the player the
    -- extraction mode would pick" and "the player who gets the loadout" are
    -- always the same person while testing.
    local saved = carrier_filter
    carrier_filter = (payload ~= nil and payload ~= "") and payload or nil
    local controller, why = find_carrier_controller()
    carrier_filter = saved
    if controller == nil then
        append("loadout grant refused: " .. tostring(why))
        return
    end
    local ok, err = grant_full_resources(controller)
    if not ok then append("loadout grant refused: " .. tostring(err)) end
end

local function recon_dump()
    local game_state = find_live_game_state()
    append("---- recon ----")
    if game_state == nil then
        append("recon: no live game state")
        return
    end
    append("game_state=" .. full(game_state) ..
           " phase=" .. phase_label(current_phase(game_state)))
    for _, prop in ipairs({ "ObjectiveCarrier", "bExtractionRequested",
                            "bExtractionOnTheWay", "ExtractedPlayer",
                            "LastManStanding", "MatchResult" }) do
        local rendered = "<unavailable>"
        pcall(function()
            local raw = unwrap(game_state[prop])
            if raw == nil then rendered = "<nil>"
            elseif type(raw) == "boolean" or type(raw) == "number" then
                rendered = tostring(raw)
            else rendered = full(raw) end
        end)
        append("  " .. prop .. " = " .. rendered)
    end
    -- FSandboxSettings on the game state is what TripwireServer.ini's
    -- bSandboxMode is supposed to drive, and bSandboxUnlocksAll is the flag
    -- that would open the client's agent/loadout choices. Dump it verbatim so
    -- the INI key's real effect is observed rather than assumed.
    local sandbox
    pcall(function() sandbox = unwrap(game_state.SandboxSettings) end)
    if sandbox == nil then
        append("  SandboxSettings = <unavailable>")
    else
        local shown = {}
        for _, field in ipairs({ "bIsPrivateSandboxGame", "bSandboxUnlocksAll",
                                 "bPrivateFillBot", "BotsAmount", "MaxPlayers",
                                 "BotsDifficulty" }) do
            local rendered = "<unreadable>"
            pcall(function()
                local raw = unwrap(sandbox[field])
                if raw == nil then rendered = "<nil>"
                elseif type(raw) == "boolean" or type(raw) == "number" then
                    rendered = tostring(raw)
                else rendered = tostring(raw) end
            end)
            shown[#shown + 1] = field .. "=" .. rendered
        end
        append("  SandboxSettings: " .. table.concat(shown, " "))
    end
    -- USecurityLevelData.SecurityColors maps each ESecurityLevel to the colour
    -- the UI paints it, which is the only authoritative way to say which tier
    -- "purple" actually means rather than inferring it from keycard ordering.
    local security_data
    pcall(function()
        local found = FindAllOf("SecurityLevelData")
        if found then
            for i = 1, #found do
                if is_live(found[i]) then security_data = found[i] break end
            end
        end
    end)
    if security_data == nil then
        append("  SecurityLevelData: <no live instance>")
    else
        append("  SecurityLevelData: " .. full(security_data))
        local colors
        pcall(function() colors = unwrap(security_data.SecurityColors) end)
        if colors == nil then
            append("    SecurityColors unreadable")
        else
            for level = 0, 4 do
                local rendered = "<unreadable>"
                pcall(function()
                    local entry = colors[level]
                    if entry ~= nil then
                        rendered = string.format("R=%s G=%s B=%s",
                            tostring(entry.R), tostring(entry.G),
                            tostring(entry.B))
                    else
                        rendered = "<no entry>"
                    end
                end)
                append("    " .. (SECURITY_LEVEL_NAMES[level] or level) ..
                       " -> " .. rendered)
            end
        end
    end

    -- Sample live NPCs' tiers. Doubles as a check that the enum property reads
    -- at all (an undefined helper once made every read show "<unreadable>"),
    -- and shows which tiers this map actually populates.
    local npcs
    pcall(function() npcs = FindAllOf("NPCCharacter") end)
    if npcs then
        local tally, shown = {}, 0
        for i = 1, #npcs do
            if is_live(npcs[i]) then
                local tier = scalar_property(npcs[i], "SecurityLevel")
                tally[tier] = (tally[tier] or 0) + 1
                if shown < 3 then
                    shown = shown + 1
                    append("  npc sample " .. full(npcs[i]) ..
                           " SecurityLevel=" .. tier)
                end
            end
        end
        local parts = {}
        for tier, count in pairs(tally) do
            parts[#parts + 1] = tostring(tier) .. "x" .. count
        end
        append("  npc SecurityLevel tally: " .. table.concat(parts, " "))
    end

    -- What the carrier is currently wearing, and at what clearance.
    local controllers_probe
    pcall(function()
        controllers_probe = FindAllOf("DeceiveIncPlayerController")
    end)
    if controllers_probe then
        for i = 1, #controllers_probe do
            local controller = controllers_probe[i]
            if is_live(controller) and is_human(controller) then
                local pawn, disguise
                pcall(function() pawn = unwrap(controller.Pawn) end)
                if pawn and is_live(pawn) then
                    pcall(function() disguise = unwrap(pawn:GetDisguise()) end)
                end
                append("  " .. tostring(player_name_of(controller)) ..
                       " disguise=" .. full(disguise) ..
                       " SecurityLevel=" ..
                       (disguise and scalar_property(disguise, "SecurityLevel")
                                 or "<none>"))
            end
        end
    end

    local is_sandbox = "<unreadable>"
    pcall(function() is_sandbox = tostring(game_state:IsSandboxGame()) end)
    append("  IsSandboxGame() = " .. is_sandbox)

    local cases
    pcall(function() cases = FindAllOf("BP_Briefcase_C") end)
    append("  briefcases: " .. tostring(cases and #cases or 0))
    if cases then
        for i = 1, #cases do
            if is_live(cases[i]) then
                append("    " .. full(cases[i]) ..
                       " world=" .. tostring(is_world_briefcase(cases[i])) ..
                       " at " .. vector_text(actor_location(cases[i])))
            end
        end
    end
    for _, extra in ipairs({ "BP_DS_ObjectivePedestal_C", "BP_VaultZone_C" }) do
        local actors
        pcall(function() actors = FindAllOf(extra) end)
        append("  " .. extra .. ": " .. tostring(actors and #actors or 0))
        if actors then
            for i = 1, #actors do
                if is_live(actors[i]) then
                    append("    " .. full(actors[i]) .. " at " ..
                           vector_text(actor_location(actors[i])))
                end
            end
        end
    end
    local carried
    pcall(function() carried = FindAllOf("BP_CarriedBriefcase_C") end)
    if carried then
        for i = 1, #carried do
            if is_live(carried[i]) then
                append("    carried: " .. full(carried[i]))
            end
        end
    end
    local controllers
    pcall(function() controllers = FindAllOf("DeceiveIncPlayerController") end)
    if controllers then
        for i = 1, #controllers do
            local controller = controllers[i]
            if is_live(controller) then
                append("  controller " .. full(controller) ..
                       " name=" .. tostring(player_name_of(controller)) ..
                       " human=" .. tostring(is_human(controller)) ..
                       " pawn=" .. full(unwrap(controller.Pawn)))
                local pawn
                pcall(function() pawn = unwrap(controller.Pawn) end)
                if pawn and is_live(pawn) then
                    local resources
                    pcall(function()
                        resources = unwrap(pawn.GameplayResourcesComponent)
                    end)
                    if resources and is_live(resources) then
                        local shown = {}
                        for _, entry in ipairs(GRANTABLE_RESOURCES) do
                            local amount, max_amount
                            pcall(function()
                                amount = resources:GetResourceAmount(entry[1])
                                max_amount = resources:GetMaxAmount(entry[1])
                            end)
                            if type(max_amount) == "number" and max_amount > 0 then
                                shown[#shown + 1] = entry[2] .. "=" ..
                                    tostring(amount) .. "/" .. tostring(max_amount)
                            end
                        end
                        append("    resources: " ..
                               (#shown > 0 and table.concat(shown, " ")
                                            or "<none in use>"))
                    else
                        append("    resources: <no component>")
                    end
                end
            end
        end
    end
    append("---- recon end ----")
end

local function consume_trigger()
    local fh = io.open(TRIGGER, "r")
    if fh == nil then return end
    local payload = fh:read("*l")
    fh:close()
    os.remove(TRIGGER)
    if payload then payload = payload:gsub("^%s+", ""):gsub("%s+$", "") end
    carrier_filter = (payload ~= nil and payload ~= "") and payload or nil
    armed = true
    advance_attempted = false
    teleport_attempts = 0
    carrier_prepared = false
    gather_done = false
    bots_released = false
    freeze_wait_started = nil
    humans_ready_since = nil
    frozen_modes = {}
    freeze_logged = nil
    last_logged_phase = nil
    append("extraction mode armed; carrier_filter=" .. tostring(carrier_filter))
    -- Name the designated player immediately when one is already connected, so
    -- a test run can confirm the right human was picked before the vault opens.
    local controller, why = find_carrier_controller()
    if controller then
        append("  designated carrier resolves to: " ..
               tostring(player_name_of(controller)))
    else
        append("  no carrier resolvable yet (" .. tostring(why) ..
               "); will keep looking")
    end
end

local function consume_recon()
    local fh = io.open(RECON, "r")
    if fh == nil then return end
    fh:close()
    os.remove(RECON)
    pcall(recon_dump)
end

local trigger_error, recon_error, tick_error, loadout_error, disguise_error
local rescue_error
LoopAsync(1000, function()
    local ok, err = pcall(consume_trigger)
    if not ok and tostring(err) ~= trigger_error then
        trigger_error = tostring(err)
        append("consume_trigger error=" .. trigger_error)
    elseif ok then trigger_error = nil end
    local r_ok, r_err = pcall(consume_recon)
    if not r_ok and tostring(r_err) ~= recon_error then
        recon_error = tostring(r_err)
        append("consume_recon error=" .. recon_error)
    elseif r_ok then recon_error = nil end
    local l_ok, l_err = pcall(consume_loadout)
    if not l_ok and tostring(l_err) ~= loadout_error then
        loadout_error = tostring(l_err)
        append("consume_loadout error=" .. loadout_error)
    elseif l_ok then loadout_error = nil end
    local d_ok, d_err = pcall(consume_disguise)
    if not d_ok and tostring(d_err) ~= disguise_error then
        disguise_error = tostring(d_err)
        append("consume_disguise error=" .. disguise_error)
    elseif d_ok then disguise_error = nil end
    local rs_ok, rs_err = pcall(consume_rescue)
    if not rs_ok and tostring(rs_err) ~= rescue_error then
        rescue_error = tostring(rs_err)
        append("consume_rescue error=" .. rescue_error)
    elseif rs_ok then rescue_error = nil end
    local t_ok, t_err = pcall(extraction_tick)
    if not t_ok and tostring(t_err) ~= tick_error then
        tick_error = tostring(t_err)
        append("extraction_tick error=" .. tick_error)
    elseif t_ok then tick_error = nil end
    return false
end)

RegisterHook("/Script/Engine.GameModeBase:StartPlay", function()
    if armed then
        advance_attempted = false
        teleport_attempts = 0
        carrier_prepared = false
        gather_done = false
        bots_released = false
        freeze_wait_started = nil
        humans_ready_since = nil
        frozen_modes = {}
        freeze_logged = nil
        last_logged_phase = nil
        append("map (re)started; armed extraction mode reset to waiting")
    end
end)

-- Arming lived only in a one-shot marker, and `dimod apply` deletes every
-- transient marker -- so each restart silently disarmed the mode and a test run
-- looked like a code failure. DIConfig.ini is written from the profile and does
-- survive, so a profile can declare the mode on:
--   [Extraction]
--   AutoArm = 1
--   Disguise = purple
local function load_config()
    local fh = io.open("DIConfig.ini", "r")
    if fh == nil then return end
    local section = nil
    local settings = {}
    for line in fh:lines() do
        local header = line:match("^%s*%[([^%]]+)%]")
        if header then
            section = header
        elseif section == "Extraction" then
            local key, value = line:match("^%s*([%w_]+)%s*=%s*([^;\r\n]+)")
            if key then
                settings[key:lower()] = (value:gsub("%s+$", ""))
            end
        end
    end
    fh:close()

    if settings.autoarm == "1" or (settings.autoarm or ""):lower() == "true" then
        armed = true
        advance_attempted = false
        teleport_attempts = 0
        carrier_prepared = false
        gather_done = false
        bots_released = false
        freeze_wait_started = nil
        humans_ready_since = nil
        frozen_modes = {}
        freeze_logged = nil
        last_logged_phase = nil
        append("auto-armed from DIConfig.ini [Extraction] AutoArm")
    end
    if settings.autoloadout == "1" or
       (settings.autoloadout or ""):lower() == "true" then
        auto_loadout = true
        append("auto-loadout enabled from config")
    end
    -- Default on: gathering the lobby is what makes this an instant brawl.
    -- Only an explicit 0/false turns it back into the carrier-only delivery.
    if settings.gatherall ~= nil then
        local value = settings.gatherall:lower()
        gather_all = not (value == "0" or value == "false" or value == "off")
        append("gather-all from config: " .. tostring(gather_all))
    end
    if settings.freezebots ~= nil then
        local value = settings.freezebots:lower()
        freeze_bots = not (value == "0" or value == "false" or value == "off")
        append("bot freeze from config: " .. tostring(freeze_bots))
    end
    local grace = tonumber(settings.freezegraceseconds or "")
    if grace and grace >= 0 and grace <= 60 then
        freeze_grace = grace
        append("bot freeze grace from config: " .. grace .. "s")
    end
    local max_wait = tonumber(settings.freezemaxwaitseconds or "")
    if max_wait and max_wait >= 5 and max_wait <= 300 then
        freeze_max_wait = max_wait
        append("bot freeze max wait from config: " .. max_wait .. "s")
    end
    if settings.carrier and settings.carrier ~= "" then
        carrier_filter = settings.carrier
        append("carrier filter from config: " .. carrier_filter)
    end
    if settings.disguise and settings.disguise ~= "" then
        local level = SECURITY_LEVELS[settings.disguise:lower()] or
                      tonumber(settings.disguise)
        if level and level >= 0 and level <= 4 then
            desired_disguise = level
            append("disguise from config: " ..
                   (SECURITY_LEVEL_NAMES[level] or level))
        else
            append("config disguise '" .. settings.disguise .. "' not recognised")
        end
    end
end

pcall(load_config)

append("DIExtraction loaded; write " .. TRIGGER .. " to arm, " ..
       RECON .. " for a state dump, " .. LOADOUT .. " to grant resources")
