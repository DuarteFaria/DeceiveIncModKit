-- DINativeStage2: one-client Route 27 lab prototype; not a finished spectator feature.
-- Route 27: retain no live UE4SS UObject wrappers across callbacks or map
-- travel, and restore the proven DebugFreecam ownership + ClientRestart path.
-- Never request a spectator target while DebugFreecam is acknowledged.
local OUT = "DINativeStage2.log"
local TRIGGER = "DINativeSpectator.stage2-trigger"
local NEXT_DEDICATED = "DINativeSpectator.next-dedicated"
local READINESS_OVERRIDE = "DINativeSpectator.readiness-override"
local retained_component = nil
local retained_original_pawn = nil
local retained_spectator = nil
local retained_natural_spectator = nil
local retained_spectating_actor = nil
local retained_spectating_player_state = nil
local retained_debug_freecam_name = nil

local NATIVE_FUNCTION_PATHS = {
    ["/Script/DeceiveInc.DISpectatorPawn:CheatSpectateFreeMove"] = true,
    ["/Script/DeceiveInc.DISpectatorPawn:CheatSpectateFreeMoveSrv"] = true,
    ["/Script/DeceiveInc.DISpectatorPawn:OnToggleAutoSpectateInput"] = true,
    ["/Script/DeceiveInc.DISpectatorPawn:OnSpectateNextInput"] = true,
    ["/Script/DeceiveInc.DIFreeSpectator:ServerReturnToPlayer"] = true,
    ["/Script/DeceiveInc.DIFreecamSettingsMenuUserWidget:SetCollisionsEnabled"] = true,
    ["/Script/DeceiveInc.DIFreecamSettingsMenuUserWidget:IsCollisionEnabled"] = true,
    ["/Script/DeceiveInc.DeceiveIncPlayerController:Server_DEBUGToggleFreecam"] = true,
    ["/Script/DeceiveInc.DeceiveIncPlayerController:Server_AskForNextSpectatedActor"] = true,
    ["/Script/DeceiveInc.DeceiveIncPlayerController:Server_ToggleAutoSpectate"] = true,
    ["/Script/DeceiveInc.DIPlayerState:SetupAsDedicatedSpectator"] = true,
    ["/Script/DeceiveInc.DISpectatorPawn:GetIsDedicatedSpectator"] = true,
    ["/Script/DeceiveInc.DeceiveIncPlayerController:PlayerReadyForSpawn"] = true,
    ["/Script/DeceiveInc.DeceiveIncPlayerController:ServerSelectAgent"] = true,
    ["/Script/DeceiveInc.DeceiveIncCheatManager:CheatIgnorePrivateLobbyMinimumPlayerCount"] = true,
    ["/Script/DeceiveInc.DeceiveIncGameModeBase:OnSpawnBotPlayerTimerEnd"] = true,
    ["/Script/DeceiveInc.DeceiveIncGameStateBase:CheatSkipCurrentPhase"] = true,
    ["/Script/DeceiveInc.DeceiveIncMatchGameState:AdvancePhase"] = true,
    ["/Script/Engine.GameMode:ReadyToStartMatch"] = true,
    ["/Script/Engine.GameMode:StartMatch"] = true,
}

local function append(line)
    local fh = io.open(OUT, "a")
    if fh then
        fh:write(os.date("!%Y-%m-%dT%H:%M:%SZ") .. " " .. tostring(line) .. "\n")
        fh:close()
    end
end

local function full(object)
    if object == nil then return "<nil>" end
    local rendered
    if pcall(function() rendered = object:GetFullName() end) and rendered then return rendered end
    if pcall(function() rendered = object:ToString() end) and rendered then return rendered end
    return "<unrenderable>"
end

local function log_native_function_addresses()
    local functions
    pcall(function() functions = FindAllOf("Function") end)
    if not functions then
        append("ufunction-address scan failed: Function objects unavailable")
        return
    end
    local found = 0
    for i = 1, #functions do
        local fn = functions[i]
        local rendered = full(fn)
        local path = rendered:match("^Function (.+)$")
        if path and NATIVE_FUNCTION_PATHS[path] then
            local address
            local ok = pcall(function() address = fn:GetAddress() end)
            if ok and address then
                append(string.format(
                    "ufunction-address path=%s object=0x%X", path, address))
                found = found + 1
            else
                append("ufunction-address unavailable path=" .. path)
            end
        end
    end
    append("ufunction-address scan complete found=" .. tostring(found))

    for _, specimen in ipairs({
        {
            class_name = "DIFreeSpectator",
            object_path = "/Script/DeceiveInc.Default__DIFreeSpectator",
        },
        {
            class_name = "DISpectatorPawn",
            object_path = "/Script/DeceiveInc.Default__DISpectatorPawn",
        },
        {
            class_name = "DebugFreecam",
            object_path = "/Script/DeceiveInc.Default__DebugFreecam",
        },
        {
            class_name = "DIPlayerState",
            object_path = "/Script/DeceiveInc.Default__DIPlayerState",
        },
        {
            class_name = "DeceiveIncGameModeBase",
            object_path = "/Script/DeceiveInc.Default__DeceiveIncGameModeBase",
        },
    }) do
        local direct_object
        pcall(function()
            direct_object = StaticFindObject(specimen.object_path)
        end)
        if direct_object ~= nil then
            local address
            if pcall(function() address = direct_object:GetAddress() end) and
               address then
                append(string.format(
                    "spectator-object class=%s object=0x%X name=%s",
                    specimen.class_name, address, full(direct_object)))
            end
        else
            append("spectator-object direct lookup failed path=" ..
                   specimen.object_path)
        end

        local objects
        pcall(function() objects = FindAllOf(specimen.class_name) end)
        if objects then
            for i = 1, #objects do
                local object = objects[i]
                local rendered = full(object)
                if rendered:find("Default__", 1, true) then
                    local address
                    if pcall(function() address = object:GetAddress() end) and
                       address then
                        append(string.format(
                            "spectator-object class=%s object=0x%X name=%s",
                            specimen.class_name, address, rendered))
                    end
                end
            end
        end
    end

    local game_modes
    pcall(function() game_modes = FindAllOf("BP_DeceiveIncBaseGameMode_C") end)
    if game_modes then
        for i = 1, #game_modes do
            local game_mode = game_modes[i]
            local rendered = full(game_mode)
            if not rendered:find("Default__", 1, true) then
                local address
                if pcall(function() address = game_mode:GetAddress() end) and
                   address then
                    append(string.format(
                        "spectator-object class=LiveDeceiveIncGameMode object=0x%X name=%s",
                        address, rendered))
                end
            end
        end
    end
end

local function property(object, name)
    local value = "<unavailable>"
    pcall(function() value = full(object[name]) end)
    return value
end

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

local function value_type(value)
    if value == nil then return "nil" end
    local kind = type(value)
    pcall(function() kind = value:type() end)
    return tostring(kind)
end

local function find_live_game_state()
    local states
    pcall(function() states = FindAllOf("GameStateBase") end)
    if not states then return nil end
    for i = 1, #states do
        local name = full(states[i])
        if name ~= "<unrenderable>" and
           not name:find("Default__", 1, true) then
            return states[i]
        end
    end
    return nil
end

local same_world

local function advance_spectator_only_pregame()
    -- Route 30 gets the engine match into InProgress. Ordinarily selecting an
    -- agent also starts the pregame countdown, whose expiry calls
    -- AdvancePhase and then FillEmptySpotsWithBotPlayers. A dedicated
    -- spectator deliberately has no agent selection, so reproduce only that
    -- missing phase transition after revalidating the complete live state.
    local controllers
    pcall(function() controllers = FindAllOf("DeceiveIncPlayerController") end)
    if not controllers or #controllers ~= 1 then
        append("route31 refused phase advance: expected one controller, found=" ..
               tostring(controllers and #controllers or 0))
        return
    end

    local controller = controllers[1]
    local player_state
    pcall(function() player_state = unwrap(controller.PlayerState) end)
    if player_state == nil or tonumber(player_state.FactionID) ~= 210 or
       player_state.bOnlySpectator ~= true then
        append("route31 refused phase advance: connection is not an exclusive faction-210 spectator")
        return
    end

    local game_state = find_live_game_state()
    if game_state == nil or not same_world(game_state, controller) then
        append("route31 refused phase advance: same-world game state unavailable")
        return
    end

    local phase = scalar_property(game_state, "GamePhase")
    local in_pregame = scalar_property(game_state, "bIsInPregame")
    local match_state = "<unavailable>"
    pcall(function()
        local raw = unwrap(game_state:GetMatchState())
        match_state = full(raw)
        if match_state == "<unrenderable>" then match_state = tostring(raw) end
    end)
    local phase_is_pregame = tonumber(phase) == 1 or
                             phase == "ESpyGamePhase::PREGAME" or
                             phase == "PREGAME"
    if not phase_is_pregame then
        append("route31 refused phase advance: expected PREGAME, found=" .. phase ..
               " match_state=" .. match_state)
        return
    end

    append("route31 phase advance input game_state=" .. full(game_state) ..
           " phase=" .. phase .. " in_pregame=" .. in_pregame ..
           " match_state=" .. match_state)
    local ok, err = pcall(function()
        -- Native inspection for build 24975521 proves that PREGAME + true is
        -- the genuine timer-expiry branch: it clears bIsInPregame, selects
        -- POSING_SPY_INTRO, and fires the normal phase events. PREGAME + false
        -- only changes the waiting timer and leaves the phase at PREGAME.
        game_state:AdvancePhase(true)
    end)
    append("route31 AdvancePhase(true) ok=" .. tostring(ok) ..
           " phase_after=" .. scalar_property(game_state, "GamePhase") ..
           " error=" .. tostring(err))
end

local function live_object_names(class_name)
    local names = {}
    local objects
    pcall(function() objects = FindAllOf(class_name) end)
    if objects then
        for i = 1, #objects do
            local name = full(objects[i])
            if name ~= "<unrenderable>" and
               not name:find("Default__", 1, true) then
                names[name] = true
            end
        end
    end
    return names
end

same_world = function(left, right)
    if left == nil or right == nil then return false end
    local left_world, right_world
    local ok = pcall(function()
        left_world = unwrap(left:GetWorld())
        right_world = unwrap(right:GetWorld())
    end)
    return ok and left_world ~= nil and right_world ~= nil and
           full(left_world) == full(right_world)
end

local function find_live_spy_target(controller)
    local spies
    pcall(function() spies = FindAllOf("Spy") end)
    if not spies then return nil, nil end

    for i = 1, #spies do
        local spy = spies[i]
        local name = full(spy)
        if name ~= "<unrenderable>" and
           not name:find("Default__", 1, true) and
           same_world(spy, controller) then
            local target_player_state
            pcall(function()
                target_player_state = unwrap(spy.PlayerState)
            end)
            if target_player_state == nil then
                pcall(function()
                    target_player_state = unwrap(spy:GetPlayerState())
                end)
            end
            if target_player_state ~= nil and
               tonumber(target_player_state.FactionID) ~= 210 and
               target_player_state.bIsSpectator ~= true then
                return spy, target_player_state
            end
        end
    end
    return nil, nil
end

local function initialize_dedicated_spectator_target()
    -- Reacquire everything after ClientRestart. Retaining any live UObject
    -- wrapper across this delay has already caused teardown corruption.
    local controllers
    pcall(function() controllers = FindAllOf("DeceiveIncPlayerController") end)
    if not controllers or #controllers ~= 1 then
        append("route32 target init refused: expected one controller, found=" ..
               tostring(controllers and #controllers or 0))
        return
    end

    local controller = controllers[1]
    local player_state, pawn
    pcall(function()
        player_state = unwrap(controller.PlayerState)
        pawn = unwrap(controller.Pawn)
    end)
    local pawn_name = full(pawn)
    if player_state == nil or tonumber(player_state.FactionID) ~= 210 or
       not pawn_name:find("SpectatorPawn", 1, true) then
        append("route32 target init refused: dedicated spectator pawn unavailable pawn=" ..
               pawn_name .. " state=" .. scalar_property(controller, "StateName"))
        return
    end

    local target_actor, target_player_state =
        find_live_spy_target(controller)
    if target_actor == nil or target_player_state == nil then
        append("route32 target init refused: no live same-world spy target")
        return
    end

    local ok, err = pcall(function()
        controller:RPC_SpectateActor(target_actor, target_player_state)
    end)
    append("route32 RPC_SpectateActor ok=" .. tostring(ok) ..
           " actor=" .. full(target_actor) ..
           " target_player_state=" .. full(target_player_state) ..
           " pawn=" .. pawn_name ..
           " state=" .. scalar_property(controller, "StateName") ..
           " error=" .. tostring(err))
end

local function spawn_dedicated_spectator_pawn(attempt)
    attempt = attempt or 1
    local controllers
    pcall(function() controllers = FindAllOf("DeceiveIncPlayerController") end)
    if not controllers or #controllers ~= 1 then
        append("route32 refused handoff: expected one controller, found=" ..
               tostring(controllers and #controllers or 0))
        return
    end

    local controller = controllers[1]
    local player_state, current_pawn
    pcall(function()
        player_state = unwrap(controller.PlayerState)
        current_pawn = unwrap(controller.Pawn)
    end)
    if player_state == nil or tonumber(player_state.FactionID) ~= 210 or
       player_state.bOnlySpectator ~= true then
        append("route32 refused handoff: connection is not an exclusive faction-210 spectator")
        return
    end

    local current_name = full(current_pawn)
    if current_name:find("SpectatorPawn", 1, true) then
        append("route32 handoff already complete pawn=" .. current_name)
        ExecuteWithDelay(750, initialize_dedicated_spectator_target)
        return
    end
    if current_pawn ~= nil and current_name ~= "<unrenderable>" then
        append("route32 refused handoff: controller unexpectedly owns pawn=" ..
               current_name)
        return
    end

    local game_state = find_live_game_state()
    local target_actor, target_player_state =
        find_live_spy_target(controller)
    if game_state == nil or not same_world(game_state, controller) or
       target_actor == nil or target_player_state == nil then
        append("route32 waiting for live bot target attempt=" .. tostring(attempt) ..
               " game_state=" .. full(game_state) ..
               " target=" .. full(target_actor))
        if attempt < 4 then
            ExecuteWithDelay(1250, function()
                spawn_dedicated_spectator_pawn(attempt + 1)
            end)
        end
        return
    end

    local spectator_class, world, raw_location, raw_rotation
    local prepared, prepare_error = pcall(function()
        spectator_class = unwrap(game_state.SpectatorClass)
        world = unwrap(controller:GetWorld())
        raw_location = unwrap(target_actor:K2_GetActorLocation())
        raw_rotation = unwrap(target_actor:K2_GetActorRotation())
    end)
    append("route32 handoff inputs prepared=" .. tostring(prepared) ..
           " attempt=" .. tostring(attempt) ..
           " spectator_class=" .. full(spectator_class) ..
           " target=" .. full(target_actor) ..
           " state=" .. scalar_property(controller, "StateName") ..
           " error=" .. tostring(prepare_error))
    if not prepared or spectator_class == nil or world == nil or
       raw_location == nil or raw_rotation == nil then
        return
    end

    local location = {
        X = raw_location.X,
        Y = raw_location.Y,
        Z = raw_location.Z + 200.0,
    }
    local rotation = {
        Pitch = raw_rotation.Pitch,
        Yaw = raw_rotation.Yaw,
        Roll = raw_rotation.Roll,
    }
    local spectator
    local spawned, spawn_error = pcall(function()
        spectator = world:SpawnActor(spectator_class, location, rotation)
    end)
    append("route32 SpawnActor live SpectatorClass ok=" .. tostring(spawned) ..
           " spectator=" .. full(spectator) ..
           " error=" .. tostring(spawn_error))
    if not spawned or spectator == nil then return end

    -- Possess() is intentionally excluded: it reproducibly terminates this
    -- dedicated server build. This is the same direct ownership plus
    -- ClientRestart handoff that survived the natural-death Route 27 tests.
    local handed_off, handoff_error = pcall(function()
        append("route33 handoff step=assign-spectator-controller begin")
        spectator.Controller = controller
        append("route33 handoff step=assign-spectator-controller complete")
        controller.Pawn = spectator
        append("route33 handoff step=assign-controller-pawn complete")
        -- Do not assign PawnPrivate or force a PlayerState net update here.
        -- Route 32 proved that the controller can own this pawn, then exited
        -- before reaching a client RPC while serializing that redundant
        -- PlayerState mutation. Route 29 already replicated all role flags.
        -- Server_ClientIsReady already leaves this controller in Spectating.
        -- Calling ClientGotoState again from this login-time path caused the
        -- deliberate status-3 exit in Route 33, before the RPC returned.
        append("route34 handoff step=client-goto-spectating bypassed state=" ..
               scalar_property(controller, "StateName"))
        controller:ClientSetSpectatorWaiting(false)
        append("route34 handoff step=client-waiting-false complete")
        controller:ClientRestart(spectator)
        append("route34 handoff step=client-restart complete")
    end)
    append("route34 dedicated spectator handoff ok=" .. tostring(handed_off) ..
           " spectator=" .. full(spectator) ..
           " controller_pawn=" .. property(controller, "Pawn") ..
           " player_state_pawn=" .. property(player_state, "PawnPrivate") ..
           " faction=" .. tostring(player_state.FactionID) ..
           " state=" .. scalar_property(controller, "StateName") ..
           " error=" .. tostring(handoff_error))
    if handed_off then
        ExecuteWithDelay(750, initialize_dedicated_spectator_target)
    end
end

local function reacquire_named_debug_freecam(controller, expected_name)
    if expected_name == nil then return nil end
    local freecams
    pcall(function() freecams = FindAllOf("DebugFreecam") end)
    if not freecams then return nil end
    for i = 1, #freecams do
        local candidate = freecams[i]
        if full(candidate) == expected_name and
           same_world(candidate, controller) then
            return candidate
        end
    end
    return nil
end

local function consume_trigger()
    local fh = io.open(TRIGGER, "r")
    if not fh then return end
    local command = fh:read("*a") or ""
    fh:close()
    os.remove(TRIGGER)
    if not command:find("TRIGGER", 1, true) then
        append("ignored invalid trigger")
        return
    end
    local request_dedicated_setup =
        command:find("DEDICATED", 1, true) ~= nil
    if request_dedicated_setup then
        append("route28 refused: mid-match faction-210 conversion is intentionally fatal; use route29 login designation")
        return
    end

    local controllers
    pcall(function() controllers = FindAllOf("DeceiveIncPlayerController") end)
    if not controllers or #controllers ~= 1 then
        append("refused: expected one human controller, found=" ..
               tostring(controllers and #controllers or 0))
        return
    end
    local controller = controllers[1]
    local player_state
    pcall(function() player_state = controller.PlayerState end)
    local route10_pawn
    local resolved_natural_spectator = false
    pcall(function() route10_pawn = controller.Pawn end)
    local route10_name = full(route10_pawn)
    if route10_pawn == nil or route10_name == "<unrenderable>" then
        local spectator_pawn
        pcall(function() spectator_pawn = controller:GetSpectatorPawn() end)
        spectator_pawn = unwrap(spectator_pawn)
        if spectator_pawn ~= nil then
            route10_pawn = spectator_pawn
            route10_name = full(route10_pawn)
            resolved_natural_spectator = true
            append("route11 resolved natural spectator via GetSpectatorPawn")
        end
    end
    append("route10 trigger controller=" .. full(controller) ..
           " pawn=" .. route10_name .. " state=" ..
           scalar_property(controller, "StateName"))
    if route10_name:find("DebugFreecam", 1, true) then
        local return_state = scalar_property(controller, "StateName")
        if return_state ~= "Spectating" then
            append("route24 refused return: expected Spectating state, found=" ..
                   return_state)
            return
        end
        retained_debug_freecam_name = route10_name
        local raw_location, raw_rotation
        local transform_ok, transform_error = pcall(function()
            raw_location = unwrap(route10_pawn:K2_GetActorLocation())
            raw_rotation = unwrap(route10_pawn:K2_GetActorRotation())
        end)
        if not transform_ok or raw_location == nil or raw_rotation == nil then
            append("route24 refused return: freecam transform unavailable error=" ..
                   tostring(transform_error))
            return
        end
        local return_location = {
            X = raw_location.X, Y = raw_location.Y, Z = raw_location.Z
        }
        local return_rotation = {
            Pitch = raw_rotation.Pitch,
            Yaw = raw_rotation.Yaw,
            Roll = raw_rotation.Roll
        }
        local game_state = find_live_game_state()
        local spectator_class
        if game_state ~= nil then
            pcall(function()
                spectator_class = unwrap(game_state.SpectatorClass)
            end)
        end
        append("route24 return inputs toggle_off=bypassed game_state=" ..
               full(game_state) .. " spectator_class=" ..
               full(spectator_class) .. " freecam_name=" ..
               retained_debug_freecam_name .. " state=" .. return_state)
        if game_state == nil or spectator_class == nil then
            append("route24 refused return: live SpectatorClass unavailable")
            return
        end
        local world, fresh_spectator
        local spawn_ok, spawn_error = pcall(function()
            world = controller:GetWorld()
            fresh_spectator = world:SpawnActor(
                spectator_class, return_location, return_rotation)
        end)
        append("route24 SpawnActor exact SpectatorClass ok=" ..
               tostring(spawn_ok) .. " spectator=" ..
               full(fresh_spectator) .. " error=" .. tostring(spawn_error))
        if not spawn_ok or fresh_spectator == nil then return end

        local restore_ok, restore_error = pcall(function()
            route10_pawn.Controller = nil
            fresh_spectator.Controller = controller
            controller.Pawn = fresh_spectator
            player_state.PawnPrivate = fresh_spectator
            player_state.bIsSpectator = true
            player_state.bOnlySpectator = true
            player_state:ForceNetUpdate()
            controller:ClientRestart(fresh_spectator)
        end)
        append("route24 freecam-to-spectator handoff ok=" ..
               tostring(restore_ok) .. " restart_target=" ..
               full(fresh_spectator) .. " controller_pawn=" ..
               property(controller, "Pawn") .. " player_state_pawn=" ..
               property(player_state, "PawnPrivate") .. " state=" ..
               scalar_property(controller, "StateName") .. " error=" ..
               tostring(restore_error))
        if not restore_ok then return end
        ExecuteWithDelay(500, function()
            local target_ok, target_error = pcall(function()
                controller:Server_AskForNextSpectatedActor(true)
            end)
            append("route24 ask-next after state-preserving return ok=" ..
                   tostring(target_ok) .. " state=" ..
                   scalar_property(controller, "StateName") .. " error=" ..
                   tostring(target_error))
        end)
        return
    end
    if false then
        local raw_location, raw_rotation
        local transform_ok, transform_error = pcall(function()
            raw_location = unwrap(route10_pawn:K2_GetActorLocation())
            raw_rotation = unwrap(route10_pawn:K2_GetActorRotation())
        end)
        if not transform_ok or raw_location == nil or raw_rotation == nil then
            append("route20 refused return: freecam transform unavailable error=" ..
                   tostring(transform_error))
            return
        end
        local return_location = {
            X = raw_location.X, Y = raw_location.Y, Z = raw_location.Z
        }
        local return_rotation = {
            Pitch = raw_rotation.Pitch,
            Yaw = raw_rotation.Yaw,
            Roll = raw_rotation.Roll
        }
        local return_ok, return_error = pcall(function()
            controller:Server_DEBUGToggleFreecam()
        end)
        append("route14 debug-freecam toggle-off ok=" .. tostring(return_ok) ..
               " state=" .. scalar_property(controller, "StateName") ..
               " error=" .. tostring(return_error))
        ExecuteWithDelay(1000, function()
            local game_state = find_live_game_state()
            local spectator_class
            if game_state ~= nil then
                pcall(function()
                    spectator_class = unwrap(game_state.SpectatorClass)
                end)
            end
            append("route20 return spawn inputs game_state=" .. full(game_state) ..
                   " spectator_class=" .. full(spectator_class) ..
                   " controller_pawn=" .. property(controller, "Pawn"))
            if game_state == nil or spectator_class == nil then
                append("route20 refused return: live SpectatorClass unavailable")
                return
            end
            local world, fresh_spectator
            local spawn_ok, spawn_error = pcall(function()
                world = controller:GetWorld()
                fresh_spectator = world:SpawnActor(
                    spectator_class, return_location, return_rotation)
            end)
            append("route20 SpawnActor exact SpectatorClass ok=" ..
                   tostring(spawn_ok) .. " spectator=" ..
                   full(fresh_spectator) .. " error=" .. tostring(spawn_error))
            if not spawn_ok or fresh_spectator == nil then return end

            retained_spectator = fresh_spectator
            retained_natural_spectator = fresh_spectator
            local restore_ok, restore_error = pcall(function()
                fresh_spectator.Controller = controller
                controller.Pawn = fresh_spectator
                player_state.PawnPrivate = fresh_spectator
                player_state.bIsSpectator = true
                player_state.bOnlySpectator = true
                player_state:ForceNetUpdate()
                controller:ClientRestart(fresh_spectator)
            end)
            append("route20 fresh ownership+state+ClientRestart ok=" ..
                   tostring(restore_ok) .. " restart_target=" ..
                   full(fresh_spectator) .. " controller_pawn=" ..
                   property(controller, "Pawn") .. " player_state_pawn=" ..
                   property(player_state, "PawnPrivate") .. " spectator=" ..
                   tostring(player_state.bIsSpectator) .. " only=" ..
                   tostring(player_state.bOnlySpectator) .. " state=" ..
                   scalar_property(controller, "StateName") .. " error=" ..
                   tostring(restore_error))
            if not restore_ok then return end
            ExecuteWithDelay(500, function()
                local target_ok, target_error = pcall(function()
                    controller:Server_AskForNextSpectatedActor(true)
                end)
                append("route20 ask-next after fresh restart ok=" ..
                       tostring(target_ok) .. " error=" ..
                       tostring(target_error))
            end)
        end)
        return
    end

    if resolved_natural_spectator or route10_name:find("DISpectatorPawn", 1, true) then
        local natural_spectator = route10_pawn
        local spectating_actor
        local spectating_player_state
        pcall(function()
            spectating_actor = unwrap(controller:GetViewTarget())
        end)
        if spectating_actor ~= nil then
            pcall(function()
                spectating_player_state =
                    unwrap(spectating_actor:GetPlayerState())
            end)
            if spectating_player_state == nil then
                pcall(function()
                    spectating_player_state =
                        unwrap(spectating_actor.PlayerState)
                end)
            end
        end
        append("route26 inspected natural spectator without retention spectator=" ..
               full(natural_spectator) .. " actor=" ..
               full(spectating_actor) .. " player_state=" ..
               full(spectating_player_state) .. " state=" ..
               scalar_property(controller, "StateName"))
        if retained_debug_freecam_name ~= nil then
            local reacquired = reacquire_named_debug_freecam(
                controller, retained_debug_freecam_name)
            if reacquired ~= nil then
                local reuse_state = scalar_property(controller, "StateName")
                if reuse_state ~= "Spectating" then
                    append("route24 refused freecam reuse: expected Spectating state, found=" ..
                           reuse_state)
                    return
                end
                local reuse_ok, reuse_error = pcall(function()
                    route10_pawn.Controller = nil
                    reacquired.Controller = controller
                    controller.Pawn = reacquired
                    controller:ClientRestart(reacquired)
                end)
                append("route24 reacquired-name freecam handoff ok=" ..
                       tostring(reuse_ok) .. " freecam_name=" ..
                       retained_debug_freecam_name .. " controller_pawn=" ..
                       property(controller, "Pawn") .. " state=" ..
                       scalar_property(controller, "StateName") .. " error=" ..
                       tostring(reuse_error))
                return
            end
            append("route24 stale freecam name rejected for current world name=" ..
                   retained_debug_freecam_name)
            retained_debug_freecam_name = nil
        end
        local existing_freecams = live_object_names("DebugFreecam")
        append("route20 CheatSpectateFreeMove bypassed; using proven debug route")
        do
            local debug_ok, debug_error = pcall(function()
                controller:Server_DEBUGToggleFreecam()
            end)
            append("route12 Server_DEBUGToggleFreecam fallback ok=" ..
                   tostring(debug_ok) .. " error=" .. tostring(debug_error))
            if debug_ok then
                ExecuteWithDelay(500, function()
                    local freecams
                    pcall(function() freecams = FindAllOf("DebugFreecam") end)
                    local debug_pawn
                    if freecams then
                        for i = 1, #freecams do
                            local candidate_name = full(freecams[i])
                            if candidate_name ~= "<unrenderable>" and
                               not candidate_name:find("Default__", 1, true) and
                               not existing_freecams[candidate_name] then
                                debug_pawn = freecams[i]
                                break
                            end
                        end
                    end
                    append("route20 new DebugFreecam lookup count=" ..
                           tostring(freecams and #freecams or 0) ..
                           " selected=" .. full(debug_pawn))
                    if debug_pawn == nil then return end
                    retained_debug_freecam_name = full(debug_pawn)
                    local handoff_ok, handoff_error = pcall(function()
                        debug_pawn.Controller = controller
                        controller.Pawn = debug_pawn
                        controller:ClientRestart(debug_pawn)
                    end)
                    append("route13 debug ownership+ClientRestart ok=" ..
                           tostring(handoff_ok) .. " controller_pawn=" ..
                           property(controller, "Pawn") .. " state=" ..
                           scalar_property(controller, "StateName") ..
                           " retained_name=" .. retained_debug_freecam_name ..
                           " error=" ..
                           tostring(handoff_error))
                end)
            end
        end
        ExecuteWithDelay(1000, function()
            append("route10 after free-move controller_pawn=" ..
                   property(controller, "Pawn"))
        end)
        return
    end

    if route10_pawn == nil or not route10_name:find("BPSpy_", 1, true) then
        append("route10 refused: controller pawn is neither spy nor DISpectatorPawn")
        return
    end

    do
        append("route11 waiting for natural in-game death; no live-pawn mutation performed")
        return
    end

    -- Route 10 reconstructs the server ownership safely and, unlike the
    -- earlier routes, explicitly transitions the remote controller state.
    append("route10-client-state-spectator begin controller=" .. full(controller) ..
           " pawn=" .. property(controller, "Pawn") ..
           " player_state=" .. property(controller, "PlayerState"))

    -- Capture before any component work or possession transition. This is the
    -- body that DIFreeSpectator's built-in return RPC must restore.
    local original_pawn
    local pawn_read_ok, pawn_read_error = pcall(function()
        original_pawn = controller.Pawn
    end)
    if original_pawn == nil then
        append("route3 refused: controller.Pawn unavailable ok=" ..
               tostring(pawn_read_ok) .. " error=" .. tostring(pawn_read_error))
        return
    end
    retained_original_pawn = original_pawn
    append("captured OriginalBody=" .. full(original_pawn))

    local component_class
    local found, find_error = pcall(function()
        component_class = StaticFindObject("/Script/DeceiveInc.SpyCheatsComponent")
    end)
    append("class lookup ok=" .. tostring(found) .. " result=" .. full(component_class) ..
           " error=" .. tostring(find_error))
    if not found or component_class == nil then return end

    local identity_transform = {
        Rotation = {X = 0.0, Y = 0.0, Z = 0.0, W = 1.0},
        Translation = {X = 0.0, Y = 0.0, Z = 0.0},
        Scale3D = {X = 1.0, Y = 1.0, Z = 1.0}
    }
    local created, create_error = pcall(function()
        retained_component = controller:AddComponentByClass(
            component_class, false, identity_transform, false)
    end)
    append("AddComponentByClass ok=" .. tostring(created) ..
           " component=" .. full(retained_component) ..
           " error=" .. tostring(create_error))
    if not created or retained_component == nil then return end

    local activated, activate_error = pcall(function()
        retained_component:Activate(true)
    end)
    append("activate ok=" .. tostring(activated) .. " error=" .. tostring(activate_error))

    -- Intentionally bypass CheatForceSpectator: routes 1/1b/2a established
    -- that it is guarded/no-op and it can transiently clear GetPawn().
    append("CheatForceSpectator bypassed")

    local spectator_class
    local spectator_class_ok, spectator_class_error = pcall(function()
        local game_state = find_live_game_state()
        if game_state ~= nil then spectator_class = game_state.SpectatorClass end
        if spectator_class == nil then
            spectator_class = StaticFindObject("/Script/DeceiveInc.DISpectatorPawn")
        end
    end)
    append("game spectator class ok=" .. tostring(spectator_class_ok) ..
           " result=" .. full(spectator_class) ..
           " error=" .. tostring(spectator_class_error))
    if not spectator_class_ok or spectator_class == nil then return end

    local world, raw_location, raw_rotation
    local prepared, prepare_error = pcall(function()
        world = controller:GetWorld()
        raw_location = unwrap(original_pawn:K2_GetActorLocation())
        raw_rotation = unwrap(original_pawn:K2_GetActorRotation())
    end)
    append("spawn inputs prepared=" .. tostring(prepared) ..
           " world=" .. full(world) ..
           " location_type=" .. value_type(raw_location) ..
           " rotation_type=" .. value_type(raw_rotation) ..
           " error=" .. tostring(prepare_error))
    if not prepared or world == nil or raw_location == nil or raw_rotation == nil then return end

    local location = {X = raw_location.X, Y = raw_location.Y, Z = raw_location.Z}
    local rotation = {
        Pitch = raw_rotation.Pitch,
        Yaw = raw_rotation.Yaw,
        Roll = raw_rotation.Roll
    }
    append(string.format("normalized transform location=(%s,%s,%s) rotation=(%s,%s,%s)",
           tostring(location.X), tostring(location.Y), tostring(location.Z),
           tostring(rotation.Pitch), tostring(rotation.Yaw), tostring(rotation.Roll)))

    local spectator
    local spawned, spawn_error = pcall(function()
        spectator = world:SpawnActor(spectator_class, location, rotation)
    end)
    retained_spectator = spectator
    append("SpawnActor DISpectatorPawn ok=" .. tostring(spawned) ..
           " spectator=" .. full(spectator) ..
           " error=" .. tostring(spawn_error))
    if not spawned or spectator == nil then return end

    append("route8 retains original body in Lua; DIFreeSpectator-only links skipped")

    if player_state == nil then
        append("route4 refused: controller has no PlayerState")
        return
    end
    append("PlayerState before dedicated setup spectator=" ..
           tostring(player_state.bIsSpectator) .. " only=" ..
           tostring(player_state.bOnlySpectator) .. " pawn=" ..
           property(player_state, "PawnPrivate"))
    local dedicated, dedicated_error = pcall(function()
        player_state:SetupAsDedicatedSpectator()
    end)
    append("SetupAsDedicatedSpectator ok=" .. tostring(dedicated) ..
           " spectator=" .. tostring(player_state.bIsSpectator) ..
           " only=" .. tostring(player_state.bOnlySpectator) ..
           " faction=" .. tostring(player_state.FactionID) ..
           " pawn=" .. property(player_state, "PawnPrivate") ..
           " error=" .. tostring(dedicated_error))
    if not dedicated then return end
    if player_state.FactionID ~= 210 then
        append("route28 refused: dedicated setup did not set faction sentinel 210")
        return
    end

    -- SetupAsDedicatedSpectator marks the PlayerState with the reserved
    -- dedicated-spectator faction 210. Preserve it: GetIsDedicatedSpectator()
    -- checks this exact value on both the server and owning client.
    local old_faction = player_state.FactionID
    local synchronized, synchronize_error = pcall(function()
        player_state.bIsSpectator = true
        player_state.bOnlySpectator = true
        player_state.PawnPrivate = spectator
        player_state:ForceNetUpdate()
    end)
    append("replicated spectator sync ok=" .. tostring(synchronized) ..
           " spectator=" .. tostring(player_state.bIsSpectator) ..
           " only=" .. tostring(player_state.bOnlySpectator) ..
           " faction=" .. tostring(player_state.FactionID) ..
           " old_faction=" .. tostring(old_faction) ..
           " pawn=" .. property(player_state, "PawnPrivate") ..
           " error=" .. tostring(synchronize_error))
    if not synchronized then return end

    -- Direct Possess() reproducibly terminates the dedicated server after all
    -- spectator bookkeeping is valid. Route 3b performs the reflected
    -- ownership handoff without firing that guarded lifecycle callback.
    local handed_off, handoff_error = pcall(function()
        original_pawn.Controller = nil
        spectator.Controller = controller
        controller.Pawn = spectator
    end)
    append("ownership handoff ok=" .. tostring(handed_off) ..
           " controller_pawn=" .. property(controller, "Pawn") ..
           " spectator_controller=" .. property(spectator, "Controller") ..
           " original_controller=" .. property(original_pawn, "Controller") ..
           " error=" .. tostring(handoff_error))
    if not handed_off then return end

    local state_changed, state_change_error = pcall(function()
        controller:ClientGotoState("Spectating")
        controller:ClientSetSpectatorWaiting(true)
    end)
    append("ClientGotoState(Spectating) ok=" .. tostring(state_changed) ..
           " error=" .. tostring(state_change_error))
    if not state_changed then return end

    local restarted, restart_error = pcall(function()
        controller:ClientRestart(spectator)
    end)
    append("ClientRestart DISpectatorPawn ok=" .. tostring(restarted) ..
           " error=" .. tostring(restart_error))
    if not restarted then return end

    local client_initialized, client_initialize_error = pcall(function()
        controller:RPC_SpectateActor(original_pawn, player_state)
    end)
    append("RPC_SpectateActor original body ok=" ..
           tostring(client_initialized) .. " actor=" .. full(original_pawn) ..
           " player_state=" .. full(player_state) ..
           " error=" .. tostring(client_initialize_error))
    if not client_initialized then return end

    append("route10 headless UI call deliberately skipped")
    ExecuteWithDelay(1000, function()
        append("route8-follow-spectator after controller_pawn=" .. property(controller, "Pawn") ..
               " player_state=" .. property(controller, "PlayerState") ..
               " retained_original=" .. full(retained_original_pawn) ..
               " retained_spectator=" .. full(retained_spectator))
    end)
end

local trigger_error
LoopAsync(500, function()
    local ok, err = pcall(consume_trigger)
    if not ok and tostring(err) ~= trigger_error then
        trigger_error = tostring(err)
        append("consume_trigger error=" .. trigger_error)
    elseif ok then
        trigger_error = nil
    end
    return false
end)

RegisterHook("/Script/Engine.GameModeBase:StartPlay", function()
    retained_component = nil
    retained_original_pawn = nil
    retained_spectator = nil
    retained_natural_spectator = nil
    retained_spectating_actor = nil
    retained_spectating_player_state = nil
    retained_debug_freecam_name = nil
    append("route state cleared at StartPlay")
end)

-- Route 29 applies the game's faction-210 marker during login, before the
-- match faction manager is constructed. Mid-match SetupAsDedicatedSpectator
-- intentionally exits because faction 210 is not part of an active match.
RegisterHook(
    "/Script/DeceiveInc.DeceiveIncPlayerController:Server_ClientIsReady",
    function(self)
        local marker = io.open(NEXT_DEDICATED, "r")
        if marker == nil then return end
        marker:close()
        os.remove(NEXT_DEDICATED)

        local controller = unwrap(self)
        local player_state
        pcall(function() player_state = unwrap(controller.PlayerState) end)
        if player_state == nil then
            append("route29 failed: next-dedicated PlayerState unavailable")
            return
        end

        local ok, err = pcall(function()
            player_state:SetupAsDedicatedSpectator()
            player_state.bIsSpectator = true
            player_state.bOnlySpectator = true
            player_state:ForceNetUpdate()
        end)
        append("route29 login designation ok=" .. tostring(ok) ..
               " controller=" .. full(controller) ..
               " player_state=" .. full(player_state) ..
               " faction=" .. tostring(player_state.FactionID) ..
               " spectator=" .. tostring(player_state.bIsSpectator) ..
               " only=" .. tostring(player_state.bOnlySpectator) ..
               " error=" .. tostring(err))
        if ok and tonumber(player_state.FactionID) == 210 then
            local readiness = io.open(READINESS_OVERRIDE, "w")
            if readiness then
                readiness:write("FACTION 210 READY\n")
                readiness:close()
                append("route29 armed one-shot native readiness override")
                ExecuteWithDelay(2500, function()
                    local phase_ok, phase_error =
                        pcall(advance_spectator_only_pregame)
                    if not phase_ok then
                        append("route31 phase advance callback error=" ..
                               tostring(phase_error))
                    end
                end)
                ExecuteWithDelay(5000, function()
                    local handoff_ok, handoff_error = pcall(function()
                        spawn_dedicated_spectator_pawn(1)
                    end)
                    if not handoff_ok then
                        append("route32 spectator-pawn callback error=" ..
                               tostring(handoff_error))
                    end
                end)
            else
                append("route29 failed to arm native readiness override")
            end
        end
        -- Do not call PlayerReadyForSpawn for a dedicated spectator. The game
        -- unconditionally forwards the cached agent selection to
        -- ServerSelectAgent, which defeats the role and can fatally start an
        -- agent spawn. A combat player or a native readiness-predicate patch is
        -- required to advance a spectator-only lobby.
    end)

append("DINativeStage2 loaded; route34 restart-only dedicated spectator handoff")
ExecuteWithDelay(3000, function() pcall(log_native_function_addresses) end)
