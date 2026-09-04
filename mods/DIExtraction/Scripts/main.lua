-- DIExtraction: stock-objective custom modes.
-- carrier_extraction keeps the original natural-grab flow. vault_assault uses
-- Trio's native teams/bots, opens the vault, stages defenders at the objective
-- and attackers outside one vault entrance, and enforces one shared
-- attack/extraction deadline around the stock briefcase endgame.
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
-- DIConfig owns this broad gameplay rule. DIExtraction only reads it to avoid
-- fighting that rule by re-applying a forced disguise.
local cover_disabled_by_config = false
-- Forward declaration: extraction_tick re-applies the disguise but is defined
-- above apply_disguise, and without this the name would resolve to a nil global
-- there instead of to the local below.
local apply_disguise
local grant_full_resources
local grant_full_resources_to_pawn
local vault_assault_tick
-- Set from DIConfig.ini; kitting the carrier out is a once-per-match action, so
-- it is latched rather than repeated every tick.
local auto_loadout = false
local carrier_prepared = false

-- The original carrier-extraction behavior remains the default. The
-- vault_assault profile selects the asymmetric 3v3 prototype explicitly.
local extraction_mode = "carrier_extraction"
local assault_time = 120
local secured_time = 60
local configured_defender_faction = nil
local configured_attacker_faction = nil
local teleport_defenders = true
-- Ambient civilians/staff/guards/technicians/VIPs are ANPCCharacter actors.
-- Player and player-bot agents are ASpy actors instead, so this switch can
-- remove the wandering population without touching either team's bot slots.
local remove_ambient_npcs = false

-- Vault-assault state contains only plain Lua values. UObject wrappers are
-- always reacquired because UE4SS wrappers become unsafe across map travel.
local assault_initialized = false
local assault_secured = false
local assault_deadline = nil
local assault_phase_timed = nil
local assault_defender_faction = nil
local assault_attacker_faction = nil
local assault_prepared = {}
local assault_loadout_prepared = {}
local assault_staging_prepared = {}
local assault_defender_slots = {}
local assault_attacker_slots = {}
local assault_stage_attempts = {}
local assault_objective_block_attempts = {}
local assault_pickup_type_logged = false
local assault_next_defender_slot = 1
local assault_next_attacker_slot = 1
local assault_attacker_spawn = nil
local assault_timeout_declared = false
local assault_timeout_advanced = false
local assault_illegal_carrier = nil
local assault_illegal_remove_at = 0
local assault_ambient_npcs_removed = 0
local assault_npc_cleanup_error = nil
local assault_quarantined_npcs = {}

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
           not name:find("Default__", 1, true) and
           not name:find(".PersistentLevel.None", 1, true)
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

local function number_property(object, name)
    local raw
    if object == nil or not pcall(function() raw = unwrap(object[name]) end) then
        return nil
    end
    if type(raw) == "number" then return raw end
    local converted
    pcall(function() converted = tonumber(raw) end)
    if converted ~= nil then return converted end
    local rendered
    pcall(function() rendered = tostring(raw:ToString()) end)
    if rendered == nil then pcall(function() rendered = tostring(raw) end) end
    if type(rendered) ~= "string" then return nil end
    return tonumber(rendered:match("(-?%d+)$"))
end

local function player_state_of_spy(pawn)
    local state
    pcall(function() state = unwrap(pawn.CachedDIPlayerState) end)
    if state == nil then pcall(function() state = unwrap(pawn.PlayerState) end) end
    if state == nil then
        pcall(function()
            local controller = unwrap(pawn.Controller)
            if controller then state = unwrap(controller.PlayerState) end
        end)
    end
    return state
end

-- Bot pawns use the same ASpy type as human players, so never infer control
-- from the actor class or display name. These two stock flags agreed with the
-- live dedicated-server roster in every observed match.
local function is_bot_spy(pawn)
    local bot = false
    pcall(function()
        if pawn.bIsBot == true then bot = true end
    end)
    local state = player_state_of_spy(pawn)
    pcall(function()
        if state and state.bIsABot == true then bot = true end
    end)
    return bot
end

local function human_controller_of_spy(pawn)
    if is_bot_spy(pawn) then return nil end
    local controller
    pcall(function() controller = unwrap(pawn.Controller) end)
    if controller and is_live(controller) and is_human(controller) then
        return controller
    end
    return nil
end

local function faction_of_spy(pawn)
    local faction = number_property(player_state_of_spy(pawn), "FactionID")
    if faction == nil then
        -- Player bots can finish possession a tick before CachedDIPlayerState is
        -- populated. HealthComponent carries the same combat faction and is
        -- already valid at that point, so it is a safe role-assignment fallback.
        local health
        pcall(function() health = unwrap(pawn.HealthComponent) end)
        faction = number_property(health, "FactionID")
    end
    return faction
end

local function spy_name(pawn)
    local state = player_state_of_spy(pawn)
    local name
    if state then
        pcall(function() name = tostring(state:GetPlayerName():ToString()) end)
        if name == nil then pcall(function() name = tostring(state.PlayerDisplayName) end) end
    end
    return name or full(pawn)
end

local function find_live_spies()
    local found, result = nil, {}
    pcall(function() found = FindAllOf("Spy") end)
    if not found then return result end
    for i = 1, #found do
        if is_live(found[i]) then result[#result + 1] = found[i] end
    end
    return result
end

local function find_live_player_states()
    local found, result = nil, {}
    pcall(function() found = FindAllOf("DIPlayerState") end)
    if not found then return result end
    for i = 1, #found do
        if is_live(found[i]) then result[#result + 1] = found[i] end
    end
    return result
end

-- There is no ambient-population count in UTripwireServerSettings. The map's
-- PopulationManager creates NPCCharacter actors from its own data asset, so a
-- server-only prototype has to neutralize those actors after they appear. Keep
-- the actors registered with PopulationManager: destroying them makes the game
-- replenish them immediately and can produce a runaway spawn loop. Each
-- NPCCharacter owns a separate NPCAIActor; hiding only the character leaves that
-- actor's behavior stack alive and guards can still shoot while invisible. Stop
-- the AI actor, its behavior machine, and live additional components (including
-- NPCGuardComponent) before hiding the character.
-- Use PopulationManager.AllNPCs instead of FindAllOf("NPCCharacter"): a spy's
-- cover/disguise representation is also an NPCCharacter, but is not part of the
-- manager's ambient population. ASpy itself is also a separate ACharacter type.
local function stop_npc_component(component)
    if component == nil or not is_live(component) then return true, nil end
    local tick_stopped, tick_err = pcall(function()
        component:SetComponentTickEnabled(false)
    end)
    if not tick_stopped then return false, describe_error(tick_err) end

    local tick_enabled
    local verified, verify_err = pcall(function()
        tick_enabled = unwrap(component:IsComponentTickEnabled())
    end)
    if not verified then return false, describe_error(verify_err) end
    if tick_enabled ~= false then return false, "component remained ticking" end
    return true, nil
end

-- A guard's gun is a separate AHitscanWeapon actor. Disabling the guard
-- component/AI tick does not cancel fire callbacks that were already queued,
-- which is why a hidden BP_Amber could still damage players. Make every guard
-- attack harmless at both the encounter and weapon layers. Keep the weapon
-- actor alive: destroying manager-owned objects during world cleanup has proven
-- unsafe on the dedicated server.
local function neutralize_npc_guard_component(component)
    if component == nil or not is_live(component) then return true, false, nil end

    local weapon
    local is_guard = pcall(function() weapon = unwrap(component.Weapon) end)
    if not is_guard then return true, false, nil end

    local guard_ok, guard_err = pcall(function()
        component.bInvestigatingSpy = false
        component.bInvestigatingDanger = false
        component.bLookingAtAggroTarget = false
        component.ReplicatedAggroTargetActor = nil
        component.EncounterShootRange = 0.0
        component.EncounterMeleeRange = 0.0
        component.EncounterMeleeDamage = 0.0
        component.EncounterMeleeHitMaxRange = 0.0
    end)
    if not guard_ok then return false, false, describe_error(guard_err) end

    if weapon == nil or not is_live(weapon) then return true, false, nil end
    local weapon_ok, weapon_err = pcall(function()
        -- These are the native AHitscanWeapon damage fields used by ambient
        -- guards. Zeroing all hit variants also covers a shot already queued.
        weapon.Damage = 0.0
        weapon.CriticalDamage = 0.0
        weapon.LimbDamage = 0.0
        weapon.EffectiveRange = 0.0
        weapon:PrimaryEnd()
        weapon:SetActorTickEnabled(false)
        weapon:ForceNetUpdate()
    end)
    if not weapon_ok then return false, false, describe_error(weapon_err) end

    local damage, critical, limb
    local verify_ok, verify_err = pcall(function()
        damage = unwrap(weapon.Damage)
        critical = unwrap(weapon.CriticalDamage)
        limb = unwrap(weapon.LimbDamage)
    end)
    if not verify_ok then return false, false, describe_error(verify_err) end
    if damage ~= 0 or critical ~= 0 or limb ~= 0 then
        return false, false, "guard weapon damage remained non-zero"
    end
    return true, true, nil
end

local function neutralize_ambient_npc_weapons(npc)
    local ai
    local read_ok, read_err = pcall(function() ai = unwrap(npc.NPCAI) end)
    if not read_ok then return false, 0, describe_error(read_err) end
    if ai == nil or not is_live(ai) then return true, 0, nil end

    local additional
    pcall(function() additional = ai.AdditionalComponents end)
    if additional == nil then return true, 0, nil end

    local count = 0
    pcall(function() count = #additional end)
    local weapons = 0
    for i = 1, count do
        local component
        pcall(function() component = unwrap(additional[i]) end)
        local ok, found, err = neutralize_npc_guard_component(component)
        if not ok then
            return false, weapons, "AdditionalComponents[" .. tostring(i) ..
                   "]: " .. tostring(err)
        end
        if found then weapons = weapons + 1 end
    end
    return true, weapons, nil
end

-- Stop the ambient population at its source. SpawnCount is copied from the
-- selected data asset into PopulationManager, so write both the live manager
-- struct and its per-match data instance. The quarantine below remains as a
-- fallback for NPCs that won the startup race.
local function disable_ambient_npc_spawning(managers)
    local changed = 0
    for i = 1, #managers do
        local manager = managers[i]
        if is_live(manager) then
            pcall(function()
                if unwrap(manager.SpawnNPCLevelData.SpawnCount) ~= 0 then
                    manager.SpawnNPCLevelData.SpawnCount = 0
                    changed = changed + 1
                end
            end)
            local instance
            pcall(function() instance = unwrap(manager.InstanceNPCSpawnData) end)
            if instance and is_live(instance) then
                pcall(function()
                    if unwrap(instance.SpawnNPCLevelData.SpawnCount) ~= 0 then
                        instance.SpawnNPCLevelData.SpawnCount = 0
                        changed = changed + 1
                    end
                    instance.NPCsEnteringVaultCount = 0
                end)
            end
        end
    end
    return changed
end

local function disable_ambient_npc_spawn_assets()
    local assets
    local find_ok, find_err = pcall(function()
        assets = FindAllOf("DIPopulationManagerNpcSpawnDataAsset")
    end)
    if not find_ok then return 0, describe_error(find_err) end
    if assets == nil then return 0, nil end

    local changed = 0
    for i = 1, #assets do
        local asset = assets[i]
        if is_live(asset) then
            pcall(function()
                if unwrap(asset.SpawnNPCLevelData.SpawnCount) ~= 0 then
                    asset.SpawnNPCLevelData.SpawnCount = 0
                    changed = changed + 1
                end
                asset.NPCsEnteringVaultCount = 0
            end)
        end
    end
    return changed, nil
end

local function stop_ambient_npc_ai(npc)
    local ai
    local ai_ok, ai_err = pcall(function() ai = unwrap(npc.NPCAI) end)
    if not ai_ok then return false, describe_error(ai_err) end
    if ai == nil or not is_live(ai) then return false, "NPCAI not ready" end

    local actor_ok, actor_err = pcall(function()
        ai:SetActorTickEnabled(false)
    end)
    if not actor_ok then return false, describe_error(actor_err) end

    local behavior_machine
    local machine_read_ok, machine_read_err = pcall(function()
        behavior_machine = unwrap(ai.BehaviorMachine)
    end)
    if not machine_read_ok then
        return false, "BehaviorMachine unavailable: " ..
                      describe_error(machine_read_err)
    end
    local machine_ok, machine_err = stop_npc_component(behavior_machine)
    if not machine_ok then
        return false, "BehaviorMachine: " .. tostring(machine_err)
    end

    local additional
    pcall(function() additional = ai.AdditionalComponents end)
    if additional then
        local count = 0
        pcall(function() count = #additional end)
        for i = 1, count do
            local component
            pcall(function() component = unwrap(additional[i]) end)
            local component_ok, component_err = stop_npc_component(component)
            if not component_ok then
                return false, "AdditionalComponents[" .. tostring(i) ..
                              "]: " .. tostring(component_err)
            end
        end
    end

    local actor_tick
    local verify_ok, verify_err = pcall(function()
        actor_tick = unwrap(ai:IsActorTickEnabled())
    end)
    if not verify_ok then return false, describe_error(verify_err) end
    if actor_tick ~= false then return false, "NPCAI actor remained ticking" end
    return true, nil
end

local function remove_ambient_npcs_tick()
    if not remove_ambient_npcs then return end
    local asset_changes, asset_error = disable_ambient_npc_spawn_assets()
    if asset_error ~= nil and asset_error ~= assault_npc_cleanup_error then
        assault_npc_cleanup_error = asset_error
        append("ambient NPC spawn-data lookup failed: " .. asset_error)
    elseif asset_changes > 0 then
        append("ambient NPC spawning disabled in " .. asset_changes ..
               " loaded spawn data asset(s)")
    end
    local managers
    local find_ok, find_err = pcall(function()
        managers = FindAllOf("PopulationManager")
    end)
    if not find_ok then
        local message = describe_error(find_err)
        if message ~= assault_npc_cleanup_error then
            assault_npc_cleanup_error = message
            append("ambient NPC cleanup lookup failed: " .. message)
        end
        return
    end
    if not managers then return end

    local spawn_limits_changed = disable_ambient_npc_spawning(managers)
    if spawn_limits_changed > 0 then
        append("ambient NPC spawning disabled at " .. spawn_limits_changed ..
               " live population source(s)")
    end

    -- Snapshot the manager-owned population before mutating actor state.
    local targets = {}
    local seen = {}
    for i = 1, #managers do
        local manager = managers[i]
        if is_live(manager) then
            local population
            pcall(function() population = manager.AllNPCs end)
            if population then
                local count = 0
                pcall(function() count = #population end)
                for j = 1, count do
                    local npc
                    pcall(function() npc = unwrap(population[j]) end)
                    if npc ~= nil and is_live(npc) then
                        local key = full(npc)
                        if not seen[key] then
                            seen[key] = true
                            targets[#targets + 1] = npc
                        end
                    end
                end
            end
        end
    end

    local removed = 0
    local neutralized_weapons = 0
    local failed = 0
    local first_error = nil
    for i = 1, #targets do
        local npc = targets[i]
        local key = full(npc)
        -- Recheck even after quarantine: a guard weapon can be created by a
        -- delayed callback after the NPC itself was hidden.
        local weapon_ok, weapon_count, weapon_err =
            neutralize_ambient_npc_weapons(npc)
        neutralized_weapons = neutralized_weapons + weapon_count
        if not weapon_ok then
            failed = failed + 1
            first_error = first_error or weapon_err
        end
        if is_live(npc) and not assault_quarantined_npcs[key] then
            local ai_ok, ai_err = stop_ambient_npc_ai(npc)
            local hide_ok, hide_err = false, nil
            local collision_ok, collision_err = false, nil
            local tick_ok, tick_err = false, nil
            local net_ok, net_err = false, nil
            if ai_ok then
                hide_ok, hide_err = pcall(function()
                    npc:SetActorHiddenInGame(true)
                end)
                collision_ok, collision_err = pcall(function()
                    npc:SetActorEnableCollision(false)
                end)
                tick_ok, tick_err = pcall(function()
                    npc:SetActorTickEnabled(false)
                end)
                net_ok, net_err = pcall(function() npc:ForceNetUpdate() end)
            end
            if weapon_ok and ai_ok and hide_ok and collision_ok and tick_ok and net_ok then
                assault_quarantined_npcs[key] = true
                removed = removed + 1
            else
                failed = failed + 1
                first_error = first_error or describe_error(
                    ai_err or hide_err or collision_err or tick_err or net_err)
            end
        end
    end

    if removed > 0 then
        assault_ambient_npcs_removed = assault_ambient_npcs_removed + removed
        append("ambient NPC cleanup: AI-stopped/quarantined=" .. removed ..
               " total=" .. assault_ambient_npcs_removed ..
               " (Spy agents and player bots untouched)")
    end
    if neutralized_weapons > 0 and removed > 0 then
        append("ambient guard weapons neutralized=" .. neutralized_weapons)
    end
    if failed > 0 then
        local message = tostring(failed) .. " actor(s): " .. tostring(first_error)
        if message ~= assault_npc_cleanup_error then
            assault_npc_cleanup_error = message
            append("ambient NPC cleanup failed for " .. message)
        end
    elseif find_ok then
        assault_npc_cleanup_error = nil
    end
end

local function reset_vault_assault_state()
    assault_initialized = false
    assault_secured = false
    assault_deadline = nil
    assault_phase_timed = nil
    assault_defender_faction = configured_defender_faction
    assault_attacker_faction = configured_attacker_faction
    assault_prepared = {}
    assault_loadout_prepared = {}
    assault_staging_prepared = {}
    assault_defender_slots = {}
    assault_attacker_slots = {}
    assault_stage_attempts = {}
    assault_objective_block_attempts = {}
    assault_pickup_type_logged = false
    assault_next_defender_slot = 1
    assault_next_attacker_slot = 1
    assault_attacker_spawn = nil
    assault_timeout_declared = false
    assault_timeout_advanced = false
    assault_illegal_carrier = nil
    assault_illegal_remove_at = 0
    assault_ambient_npcs_removed = 0
    assault_npc_cleanup_error = nil
    assault_quarantined_npcs = {}
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

-- Not every BP_Briefcase_C is a pickable objective. Each spy carries several
-- display-only ItemCache instances. The real case has a plain BP_Briefcase_C
-- object name; while it is in the vault it may still be attached to its
-- pedestal, so attachment cannot be used to decide interaction eligibility.
local function is_pickup_briefcase(case)
    if not is_live(case) then return false end
    local name = full(case)
    local short = name:match("([^.]+)$") or name
    if short:find("ItemCache", 1, true) then return false end
    if not short:find("^BP_Briefcase_C") then return false end
    return true
end

local INTERACTABLE_TYPE_BY_NAME = {
    Invalid = 0, IntelSource = 1, KeyCard = 2, Ammo = 3, NPC = 4,
    Spy = 5, Door = 6, HackableDoor = 7, Container = 8, Chest = 9,
    StrongBox = 10, PowerupModule = 11, SpyCache = 12, Objective = 13,
    Extraction = 14, VaultTerminal = 15, ObjectiveTerminal = 16,
    Furniture = 17, AmmoDispenser = 18, HealthDispenser = 19,
    Social = 20, PickableTool = 21, Pickable_HardCurrency = 22,
    Pickable_SoftCurrency = 23, Pickable_XP = 24, Breadcrumb = 25,
    Consumable = 26, Deployable_BounceMat = 27, Deployable_Turret = 28,
    Deployable_Drone = 29, Deployable_Goopod = 30,
    Deployable_Tripwire = 31, Deployable_Scrambler = 32,
    Deployable_SoundMachine = 33, Environment_WindowShutter = 34,
    Environment_ElevatorCallButton = 35, KeycardPrinter = 36,
    LostAndFound = 37, HealthConsumable = 38,
    HealthConsumableDispenser = 39, RetinalScanner = 40,
}

local INTERACTABLE_NAME_BY_TYPE = {}
for name, value in pairs(INTERACTABLE_TYPE_BY_NAME) do
    INTERACTABLE_NAME_BY_TYPE[value] = name
end

local function normalize_interactable_type(raw)
    raw = unwrap(raw)
    if type(raw) == "number" then return raw end
    local converted
    pcall(function() converted = tonumber(raw) end)
    if converted ~= nil then return converted end
    local rendered
    pcall(function() rendered = tostring(raw:ToString()) end)
    if rendered == nil then pcall(function() rendered = tostring(raw) end) end
    if type(rendered) ~= "string" then return nil end
    local numeric = tonumber(rendered:match("(-?%d+)$"))
    if numeric ~= nil then return numeric end
    local name = rendered:match("EInteractableType::([%w_]+)$") or
                 rendered:match("([%w_]+)$")
    return name and INTERACTABLE_TYPE_BY_NAME[name] or nil
end

local function find_pickup_briefcase()
    local cases
    pcall(function() cases = FindAllOf("BP_Briefcase_C") end)
    if not cases then return nil end
    for i = 1, #cases do
        if is_pickup_briefcase(cases[i]) then return cases[i] end
    end
    return nil
end

-- The visible case is not necessarily the actor being interacted with. On
-- Diamond Spire no standalone world BP_Briefcase exists before pickup; the
-- universal objective terminal owns the InteractableComponent and grants the
-- case when its Blueprint event completes. Prefer a real case where one exists,
-- otherwise gate the terminal that actually drives the stock phase change.
local function find_objective_pickup_source()
    local briefcase = find_pickup_briefcase()
    if briefcase ~= nil then return briefcase, "briefcase" end
    local terminals
    pcall(function() terminals = FindAllOf("Bp_Objective_Terminal_C") end)
    if terminals then
        for i = 1, #terminals do
            if is_live(terminals[i]) then
                return terminals[i], "objective terminal"
            end
        end
    end
    return nil, nil
end

local function interactable_type_of(actor)
    local type_value = number_property(actor, "InteractableType")
    if type_value == nil then
        local raw
        pcall(function() raw = actor:GetInteractableType() end)
        type_value = normalize_interactable_type(raw)
    end
    return type_value
end

-- Teleport targeting is stricter: only a detached world case is safe. When the
-- case is still attached in the vault, the objective pedestal is used instead.
local function is_world_briefcase(case)
    if not is_pickup_briefcase(case) then return false end
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
    if extraction_mode == "vault_assault" then
        return vault_assault_tick()
    end
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
grant_full_resources_to_pawn = function(pawn, display_name)
    local name = tostring(display_name or spy_name(pawn))
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

grant_full_resources = function(controller)
    local name = tostring(player_name_of(controller))
    local pawn
    pcall(function() pawn = unwrap(controller.Pawn) end)
    return grant_full_resources_to_pawn(pawn, name)
end

local function resolve_assault_factions(spies)
    if assault_defender_faction ~= nil and assault_attacker_faction ~= nil then
        return true
    end

    local seen, factions = {}, {}
    for _, pawn in ipairs(spies) do
        local faction = faction_of_spy(pawn)
        if faction ~= nil and faction < 200 and not seen[faction] then
            seen[faction] = true
            factions[#factions + 1] = faction
        end
    end
    table.sort(factions)
    assault_defender_faction = assault_defender_faction or factions[1]
    for _, faction in ipairs(factions) do
        if faction ~= assault_defender_faction then
            assault_attacker_faction = assault_attacker_faction or faction
            break
        end
    end
    if assault_defender_faction == nil or assault_attacker_faction == nil then
        return false
    end
    append("vault assault roles: defenders=faction " ..
           tostring(assault_defender_faction) .. " attackers=faction " ..
           tostring(assault_attacker_faction))
    return true
end

local DEFENDER_OFFSETS = {
    { 0.0,    0.0, 300.0 },
    { 260.0,  0.0, 180.0 },
    { -260.0, 0.0, 180.0 },
    { 0.0,  260.0, 180.0 },
    { 0.0, -260.0, 180.0 },
    { 420.0,  0.0, 220.0 },
    { -420.0, 0.0, 220.0 },
}

-- Attackers share one randomly selected vault entrance per match. Positions
-- are measured in centimetres: 500 is five metres beyond the door, away from
-- the objective, and the lateral offsets spread a Trio across the corridor.
local ATTACKER_DOOR_DISTANCES = { 500.0, 700.0, 900.0 }
local ATTACKER_LATERAL_OFFSETS = { 0.0, -180.0, 180.0, -360.0, 360.0 }

local function choose_attacker_spawn()
    if assault_attacker_spawn ~= nil then
        return assault_attacker_spawn, nil
    end

    local objective, objective_kind = find_objective_target()
    if objective == nil then return nil, "no usable objective anchor" end
    local objective_location = actor_location(objective)
    if not is_usable_location(objective_location) then
        return nil, "objective anchor location invalid"
    end

    local doors
    pcall(function() doors = FindAllOf("BP_VaultDoorBase_C") end)
    if not doors then return nil, "no vault-door actors in world" end

    local candidates = {}
    for i = 1, #doors do
        local door = doors[i]
        if is_live(door) then
            local location = actor_location(door)
            if is_usable_location(location) then
                local dx = location.X - objective_location.X
                local dy = location.Y - objective_location.Y
                local horizontal_distance = math.sqrt(dx * dx + dy * dy)
                -- Reject a class default object or a decorative actor located
                -- at the objective itself; neither defines an outside vector.
                if horizontal_distance >= 400.0 then
                    candidates[#candidates + 1] = {
                        key = full(door),
                        x = location.X,
                        y = location.Y,
                        z = location.Z,
                        outward_x = dx / horizontal_distance,
                        outward_y = dy / horizontal_distance,
                    }
                end
            end
        end
    end
    if #candidates == 0 then
        return nil, "no usable vault-door locations"
    end
    table.sort(candidates, function(a, b) return a.key < b.key end)

    -- Sorting removes FindAllOf iteration-order noise. The current wall-clock
    -- second then varies the entrance between matches without seeding or
    -- disturbing Lua's process-wide random-number generator.
    local selected = candidates[(math.abs(os.time()) % #candidates) + 1]
    assault_attacker_spawn = selected
    append("attacker entrance selected: " .. selected.key .. " door=" ..
           vector_text({ X = selected.x, Y = selected.y, Z = selected.z }) ..
           " objective=" .. tostring(objective_kind) .. " candidates=" ..
           tostring(#candidates))
    return selected, nil
end

local function teleport_attacker_to_vault_entrance(pawn, slot)
    local spawn, why = choose_attacker_spawn()
    if spawn == nil then return false, why end

    -- Perpendicular to the objective->door vector, used to fan the team out
    -- while keeping every attacker immediately outside the same entrance.
    local side_x = -spawn.outward_y
    local side_y = spawn.outward_x
    for distance_step = 1, #ATTACKER_DOOR_DISTANCES do
        local distance = ATTACKER_DOOR_DISTANCES[distance_step]
        for lateral_step = 0, #ATTACKER_LATERAL_OFFSETS - 1 do
            local index = ((slot - 1 + lateral_step) %
                           #ATTACKER_LATERAL_OFFSETS) + 1
            local lateral = ATTACKER_LATERAL_OFFSETS[index]
            local destination = {
                X = spawn.x + spawn.outward_x * distance + side_x * lateral,
                Y = spawn.y + spawn.outward_y * distance + side_y * lateral,
                Z = spawn.z + 180.0,
            }
            local moved = false
            local ok, err = pcall(function()
                moved = pawn:K2_TeleportTo(
                    destination, { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 })
            end)
            if ok and moved then
                append("attacker staged: " .. spy_name(pawn) .. " faction=" ..
                       tostring(faction_of_spy(pawn)) .. " entrance=" ..
                       spawn.key .. " destination=" .. vector_text(destination))
                return true, nil
            end
            if not ok then
                append("attacker teleport call failed for " .. spy_name(pawn) ..
                       ": " .. describe_error(err))
            end
        end
    end
    return false, "every collision-safe entrance offset was blocked"
end

-- Query the live pickup source instead of assuming it uses
-- EInteractableType::Objective. The previous hard-coded type 13 request was
-- accepted by the UFunction but did not match the pickup path on the live
-- actor: a defender could complete the stock pickup, advance the phase, then
-- have the resource stripped one tick later. Validate the native block against
-- the exact source before considering a defender prepared.
local function block_defender_briefcase_interaction(pawn, pickup_source)
    if pickup_source == nil or not is_live(pickup_source) then
        return false, "live objective pickup source not available"
    end
    local interactable_type = interactable_type_of(pickup_source)
    if type(interactable_type) ~= "number" or interactable_type < 0 or
       interactable_type >= 41 then
        return false, "pickup source InteractableType unreadable (" ..
                      scalar_property(pickup_source, "InteractableType") .. ")"
    end
    local pickup_interactable
    pcall(function()
        pickup_interactable = unwrap(pickup_source:GetInteractableComponent())
    end)
    if pickup_interactable == nil or not is_live(pickup_interactable) then
        pcall(function()
            pickup_interactable = unwrap(pickup_source.InteractableComp)
        end)
    end
    if pickup_interactable == nil or not is_live(pickup_interactable) then
        return false, "pickup source has no live InteractableComponent"
    end

    local interacter
    pcall(function() interacter = unwrap(pawn.InteracterComponent) end)
    if interacter == nil or not is_live(interacter) then
        return false, "no live InteracterComponent"
    end
    local ok, err = pcall(function()
        interacter:BlockInteractableTypes({ interactable_type }, pawn)
    end)
    if not ok then return false, describe_error(err) end

    local blocked, valid
    local blocked_ok, blocked_err = pcall(function()
        blocked = unwrap(interacter:IsInteractTypeBlocked(pickup_interactable))
    end)
    pcall(function()
        valid = unwrap(interacter:IsValidInteractType(pickup_interactable, true))
    end)
    if not blocked_ok then return false, describe_error(blocked_err) end
    if blocked ~= true then
        return false, "native verification failed: type=" ..
                      tostring(INTERACTABLE_NAME_BY_TYPE[interactable_type] or "?") ..
                      "(" .. tostring(interactable_type) .. ") blocked=" ..
                      tostring(blocked) .. " valid=" .. tostring(valid)
    end
    return true, "type=" ..
                 tostring(INTERACTABLE_NAME_BY_TYPE[interactable_type] or "?") ..
                 "(" .. tostring(interactable_type) .. ") blocked=true valid=" ..
                 tostring(valid)
end

local function teleport_defender_to_objective(pawn, slot)
    local target, kind = find_objective_target()
    if target == nil then return false, "no usable objective anchor" end
    local location = actor_location(target)
    if not is_usable_location(location) then return false, "anchor location invalid" end

    -- Start from this defender's own slot, then try every other known-safe
    -- offset. K2_TeleportTo sweeps collision and returns false rather than
    -- placing a pawn inside the pedestal or wall.
    for step = 0, #DEFENDER_OFFSETS - 1 do
        local index = ((slot - 1 + step) % #DEFENDER_OFFSETS) + 1
        local offset = DEFENDER_OFFSETS[index]
        local destination = {
            X = location.X + offset[1],
            Y = location.Y + offset[2],
            Z = location.Z + offset[3],
        }
        local moved = false
        local ok, err = pcall(function()
            moved = pawn:K2_TeleportTo(
                destination, { Pitch = 0.0, Yaw = 180.0, Roll = 0.0 })
        end)
        if ok and moved then
            append("defender staged: " .. spy_name(pawn) .. " faction=" ..
                   tostring(faction_of_spy(pawn)) .. " target=" .. kind ..
                   " offset=" .. string.format("(%+.0f,%+.0f,%+.0f)",
                                                offset[1], offset[2], offset[3]))
            return true, nil
        end
        if not ok then
            append("defender teleport call failed for " .. spy_name(pawn) ..
                   ": " .. describe_error(err))
        end
    end
    return false, "every collision-safe offset was blocked"
end

local function prepare_assault_spies(spies, pickup_source)
    for _, pawn in ipairs(spies) do
        local key = full(player_state_of_spy(pawn))
        if key == "<nil>" or key == "<unrenderable>" then key = full(pawn) end
        if not assault_prepared[key] then
            local faction = faction_of_spy(pawn)
            if faction ~= nil then
                local loadout_ok = assault_loadout_prepared[key] == true
                local loadout_why = nil
                if not auto_loadout then
                    loadout_ok = true
                    assault_loadout_prepared[key] = true
                elseif not loadout_ok then
                    if is_bot_spy(pawn) then
                        -- Calling AddResource across every resource enum while
                        -- bot equipment is initializing reproducibly drives the
                        -- dedicated server into a status-3 shutdown. Bots keep
                        -- the loadout selected by the stock game.
                        loadout_ok = true
                        assault_loadout_prepared[key] = true
                        append("automatic loadout skipped for agent bot " ..
                               spy_name(pawn))
                    elseif human_controller_of_spy(pawn) == nil then
                        -- A human pawn may precede its controller/NetConnection
                        -- by a tick. Leave it pending instead of treating it as
                        -- a bot and permanently missing the grant.
                        loadout_why = "waiting for human controller"
                    else
                        loadout_ok, loadout_why = grant_full_resources_to_pawn(
                            pawn, spy_name(pawn))
                        if loadout_ok then
                            assault_loadout_prepared[key] = true
                        end
                    end
                end

                local health
                pcall(function() health = unwrap(pawn.HealthComponent) end)
                if health and is_live(health) then
                    pcall(function() health.bAllowFriendlyFire = false end)
                end

                local staged = assault_staging_prepared[key] == true
                local stage_why = nil
                local objective_blocked, block_why = true, nil
                if faction == assault_defender_faction then
                    objective_blocked, block_why =
                        block_defender_briefcase_interaction(pawn, pickup_source)
                    local attempts = assault_objective_block_attempts[key] or 0
                    assault_objective_block_attempts[key] = attempts + 1
                    if objective_blocked and attempts == 0 then
                        append("defender briefcase interaction verified blocked: " ..
                               spy_name(pawn) .. " faction=" .. tostring(faction) ..
                               " " .. tostring(block_why))
                    elseif not objective_blocked and attempts < 3 then
                        append("defender objective block pending for " ..
                               spy_name(pawn) .. ": " .. tostring(block_why))
                    end
                end
                if faction == assault_attacker_faction and not staged then
                    local slot = assault_attacker_slots[key]
                    if slot == nil then
                        slot = assault_next_attacker_slot
                        assault_attacker_slots[key] = slot
                        assault_next_attacker_slot = assault_next_attacker_slot + 1
                    end
                    local attempts = assault_stage_attempts[key] or 0
                    if attempts < TELEPORT_MAX_ATTEMPTS then
                        staged, stage_why =
                            teleport_attacker_to_vault_entrance(pawn, slot)
                        assault_stage_attempts[key] = attempts + 1
                        if staged then assault_staging_prepared[key] = true end
                    else
                        staged = true
                        assault_staging_prepared[key] = true
                        stage_why = "gave up after " .. TELEPORT_MAX_ATTEMPTS ..
                                    " attempts; kept stock spawn"
                        append("attacker staging gave up for " .. spy_name(pawn) ..
                               ": " .. stage_why)
                    end
                elseif not teleport_defenders or
                       faction ~= assault_defender_faction then
                    staged = true
                    assault_staging_prepared[key] = true
                elseif not staged then
                    local slot = assault_defender_slots[key]
                    if slot == nil then
                        slot = assault_next_defender_slot
                        assault_defender_slots[key] = slot
                        assault_next_defender_slot = assault_next_defender_slot + 1
                    end
                    local attempts = assault_stage_attempts[key] or 0
                    if attempts < TELEPORT_MAX_ATTEMPTS then
                        staged, stage_why = teleport_defender_to_objective(pawn, slot)
                        assault_stage_attempts[key] = attempts + 1
                        if staged then assault_staging_prepared[key] = true end
                    else
                        -- Stop retrying and let the defender play from the stock
                        -- spawn. A missing stage point must never flood the log
                        -- or block the rest of that spy's preparation forever.
                        staged = true
                        assault_staging_prepared[key] = true
                        stage_why = "gave up after " .. TELEPORT_MAX_ATTEMPTS ..
                                    " attempts; kept stock spawn"
                        append("defender staging gave up for " .. spy_name(pawn) ..
                               ": " .. stage_why)
                    end
                end

                -- Leave an unstaged player pending so still-streaming map
                -- geometry gets another bounded attempt on the next tick.
                -- Resource grants are idempotent and skip already-full values.
                if loadout_ok and staged and objective_blocked then
                    assault_prepared[key] = true
                    append("vault assault ready: " .. spy_name(pawn) ..
                           " faction=" .. tostring(faction) ..
                           (faction == assault_defender_faction and
                                " role=DEFENDER" or
                            faction == assault_attacker_faction and
                                " role=ATTACKER" or " role=UNASSIGNED"))
                else
                    append("vault assault preparation pending for " ..
                           spy_name(pawn) .. ": loadout=" ..
                           tostring(loadout_why or loadout_ok) .. " stage=" ..
                           tostring(stage_why or staged) .. " objective_block=" ..
                           tostring(block_why or objective_blocked))
                end
            end
        end
    end
end

local function set_phase_time(game_state, seconds, reason)
    local value = math.max(1, math.floor(seconds + 0.5))
    local before, after, game_after, hud_after
    pcall(function() before = game_state:GetCurrentPhaseTimeLeftInSeconds() end)
    local ok, err = pcall(function()
        game_state:SetCurrentPhaseTimeLeftInSeconds(value)
    end)
    pcall(function() after = game_state:GetCurrentPhaseTimeLeftInSeconds() end)
    pcall(function() game_after = game_state:GetCurrentGamePhaseTimeLeft() end)
    pcall(function() hud_after = game_state:GetTimeLeftforHUD() end)
    append("vault assault timer " .. tostring(reason) .. ": " ..
           tostring(before) .. " -> " .. tostring(after) ..
           " requested=" .. tostring(value) .. " game=" ..
           tostring(game_after) .. " hud=" .. tostring(hud_after) ..
           " ok=" .. tostring(ok) ..
           (ok and "" or " error=" .. describe_error(err)))
    return ok
end

local function remove_illegal_defender_objective(pawn)
    local resources
    pcall(function() resources = unwrap(pawn.GameplayResourcesComponent) end)
    if resources == nil or not is_live(resources) then
        return false, "no GameplayResourcesComponent"
    end
    local amount
    local read_ok = pcall(function()
        amount = resources:GetResourceAmount(8) -- Mission_Objective
    end)
    if not read_ok or type(amount) ~= "number" or amount <= 0 then
        return false, "Mission_Objective amount unreadable or zero"
    end
    local ok, err = pcall(function() resources:RemoveResource(8, amount) end)
    if not ok then return false, describe_error(err) end
    return true, nil
end

local function mark_defender_winners()
    if assault_defender_faction == nil then return end
    local changed = 0
    for _, state in ipairs(find_live_player_states()) do
        local faction = number_property(state, "FactionID")
        if faction ~= nil then
            local won = faction == assault_defender_faction
            local ok = pcall(function() state.bWon = won end)
            if ok then changed = changed + 1 end
        end
    end
    if not assault_timeout_declared then
        assault_timeout_declared = true
        append("VAULT ASSAULT DEFENDER WIN: objective timer expired; marked " ..
               changed .. " player state(s), defender faction=" ..
               tostring(assault_defender_faction))
    end
end

-- Asymmetric prototype. Trio supplies the native 3-person factions and bots;
-- this layer assigns the first faction as defenders and the second as
-- attackers, opens the vault, stages defenders, grants each human spy a full
-- legal resource loadout, and changes the stock replicated clock from 120
-- seconds to 60 seconds on the first valid attacker pickup. Agent bots retain
-- their stock loadouts. Extraction and its result stay entirely stock.
vault_assault_tick = function()
    if not armed then return end
    remove_ambient_npcs_tick()
    local game_state = find_live_game_state()
    if game_state == nil then return end
    local phase = current_phase(game_state)
    if phase ~= last_logged_phase then
        append("vault assault phase=" .. phase_label(phase))
        last_logged_phase = phase
    end
    if phase == nil or phase < PHASE_BY_NAME.VAULT_LOCKED then return end

    local spies = find_live_spies()
    if phase == PHASE_BY_NAME.VAULT_LOCKED then
        if #spies == 0 then
            append("holding at VAULT_LOCKED: no deployed spies yet")
            return
        end
        if advance_attempted then return end
        advance_attempted = true
        local ok, err = pcall(function() game_state:AdvancePhase(true) end)
        append("vault assault AdvancePhase(true) at VAULT_LOCKED spies=" ..
               #spies .. " ok=" .. tostring(ok) .. " error=" ..
               tostring(err))
        return
    end

    if phase >= PHASE_BY_NAME.RESULT_SCREEN then
        if assault_timeout_declared or number_property(game_state, "MatchResult") == 4 then
            mark_defender_winners()
        end
        return
    end

    if phase < PHASE_BY_NAME.VAULT_UNLOCKED or
       phase > PHASE_BY_NAME.EXTRACTION_ARRIVED then return end

    if not assault_initialized then
        assault_initialized = true
        assault_deadline = os.time() + assault_time
        assault_phase_timed = phase
        set_phase_time(game_state, assault_time, "round start")
        append("vault assault live: " .. tostring(assault_time) ..
               "s to secure the briefcase; " .. tostring(secured_time) ..
               "s after attacker pickup; player bots retained; ambient NPCs " ..
               (remove_ambient_npcs and "removed" or "retained"))
    end

    if not resolve_assault_factions(spies) then
        append("vault assault waiting for two populated factions; spies=" .. #spies)
        return
    end
    local pickup_source, pickup_kind = find_objective_pickup_source()
    if pickup_source ~= nil and not assault_pickup_type_logged then
        local live_type = interactable_type_of(pickup_source)
        assault_pickup_type_logged = true
        append("live objective pickup interaction: source=" ..
               tostring(pickup_kind) .. " actor=" .. full(pickup_source) ..
               " property=" ..
               scalar_property(pickup_source, "InteractableType") ..
               " resolved=" ..
               tostring(INTERACTABLE_NAME_BY_TYPE[live_type] or "?") ..
               "(" .. tostring(live_type) .. ")")
    end
    prepare_assault_spies(spies, pickup_source)

    local carrier
    pcall(function() carrier = unwrap(game_state.ObjectiveCarrier) end)
    if carrier ~= nil and is_live(carrier) then
        local carrier_faction = faction_of_spy(carrier)
        local carrier_key = full(carrier)
        if carrier_faction == assault_defender_faction then
            local now = os.time()
            if carrier_key ~= assault_illegal_carrier or
               now - assault_illegal_remove_at >= 3 then
                assault_illegal_carrier = carrier_key
                assault_illegal_remove_at = now
                local ok, why = remove_illegal_defender_objective(carrier)
                append("blocked defender briefcase pickup: " .. spy_name(carrier) ..
                       " faction=" .. tostring(carrier_faction) ..
                       " removed=" .. tostring(ok) .. " detail=" .. tostring(why))
            end
        elseif carrier_faction == assault_attacker_faction and not assault_secured then
            assault_secured = true
            assault_deadline = os.time() + secured_time
            assault_phase_timed = phase
            assault_illegal_carrier = nil
            set_phase_time(game_state, secured_time, "attacker secured briefcase")
            append("VAULT ASSAULT BRIEFCASE SECURED by " .. spy_name(carrier) ..
                   " (faction " .. tostring(carrier_faction) .. "); extraction " ..
                   "deadline in " .. tostring(secured_time) .. "s")
        end
    else
        assault_illegal_carrier = nil
    end

    -- A stock phase change installs that phase's normal duration. Reapply only
    -- on the transition, using the remaining shared deadline, so the initial
    -- assault is one 120-second budget and pickup -> arrival -> extraction is
    -- one 60-second budget.
    if assault_deadline ~= nil then
        local remaining = assault_deadline - os.time()
        if phase ~= assault_phase_timed then
            assault_phase_timed = phase
            set_phase_time(game_state, remaining,
                           "shared extraction deadline in " .. phase_label(phase))
        end
        if remaining <= 1 then
            mark_defender_winners()
            if not assault_timeout_advanced then
                assault_timeout_advanced = true
                local ok, err = pcall(function() game_state:AdvancePhase(true) end)
                append("vault assault timeout AdvancePhase(true) at " ..
                       phase_label(phase) .. " ok=" .. tostring(ok) ..
                       " error=" .. tostring(err))
            end
        end
    end
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
    if cover_disabled_by_config then
        return false, "disabled by [Gameplay] DisableCover"
    end
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
    if cover_disabled_by_config then
        desired_disguise = nil
        append("disguise refused: [Gameplay] DisableCover is enabled")
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
    reset_vault_assault_state()
    last_logged_phase = nil
    append("extraction mode armed; mode=" .. extraction_mode ..
           " carrier_filter=" .. tostring(carrier_filter))
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
        reset_vault_assault_state()
        last_logged_phase = nil
        append("map (re)started; armed " .. extraction_mode ..
               " mode reset to waiting")
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
    local gameplay_settings = {}
    for line in fh:lines() do
        local header = line:match("^%s*%[([^%]]+)%]")
        if header then
            section = header
        elseif section == "Extraction" or section == "Gameplay" then
            local key, value = line:match("^%s*([%w_]+)%s*=%s*([^;\r\n]+)")
            if key then
                local target = section == "Extraction" and settings or
                               gameplay_settings
                target[key:lower()] = (value:gsub("%s+$", ""))
            end
        end
    end
    fh:close()

    if settings.mode and settings.mode ~= "" then
        local selected = settings.mode:lower()
        if selected == "vault_assault" or selected == "carrier_extraction" then
            extraction_mode = selected
            append("extraction mode from config: " .. extraction_mode)
        else
            append("config mode '" .. settings.mode .. "' not recognised; using " ..
                   extraction_mode)
        end
    end
    local configured_assault_time = tonumber(settings.assaulttime)
    if configured_assault_time and configured_assault_time >= 10 then
        assault_time = math.floor(configured_assault_time)
    end
    local configured_secured_time = tonumber(settings.securedtime)
    if configured_secured_time and configured_secured_time >= 10 then
        secured_time = math.floor(configured_secured_time)
    end
    configured_defender_faction = tonumber(settings.defenderfaction)
    configured_attacker_faction = tonumber(settings.attackerfaction)
    if gameplay_settings.disablecover ~= nil then
        local value = gameplay_settings.disablecover:lower()
        cover_disabled_by_config =
            value == "1" or value == "true" or value == "yes"
    end
    if settings.teleportdefenders ~= nil then
        local value = settings.teleportdefenders:lower()
        teleport_defenders = value == "1" or value == "true" or value == "yes"
    end
    if settings.removeambientnpcs ~= nil then
        local value = settings.removeambientnpcs:lower()
        remove_ambient_npcs = value == "1" or value == "true" or value == "yes"
    end

    if settings.autoarm == "1" or (settings.autoarm or ""):lower() == "true" then
        armed = true
        advance_attempted = false
        teleport_attempts = 0
        carrier_prepared = false
        reset_vault_assault_state()
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
    if cover_disabled_by_config then
        desired_disguise = nil
        append("forced disguise disabled by [Gameplay] DisableCover")
    elseif settings.disguise and settings.disguise ~= "" then
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
    if extraction_mode == "vault_assault" then
        append("vault assault config: assault_time=" .. assault_time ..
               " secured_time=" .. secured_time ..
               " defender_faction=" .. tostring(configured_defender_faction) ..
               " attacker_faction=" .. tostring(configured_attacker_faction) ..
               " teleport_defenders=" .. tostring(teleport_defenders) ..
               " remove_ambient_npcs=" .. tostring(remove_ambient_npcs))
    end
end

pcall(load_config)

-- UE4SS loads this module on LVL_StartupServer, before travel to the operation
-- map. Mutate the already-loaded spawn data here so PopulationManager copies a
-- zero count during its BeginPlay instead of racing the one-second game loop.
if armed and extraction_mode == "vault_assault" and remove_ambient_npcs then
    local changed, err = disable_ambient_npc_spawn_assets()
    if err ~= nil then
        append("early ambient NPC spawn-data override failed: " .. tostring(err))
    else
        append("early ambient NPC spawn-data override: changed=" ..
               tostring(changed))
    end
end

-- Do not RegisterHook the global interaction/condition UFunctions here. They
-- execute at very high frequency during intro and traversing UObject state from
-- those UE4SS callbacks caused an access violation in the live server. The
-- once-per-second vault_assault_tick fallback is intentionally retained while
-- attacker-only interaction is moved to a non-hook implementation.

append("DIExtraction loaded; write " .. TRIGGER .. " to arm, " ..
       RECON .. " for a state dump, " .. LOADOUT .. " to grant resources")
