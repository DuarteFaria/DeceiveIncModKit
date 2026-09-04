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
-- Set from DIConfig.ini; kitting the carrier out is a once-per-match action, so
-- it is latched rather than repeated every tick.
local auto_loadout = false
local carrier_prepared = false

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

local function is_live(object)
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

local function player_name_of(controller)
    local name
    pcall(function()
        local state = unwrap(controller.PlayerState)
        if state then name = tostring(state:GetPlayerName():ToString()) end
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

local function teleport_carrier_to_briefcase()
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
    -- K2_TeleportTo sweeps for collision and returns false if the destination
    -- overlaps geometry. A single fixed offset put the carrier inside the
    -- pedestal on Diamondspire and failed forever, so try a spread of
    -- candidates: straight above first (drop onto the objective), then a
    -- widening ring at two heights. First one the engine accepts wins.
    local offsets = { { 0, 0, 300 }, { 0, 0, 500 } }
    for _, radius in ipairs({ 150, 300, 500 }) do
        for _, dir in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
                               { 0.7, 0.7 }, { -0.7, 0.7 },
                               { 0.7, -0.7 }, { -0.7, -0.7 } }) do
            offsets[#offsets + 1] =
                { dir[1] * radius, dir[2] * radius, 250 }
        end
    end

    local moved, ok, err, used = false, true, nil, nil
    for _, offset in ipairs(offsets) do
        local dest = { X = location.X + offset[1],
                       Y = location.Y + offset[2],
                       Z = location.Z + offset[3] }
        local attempt_ok, attempt_err = pcall(function()
            moved = pawn:K2_TeleportTo(dest,
                                       { Pitch = 0.0, Yaw = 180.0, Roll = 0.0 })
        end)
        ok, err = attempt_ok, attempt_err
        if attempt_ok and moved then
            used = string.format("(+%.0f,+%.0f,+%.0f)",
                                 offset[1], offset[2], offset[3])
            break
        end
        moved = false
    end
    append("  teleport offset used=" .. tostring(used) ..
           " after " .. #offsets .. " candidates")
    append("teleport carrier=" .. tostring(player_name_of(controller)) ..
           " pawn=" .. full(pawn) ..
           " target(" .. kind .. ")=" .. full(briefcase) ..
           " at " .. vector_text(location) ..
           " ok=" .. tostring(ok and moved) .. " error=" .. tostring(err))
    if not ok then return false, tostring(err) end
    if not moved then return false, "K2_TeleportTo returned false (blocked?)" end
    return true, nil
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

    if phase < PHASE_BY_NAME.VAULT_LOCKED then
        return -- stock lobby/intro flow gets the players spawned first
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
                    append("---- auto loadout on vault open ----")
                    pcall(function() grant_full_resources(controller) end)
                end
                if desired_disguise ~= nil then
                    pcall(function()
                        apply_disguise(controller, desired_disguise)
                    end)
                end
            end
        end

        local ok, why = teleport_carrier_to_briefcase()
        if not ok then pcall(probe_objective_classes) end
        if ok then
            armed = false
            advance_attempted = false
            append("carrier delivered to briefcase; mode handoff complete -- " ..
                   "grab, call extraction, and the stock endgame takes over")
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
grant_full_resources = function(controller)
    local name = tostring(player_name_of(controller))
    local pawn
    pcall(function() pawn = unwrap(controller.Pawn) end)
    if pawn == nil or not is_live(pawn) then
        return false, "no live pawn for " .. name .. " (not deployed?)"
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
    append("loadout grant for " .. name .. " pawn=" .. full(pawn) ..
           " granted=" .. granted .. " skipped=" .. skipped ..
           " failed=" .. failed)
    return true, nil
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

local function consume_loadout()
    local fh = io.open(LOADOUT, "r")
    if fh == nil then return end
    local payload = fh:read("*l")
    fh:close()
    os.remove(LOADOUT)
    if payload then payload = payload:gsub("^%s+", ""):gsub("%s+$", "") end

    append("---- loadout grant requested target=" .. tostring(payload) .. " ----")
    if payload == "all" then
        local controllers
        pcall(function() controllers = FindAllOf("DeceiveIncPlayerController") end)
        if not controllers then
            append("loadout grant: no controllers in world")
            return
        end
        local done = 0
        for i = 1, #controllers do
            local controller = controllers[i]
            if is_live(controller) then
                local ok, why = grant_full_resources(controller)
                if ok then done = done + 1
                else append("loadout skip: " .. tostring(why)) end
            end
        end
        append("loadout grant complete for " .. done .. " player(s)")
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
        last_logged_phase = nil
        append("auto-armed from DIConfig.ini [Extraction] AutoArm")
    end
    if settings.autoloadout == "1" or
       (settings.autoloadout or ""):lower() == "true" then
        auto_loadout = true
        append("auto-loadout enabled from config")
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
