-- DINativeStage2: one-client Route 27 lab prototype; not a finished spectator feature.
-- Route 27: retain no live UE4SS UObject wrappers across callbacks or map
-- travel, and restore the proven DebugFreecam ownership + ClientRestart path.
-- Never request a spectator target while DebugFreecam is acknowledged.
local OUT = "DINativeStage2.log"
local TRIGGER = "DINativeSpectator.stage2-trigger"
local NEXT_DEDICATED = "DINativeSpectator.next-dedicated"
local FORCE_DEATH = "DINativeSpectator.force-death"
local NATIVE_FREEMOVE = "DINativeSpectator.native-freemove"
local READINESS_OVERRIDE = "DINativeSpectator.readiness-override"
-- Stage 3 native invoker handshake. Lua resolves the live pawn + UFunction
-- addresses (only Lua can, via GetAddress) and hands them to the C++ DLL, which
-- calls ProcessEvent on the game thread. dimod writes the *-request files; Lua
-- emits the addressed markers the DLL consumes.
local INVOKE_REQUEST = "DINativeSpectator.invoke-request"
local INVOKE_MARKER = "DINativeSpectator.invoke"
local TRACE_REQUEST = "DINativeSpectator.trace-request"
local TRACE_MARKER = "DINativeSpectator.trace"

-- Login-spectator experiment toggles. A live test showed the stock client DOES
-- honor route29 (Deploy greys out, agent-select briefly drops during the phase
-- change) but then falls back to agent-select instead of the spectator view.
-- The manual phase advance (route31) and pawn handoff (route32-35) predate the
-- native readiness override (route30); now that route30 lets the stalled lobby
-- start on its own, those manual steps may be racing the game's native
-- dedicated-spectator presentation. Disable them to test whether the untouched
-- client enters the spectator view natively once the lobby simply unblocks.
-- Experiment C: native match start (no forced intro) + manual pawn handoff.
-- The native run proved the client enters spectator mode and asks for a target
-- on its own, but no spectator pawn is ever spawned for a dedicated spectator,
-- so it has nothing to view. Supply only the missing pawn; do NOT force the
-- phase intro (route31), which previously yanked the client UI back to
-- agent-select. Without route31 the bots spawn later (~16s), so the handoff
-- must keep retrying until a live target exists (see HANDOFF_MAX_ATTEMPTS).
local MANUAL_PHASE_ADVANCE = false     -- route31 (game advances phase on its own)
local MANUAL_SPECTATOR_HANDOFF = true  -- route32/33 (supply the missing spectator pawn)
local HANDOFF_MAX_ATTEMPTS = 16        -- ~20s of 1250ms retries, covers native bot spawn
-- route35 (auto-spectate + view-target) tripped the status-3 exit when the
-- client was ALREADY natively spectating: writing the replicated
-- bIsAutoSpectating flag on a live spectating controller is illegal-state.
-- The client drives its own follow camera (it sends Server_AskForNextSpectatedActor
-- unprompted), so leave it alone and only give it a pawn. Keep this off unless
-- a test shows the client needs a server nudge.
local DRIVE_FOLLOW_CAMERA = false
-- The server-side RPC_SpectateActor seed is also optional now that the client
-- selects its own target. Off by default to keep the handoff minimal; the
-- client's native A/D cycling should pick a live agent on its own.
local SEED_SPECTATE_TARGET = false
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

-- Return the runtime address of an object (GetAddress), or nil.
local function address_of(object)
    if object == nil then return nil end
    local address
    if pcall(function() address = object:GetAddress() end) and address then
        return address
    end
    return nil
end

-- Resolve a UFunction by its "/Script/..." path to a runtime address. The DLL
-- needs the UFunction pointer to call ProcessEvent(target, func, parms).
local function ufunction_address(path)
    local functions
    pcall(function() functions = FindAllOf("Function") end)
    if not functions then return nil end
    for i = 1, #functions do
        local fn = functions[i]
        local rendered = full(fn)
        if rendered == "Function " .. path then
            return address_of(fn)
        end
    end
    return nil
end

-- First live (non-CDO) instance of class_name sharing the controller's world.
local function first_live_instance(class_name, controller)
    local objs
    pcall(function() objs = FindAllOf(class_name) end)
    if not objs then return nil end
    for i = 1, #objs do
        local o = objs[i]
        local n = full(o)
        if not n:find("Default__", 1, true) and same_world(o, controller) then
            return o
        end
    end
    return nil
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

local function reacquire_named_spy(controller, expected_name)
    if expected_name == nil or expected_name == "<unrenderable>" then
        return nil
    end
    local spies
    pcall(function() spies = FindAllOf("Spy") end)
    if not spies then return nil end
    for i = 1, #spies do
        local candidate = spies[i]
        if full(candidate) == expected_name and
           same_world(candidate, controller) then
            return candidate
        end
    end
    return nil
end

local function drive_client_follow_camera(controller, target_actor)
    -- Route 35: RPC_SpectateActor is a client->server RPC (this build ships no
    -- Client_/NetMulticast_ spectate-target counterpart), so calling it on the
    -- server never moves the owning client's camera. Two genuine server->client
    -- levers do exist; try them in order and log each so a live test can tell
    -- which one, if either, actually follows an agent.
    --
    -- Lever 1: bIsAutoSpectating is a replicated bool with OnRep_IsAutoSpectating.
    -- Setting it server-side and forcing a net update should fire that OnRep on
    -- the client and let the stock DISpectatorPawn run its own follow loop,
    -- preserving the 3P spring-arm framing without any per-target RPC.
    local auto_ok, auto_err = pcall(function()
        controller.bIsAutoSpectating = true
        controller:ForceNetUpdate()
    end)
    append("route35 auto-spectate set ok=" .. tostring(auto_ok) ..
           " bIsAutoSpectating=" .. scalar_property(controller, "bIsAutoSpectating") ..
           " error=" .. tostring(auto_err))

    -- Lever 2 (fallback): the engine's SetViewTargetWithBlend is a real
    -- server->client view-target change. It points the client camera straight
    -- at the spy, bypassing the pawn's spring-arm framing, but guarantees a
    -- visible result and proves server-driven camera control while Spectating.
    -- Delayed so lever 1 gets a replication window first; a watcher can see
    -- whether anything follows before this blend takes over. Only the target's
    -- name string is captured across the delay: reacquire the live spy inside
    -- the callback, never a retained wrapper. VTBlend_Linear = 0.
    local target_name = full(target_actor)
    ExecuteWithDelay(1500, function()
        local live
        pcall(function() live = FindAllOf("DeceiveIncPlayerController") end)
        if not live or #live ~= 1 then
            append("route35 view-target fallback refused: expected one controller, found=" ..
                   tostring(live and #live or 0))
            return
        end
        local ctrl = live[1]
        local spy = reacquire_named_spy(ctrl, target_name)
        if spy == nil then
            append("route35 view-target fallback refused: spy no longer live name=" ..
                   target_name)
            return
        end
        local view_ok, view_err = pcall(function()
            ctrl:SetViewTargetWithBlend(spy, 0.4, 0, 0.0, false)
        end)
        append("route35 SetViewTargetWithBlend ok=" .. tostring(view_ok) ..
               " actor=" .. full(spy) ..
               " state=" .. scalar_property(ctrl, "StateName") ..
               " error=" .. tostring(view_err))
    end)
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

    -- The client already possesses the spectator pawn and drives its own follow
    -- camera. By default do nothing further: seeding a target or writing the
    -- auto-spectate flag on an already-spectating client tripped the status-3
    -- exit. Only act if a test explicitly re-enables a server nudge.
    if not SEED_SPECTATE_TARGET and not DRIVE_FOLLOW_CAMERA then
        append("route32 target init: pawn in place, leaving follow to the native client pawn=" ..
               pawn_name .. " state=" .. scalar_property(controller, "StateName"))
        return
    end

    local target_actor, target_player_state =
        find_live_spy_target(controller)
    if target_actor == nil or target_player_state == nil then
        append("route32 target init refused: no live same-world spy target")
        return
    end

    if SEED_SPECTATE_TARGET then
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

    if DRIVE_FOLLOW_CAMERA then
        drive_client_follow_camera(controller, target_actor)
    end
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
        if attempt < HANDOFF_MAX_ATTEMPTS then
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
        -- BANKED: the DebugFreecam->follow return is not supported. Natural
        -- follow-spectating is pawn-less, so recreating a follow pawn only
        -- strands the client on the dead body. Refuse cleanly and stay in the
        -- (working) freecam instead of stranding. Free-roam via DebugFreecam is
        -- therefore a one-way detach; use follow (A/D) before detaching.
        append("route24 return not supported: staying in DebugFreecam (pawn-less " ..
               "follow cannot be recreated); A/D follow is the primary mode")
        return
    end
    if false then
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

-- Option C (deploy-then-spectate): kill the human's own deployed spy through the
-- game's own health path so the untouched client enters its native, proven
-- death-spectator flow (spectator HUD + working A/D follow). No faction-210
-- login is involved; the player joined as a normal combat player, so the match
-- started the stable way. After this drops the player into spectating,
-- `trigger-stage2` (route 27) can toggle the freecam free-move on top.
local function consume_force_death()
    local fh = io.open(FORCE_DEATH, "r")
    if not fh then return end
    fh:close()
    os.remove(FORCE_DEATH)

    local controllers
    pcall(function() controllers = FindAllOf("DeceiveIncPlayerController") end)
    if not controllers or #controllers < 1 then
        append("force-death refused: no human player controller present")
        return
    end

    for i = 1, #controllers do
        local controller = controllers[i]
        local pawn
        pcall(function() pawn = unwrap(controller.Pawn) end)
        local pawn_name = full(pawn)
        if pawn ~= nil and pawn_name:find("BPSpy_", 1, true) then
            local health
            pcall(function() health = unwrap(pawn.HealthComponent) end)
            if health == nil then
                append("force-death refused: spy has no HealthComponent pawn=" ..
                       pawn_name)
                return
            end
            -- DISABLED: SetHealth(0) does kill the spy, but the HUMAN death
            -- flow (BlowCover -> killcam) then hits the status-3 exit because a
            -- raw health write skips the damage/killer data a real kill sets up.
            -- A bot kill uses the full damage pipeline and is the confirmed
            -- working death->spectator path. Until force-death routes through
            -- that pipeline safely, it only reports state and does not kill.
            local hp, dead = "?", "?"
            pcall(function() hp = tostring(health:GetHealth()) end)
            pcall(function() dead = tostring(health:IsDead()) end)
            append("force-death DISABLED (would crash): pawn=" .. pawn_name ..
                   " hp=" .. hp .. " dead=" .. dead ..
                   " state=" .. scalar_property(controller, "StateName") ..
                   " -- die to a bot instead, then trigger-stage2")
            return
        end
    end
    append("force-death refused: no human controller currently owns a live spy pawn")
end

-- Gate A test: drive the game's OWN free<->follow toggle server-side, instead
-- of the DebugFreecam workaround. The toggle is asymmetric:
--   follow -> free : DISpectatorPawn:CheatSpectateFreeMoveSrv()  (server RPC)
--   free -> follow : DIFreeSpectator:ServerReturnToPlayer()
-- Both are no-arg. If these work, the native return (stuck-in-dead-body) is
-- solved without any C++. Only the client CheatSpectateFreeMove was tried
-- before (and failed); the server Srv entry was never used on its own.
local function consume_native_freemove()
    local fh = io.open(NATIVE_FREEMOVE, "r")
    if not fh then return end
    fh:close()
    os.remove(NATIVE_FREEMOVE)

    local controllers
    pcall(function() controllers = FindAllOf("DeceiveIncPlayerController") end)
    if not controllers or #controllers < 1 then
        append("native-freemove refused: no human player controller")
        return
    end
    local controller = controllers[1]
    local state = scalar_property(controller, "StateName")
    -- The controller's pawn refs point at the dead spy body during natural
    -- follow-spectating, so find the live spectator pawn BY CLASS in the same
    -- world instead. DIFreeSpectator = currently free (go back); DISpectatorPawn
    -- = follow (go free). If neither exists live, natural follow uses no such
    -- pawn and the native free-move entry has nothing to call on.
    local function first_live_same_world(class_name)
        local objs
        pcall(function() objs = FindAllOf(class_name) end)
        if not objs then return nil end
        for i = 1, #objs do
            local o = objs[i]
            local n = full(o)
            if not n:find("Default__", 1, true) and same_world(o, controller) then
                return o
            end
        end
        return nil
    end

    local free = first_live_same_world("DIFreeSpectator")
    local spec = first_live_same_world("DISpectatorPawn")
    append("native-freemove resolve state=" .. state ..
           " live_DIFreeSpectator=" .. (free ~= nil and "yes" or "no") ..
           " live_DISpectatorPawn=" .. (spec ~= nil and "yes" or "no"))

    local action, ok, err
    if free ~= nil then
        action = "DIFreeSpectator:ServerReturnToPlayer"
        ok, err = pcall(function() free:ServerReturnToPlayer() end)
    elseif spec ~= nil then
        action = "DISpectatorPawn:CheatSpectateFreeMoveSrv"
        ok, err = pcall(function() spec:CheatSpectateFreeMoveSrv() end)
    else
        append("native-freemove refused: no live DISpectatorPawn or DIFreeSpectator " ..
               "in this world -- natural follow spectating has no such pawn to drive")
        return
    end

    append("native-freemove call=" .. action .. " ok=" .. tostring(ok) ..
           " state=" .. state .. " error=" .. tostring(err))
    -- Report the resulting pawn/state after the transition replicates. Reacquire
    -- fresh; never retain the pawn wrapper across the delay.
    ExecuteWithDelay(500, function()
        local ctrls
        pcall(function() ctrls = FindAllOf("DeceiveIncPlayerController") end)
        local c2 = ctrls and ctrls[1]
        local frees = 0
        pcall(function() frees = #(FindAllOf("DIFreeSpectator") or {}) end)
        append("native-freemove after call=" .. action ..
               " after_pawn=" .. (c2 and property(c2, "Pawn") or "<none>") ..
               " state=" .. (c2 and scalar_property(c2, "StateName") or "?") ..
               " live_DIFreeSpectator=" .. tostring(frees))
    end)
end

-- Stage 3 handshake. dimod drops DINativeSpectator.invoke-request with a single
-- token ("free"/"follow"); we resolve the live pawn + UFunction addresses and
-- write DINativeSpectator.invoke (target=/func=) for the C++ game-thread invoker.
-- Unlike consume_native_freemove (which calls through UE4SS marshaling), this
-- path hands raw addresses to ProcessEvent and works even where the reflected
-- call boundary is unreliable.
local INVOKE_PLAN = {
    free = {
        class = "DISpectatorPawn",
        func = "/Script/DeceiveInc.DISpectatorPawn:CheatSpectateFreeMoveSrv",
    },
    follow = {
        class = "DIFreeSpectator",
        func = "/Script/DeceiveInc.DIFreeSpectator:ServerReturnToPlayer",
    },
}

-- The game's own free-move (CheatSpectateFreeMoveSrv) is a method ON a
-- DISpectatorPawn, but the death path is pawn-less. Manufacture one from the
-- current follow state using the proven-safe Route 24 sequence (SpawnActor +
-- direct ownership + ClientRestart; NO Possess), so the native call has an
-- instance to run on. The manufactured pawn is what the game would set up on the
-- login path; whether CheatSpectateFreeMoveSrv fully initializes on it is exactly
-- what native-invoke free tests.
local retained_native_spec_name = nil

-- Find a live spectator pawn: either a DISpectatorPawn subclass instance or an
-- instance of the live GameState.SpectatorClass (covers BP_DISpectatorPawn_C
-- whether or not FindAllOf matches subclasses).
local function find_live_spectator_pawn(controller)
    local direct = first_live_instance("DISpectatorPawn", controller)
    if direct then return direct end
    local game_state = find_live_game_state()
    local spectator_class
    if game_state then
        pcall(function() spectator_class = unwrap(game_state.SpectatorClass) end)
    end
    if spectator_class == nil then return nil end
    local class_leaf = full(spectator_class):match("([^%.:/]+)$")
    if not class_leaf then return nil end
    return first_live_instance(class_leaf, controller)
end

local function manufacture_spectator_pawn(controller)
    local player_state
    pcall(function() player_state = unwrap(controller.PlayerState) end)
    local game_state = find_live_game_state()
    if game_state == nil or not same_world(game_state, controller) then
        append("native-spawn refused: no live game state in controller world")
        return nil
    end
    local spectator_class, world
    pcall(function()
        spectator_class = unwrap(game_state.SpectatorClass)
        world = unwrap(controller:GetWorld())
    end)
    if spectator_class == nil or world == nil then
        append("native-spawn refused: SpectatorClass/world unavailable spectator_class=" ..
               full(spectator_class))
        return nil
    end

    -- Spawn near a live spy so the pawn starts inside the level; the exact spot
    -- is unimportant for a pawn that will free-move.
    local anchor = select(1, find_live_spy_target(controller))
    local raw_location, raw_rotation
    pcall(function()
        if anchor ~= nil then
            raw_location = unwrap(anchor:K2_GetActorLocation())
            raw_rotation = unwrap(anchor:K2_GetActorRotation())
        end
    end)
    local location = raw_location and
        { X = raw_location.X, Y = raw_location.Y, Z = raw_location.Z } or
        { X = 0.0, Y = 0.0, Z = 0.0 }
    local rotation = raw_rotation and
        { Pitch = raw_rotation.Pitch, Yaw = raw_rotation.Yaw, Roll = raw_rotation.Roll } or
        { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }

    local fresh_spectator
    local spawn_ok, spawn_error = pcall(function()
        fresh_spectator = world:SpawnActor(spectator_class, location, rotation)
    end)
    append("native-spawn SpawnActor ok=" .. tostring(spawn_ok) ..
           " spectator=" .. full(fresh_spectator) ..
           " error=" .. tostring(spawn_error))
    if not spawn_ok or fresh_spectator == nil then return nil end

    local old_pawn
    pcall(function() old_pawn = unwrap(controller.Pawn) end)
    local handoff_ok, handoff_error = pcall(function()
        if old_pawn ~= nil then old_pawn.Controller = nil end
        fresh_spectator.Controller = controller
        controller.Pawn = fresh_spectator
        if player_state ~= nil then
            player_state.PawnPrivate = fresh_spectator
            player_state:ForceNetUpdate()
        end
        controller:ClientRestart(fresh_spectator)
    end)
    retained_native_spec_name = full(fresh_spectator)
    append("native-spawn handoff ok=" .. tostring(handoff_ok) ..
           " pawn=" .. retained_native_spec_name ..
           " state=" .. scalar_property(controller, "StateName") ..
           " error=" .. tostring(handoff_error))
    if not handoff_ok then return nil end
    return fresh_spectator
end

local function consume_invoke_request()
    local fh = io.open(INVOKE_REQUEST, "r")
    if not fh then return end
    local token = (fh:read("*l") or ""):gsub("%s+", "")
    fh:close()
    os.remove(INVOKE_REQUEST)

    local plan = INVOKE_PLAN[token]
    if not plan then
        append("invoke-request refused: unknown direction '" .. token .. "'")
        return
    end

    local controllers
    pcall(function() controllers = FindAllOf("DeceiveIncPlayerController") end)
    local controller = controllers and controllers[1]
    if not controller then
        append("invoke-request refused: no human player controller")
        return
    end

    local target
    if token == "free" then
        target = find_live_spectator_pawn(controller)
        if not target then
            -- No spectator pawn yet: manufacture one and stop. The client
            -- ClientRestart needs a moment to acknowledge, so re-run
            -- `native-invoke free` to drive CheatSpectateFreeMoveSrv on it.
            local made = manufacture_spectator_pawn(controller)
            if made then
                append("invoke-request direction=free spawned a spectator pawn; " ..
                       "re-run `dimod native-invoke free` to drive free-move on it")
            else
                append("invoke-request direction=free could not manufacture a spectator pawn")
            end
            return
        end
    else
        target = first_live_instance(plan.class, controller)
        if not target then
            append("invoke-request refused direction=" .. token ..
                   " -- no live " .. plan.class .. " in this world")
            return
        end
    end
    local target_addr = address_of(target)
    local func_addr = ufunction_address(plan.func)
    if not target_addr or not func_addr then
        append("invoke-request refused direction=" .. token ..
               " target_addr=" .. tostring(target_addr) ..
               " func_addr=" .. tostring(func_addr))
        return
    end

    local marker = io.open(INVOKE_MARKER, "w")
    if not marker then
        append("invoke-request failed: could not write invoke marker")
        return
    end
    marker:write(string.format("target=0x%X func=0x%X\n", target_addr, func_addr))
    marker:close()
    append(string.format(
        "invoke-request resolved direction=%s target=%s(0x%X) func=%s(0x%X)",
        token, plan.class, target_addr, plan.func, func_addr))
end

-- Default trace watch-set: the two spectator-toggle RPCs plus the follow-target
-- selection RPC, with a controller byte-range that spans the known replicated
-- spectator flags (bIsAutoSpectating ~0x82C). The DLL dumps this range from each
-- call's `self`; diff it across natural-follow / freecam / post-return.
local TRACE_FUNCS = {
    "/Script/DeceiveInc.DeceiveIncPlayerController:RPC_SpectateActor",
    "/Script/DeceiveInc.DeceiveIncPlayerController:Server_AskForNextSpectatedActor",
    "/Script/DeceiveInc.DISpectatorPawn:CheatSpectateFreeMoveSrv",
    "/Script/DeceiveInc.DIFreeSpectator:ServerReturnToPlayer",
}
local TRACE_DUMP_OFFSET = 0x800
local TRACE_DUMP_LENGTH = 0x40

local function consume_trace_request()
    local fh = io.open(TRACE_REQUEST, "r")
    if not fh then return end
    local mode = (fh:read("*l") or ""):gsub("%s+", "")
    fh:close()
    os.remove(TRACE_REQUEST)

    local marker = io.open(TRACE_MARKER, "w")
    if not marker then
        append("trace-request failed: could not write trace marker")
        return
    end
    if mode == "off" then
        marker:write("dumpoff=0x0 dumplen=0x0\n")  -- empty set disables tracing
        marker:close()
        append("trace-request cleared")
        return
    end

    local resolved = 0
    marker:write(string.format("dumpoff=0x%X dumplen=0x%X\n",
                               TRACE_DUMP_OFFSET, TRACE_DUMP_LENGTH))
    for _, path in ipairs(TRACE_FUNCS) do
        local addr = ufunction_address(path)
        if addr then
            marker:write(string.format("func=0x%X\n", addr))
            resolved = resolved + 1
            append(string.format("trace watch %s=0x%X", path, addr))
        else
            append("trace watch unresolved " .. path)
        end
    end
    marker:close()
    append("trace-request armed functions=" .. resolved)
end

local trigger_error
local force_death_error
local native_freemove_error
local invoke_request_error
local trace_request_error
LoopAsync(500, function()
    local ok, err = pcall(consume_trigger)
    if not ok and tostring(err) ~= trigger_error then
        trigger_error = tostring(err)
        append("consume_trigger error=" .. trigger_error)
    elseif ok then
        trigger_error = nil
    end
    local fd_ok, fd_err = pcall(consume_force_death)
    if not fd_ok and tostring(fd_err) ~= force_death_error then
        force_death_error = tostring(fd_err)
        append("consume_force_death error=" .. force_death_error)
    elseif fd_ok then
        force_death_error = nil
    end
    local nf_ok, nf_err = pcall(consume_native_freemove)
    if not nf_ok and tostring(nf_err) ~= native_freemove_error then
        native_freemove_error = tostring(nf_err)
        append("consume_native_freemove error=" .. native_freemove_error)
    elseif nf_ok then
        native_freemove_error = nil
    end
    local iv_ok, iv_err = pcall(consume_invoke_request)
    if not iv_ok and tostring(iv_err) ~= invoke_request_error then
        invoke_request_error = tostring(iv_err)
        append("consume_invoke_request error=" .. invoke_request_error)
    elseif iv_ok then
        invoke_request_error = nil
    end
    local tr_ok, tr_err = pcall(consume_trace_request)
    if not tr_ok and tostring(tr_err) ~= trace_request_error then
        trace_request_error = tostring(tr_err)
        append("consume_trace_request error=" .. trace_request_error)
    elseif tr_ok then
        trace_request_error = nil
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
                append("route29 manual-flow toggles phase_advance=" ..
                       tostring(MANUAL_PHASE_ADVANCE) .. " handoff=" ..
                       tostring(MANUAL_SPECTATOR_HANDOFF))
                if MANUAL_PHASE_ADVANCE then
                    ExecuteWithDelay(2500, function()
                        local phase_ok, phase_error =
                            pcall(advance_spectator_only_pregame)
                        if not phase_ok then
                            append("route31 phase advance callback error=" ..
                                   tostring(phase_error))
                        end
                    end)
                end
                if MANUAL_SPECTATOR_HANDOFF then
                    ExecuteWithDelay(5000, function()
                        local handoff_ok, handoff_error = pcall(function()
                            spawn_dedicated_spectator_pawn(1)
                        end)
                        if not handoff_ok then
                            append("route32 spectator-pawn callback error=" ..
                                   tostring(handoff_error))
                        end
                    end)
                end
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
