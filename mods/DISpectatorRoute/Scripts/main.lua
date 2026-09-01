-- DISpectatorRoute: legacy SpectatorClass and debug-freecam experiment.
--
-- The promising lever is AGameStateBase::SpectatorClass. Unreal's normal
-- BeginSpectatingState path uses that replicated class to spawn and possess a
-- spectator pawn. If Deceive Inc. leaves this route intact, replacing the
-- class with ADIFreeSpectator before a player dies should produce real free
-- movement without touching the client.
--
-- [SpectatorRoute]
-- ReplaceClass       = 0 ; legacy class-route experiment
-- DebugToggleFreecam = 0 ; call the game's Server_DEBUGToggleFreecam RPC
-- DebugToggleDelayMs = 25000 ; wait until lobby+intro are over
-- ForcePossessDebug  = 0 ; possess the DebugFreecam pawn after it spawns
--
-- Output: Win64/DISpectatorRoute_dump.txt
local OUT = "DISpectatorRoute_dump.txt"
local INI = "DIConfig.ini"
local replace = 0
local debug_toggle = 0
local debug_delay_ms = 25000
local force_possess_debug = 0

do
    local fh = io.open(INI, "r")
    if fh then
        for line in fh:lines() do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*([^;]+)")
            if k == "ReplaceClass" then replace = tonumber(v) or 0 end
            if k == "DebugToggleFreecam" then debug_toggle = tonumber(v) or 0 end
            if k == "DebugToggleDelayMs" then debug_delay_ms = tonumber(v) or 25000 end
            if k == "ForcePossessDebug" then force_possess_debug = tonumber(v) or 0 end
        end
        fh:close()
    end
end

local function w(s)
    local fh = io.open(OUT, "a")
    if fh then fh:write(tostring(s) .. "\n"); fh:close() end
end

local function log(s) print("[DISpectatorRoute] " .. tostring(s) .. "\n") end
local full

local TARGET_FUNCTIONS = {
    Server_DEBUGToggleFreecam = true,
    CheatSpectateFreeMoveSrv = true,
    CheatSpectateFreeMove = true,
    CheatForceSpectatorSrv = true,
    RPC_SpectateActor = true,
    Server_AskForNextSpectatedActor = true,
    Server_ToggleAutoSpectate = true,
    GetPawn = true,
    Possess = true,
    SetViewTargetWithBlend = true,
    EnableInput = true,
}

local function scan_target_functions()
    local funcs
    pcall(function() funcs = FindAllOf("Function") end)
    w("")
    w("################ target UFunctions ################")
    w("Function objects=" .. tostring(funcs and #funcs or 0))
    if funcs then
        for i = 1, #funcs do
            local f = funcs[i]
            local n
            pcall(function() n = f:GetFName():ToString() end)
            if n and (TARGET_FUNCTIONS[n] or n:lower():find("freecam", 1, true)) then
                w("  " .. n .. " -> " .. full(f))
            end
        end
    end
    w("################ end UFunctions ################")
    log("target UFunction scan complete")
end

full = function(o)
    if o == nil then return "<nil>" end
    local s
    if pcall(function() s = o:GetFullName() end) and s then return s end
    if pcall(function() s = o:ToString() end) and s then return s end
    return "<unrenderable>"
end

local function is_class(o)
    local v = false
    pcall(function() v = o:IsAnyClass() end)
    return v
end

local function find_free_class()
    local candidates = {
        "/Script/DeceiveInc.DIFreeSpectator",
        "/Script/DeceiveIncServer.DIFreeSpectator",
    }
    for _, path in ipairs(candidates) do
        local o
        pcall(function() o = StaticFindObject(path) end)
        if o ~= nil then
            w("free class candidate " .. path .. " -> " .. full(o) ..
              " IsAnyClass=" .. tostring(is_class(o)))
            if is_class(o) then return o end
        end
    end

    -- FindAllOf may return only the class default object. Its GetClass() is the
    -- UClass reference that a ClassProperty needs, so retain that fallback.
    local all
    pcall(function() all = FindAllOf("DIFreeSpectator") end)
    if all then
        for i = 1, #all do
            local o = all[i]
            w("FindAllOf DIFreeSpectator [" .. i .. "] -> " .. full(o) ..
              " IsAnyClass=" .. tostring(is_class(o)))
            if is_class(o) then return o end
            local cls
            pcall(function() cls = o:GetClass() end)
            if cls ~= nil then return cls end
        end
    end
    return nil
end

local handled = {}
local waiting_logged = {}
local toggled_controllers = {}
local probe_done = false
local in_progress_ms = 0
local last_live_free, last_live_follow, last_live_debug = -1, -1, -1
local debug_inspected = false

local function inspect_debug_freecam()
    if debug_inspected then return end
    local all
    pcall(function() all = FindAllOf("DebugFreecam") end)
    if not all then return end
    for i = 1, #all do
        local o = all[i]
        local name = full(o)
        if not is_class(o) and not name:find("Default__", 1, true) then
            debug_inspected = true
            w("")
            w("################ DebugFreecam instance ################")
            w("object=" .. name)
            local pawn_class
            pcall(function() pawn_class = StaticFindObject("/Script/Engine.Pawn") end)
            local is_pawn = false
            if pawn_class then pcall(function() is_pawn = o:IsA(pawn_class) end) end
            w("IsA Pawn=" .. tostring(is_pawn))
            local cls
            pcall(function() cls = o:GetClass() end)
            local guard = 0
            while cls and guard < 12 do
                guard = guard + 1
                local cn
                pcall(function() cn = cls:GetFName():ToString() end)
                w("class[" .. guard .. "]=" .. tostring(cn))
                local next_cls
                pcall(function() next_cls = cls:GetSuperStruct() end)
                cls = next_cls
            end
            w("################ end DebugFreecam ################")
            log("DebugFreecam inspected; IsA Pawn=" .. tostring(is_pawn))
            return
        end
    end
end

local function count_live(class_name)
    local all, n = nil, 0
    pcall(function() all = FindAllOf(class_name) end)
    if not all then return 0 end
    for i = 1, #all do
        local o = all[i]
        local name = full(o)
        if not is_class(o) and not name:find("Default__", 1, true) then
            n = n + 1
        end
    end
    return n
end

local function verify_spawned_pawn()
    local free = count_live("DIFreeSpectator")
    local follow = count_live("DISpectatorPawn")
    local debug = count_live("DebugFreecam")
    if free ~= last_live_free or follow ~= last_live_follow or
       debug ~= last_live_debug then
        last_live_free, last_live_follow, last_live_debug = free, follow, debug
        w("spectator pawn instances: DIFreeSpectator=" .. free ..
          " DISpectatorPawn=" .. follow .. " DebugFreecam=" .. debug)
        log("live spectator pawns: free=" .. free .. " follow=" .. follow ..
            " debug=" .. debug)
    end
    if debug > 0 then pcall(inspect_debug_freecam) end
end

local function match_is_in_progress()
    local states
    pcall(function() states = FindAllOf("GameStateBase") end)
    if not states then return false end
    for i = 1, #states do
        local gs = states[i]
        local name = full(gs)
        if not is_class(gs) and not name:find("Default__", 1, true) then
            local state
            pcall(function() state = gs.MatchState:ToString() end)
            if state == "InProgress" then return true end
        end
    end
    return false
end

local function toggle_debug_freecam()
    if debug_toggle ~= 1 then return end
    if not match_is_in_progress() then
        in_progress_ms = 0
        return
    end
    in_progress_ms = in_progress_ms + 2000
    if in_progress_ms < debug_delay_ms then return end
    local pcs
    pcall(function() pcs = FindAllOf("DeceiveIncPlayerController") end)
    if not pcs then return end
    for i = 1, #pcs do
        local pc = pcs[i]
        local name = full(pc)
        if not is_class(pc) and not name:find("Default__", 1, true) and
           not toggled_controllers[name] then
            -- Mark before the call: if the native RPC is destructive or
            -- asynchronous, never hammer it every two seconds.
            toggled_controllers[name] = true
            w("calling Server_DEBUGToggleFreecam on " .. name)
            log("calling built-in freecam RPC on " .. name)
            ExecuteInGameThread(function()
                local ok = pcall(function() pc:Server_DEBUGToggleFreecam() end)
                w("Server_DEBUGToggleFreecam returned, pcall=" .. tostring(ok))
                log("built-in freecam RPC " .. (ok and "returned" or "FAILED"))
            end)
            if force_possess_debug == 1 then
                ExecuteWithDelay(1500, function()
                    local cams
                    pcall(function() cams = FindAllOf("DebugFreecam") end)
                    if not cams then return end
                    for j = 1, #cams do
                        local cam = cams[j]
                        local cam_name = full(cam)
                        if not is_class(cam) and
                           not cam_name:find("Default__", 1, true) then
                            w("possessing DebugFreecam " .. cam_name ..
                              " with " .. name)
                            log("possessing spawned DebugFreecam pawn")
                            ExecuteInGameThread(function()
                                local ok = pcall(function() pc:Possess(cam) end)
                                w("Possess(DebugFreecam) returned, pcall=" ..
                                  tostring(ok))
                                log("DebugFreecam possession " ..
                                    (ok and "returned" or "FAILED"))
                            end)
                            return
                        end
                    end
                    log("no live DebugFreecam found for possession")
                end)
            end
        end
    end
end

local function probe()
    local states
    pcall(function() states = FindAllOf("GameStateBase") end)
    if not states or #states == 0 then return false end

    w("")
    w("################ spectator route probe ################")
    w("ReplaceClass=" .. tostring(replace))
    local free_class = find_free_class()
    w("selected free class: " .. full(free_class))

    local live = 0
    for i = 1, #states do
        local gs = states[i]
        if not is_class(gs) then
            local name = full(gs)
            -- Ignore class default objects; only a world's live GameState can
            -- drive replication and native spectator spawning.
            if not name:find("Default__", 1, true) and
               (replace == 0 or not handled[name]) then
                live = live + 1
                local before, readable
                readable = pcall(function() before = gs.SpectatorClass end)
                w("GameState [" .. i .. "] " .. name)
                w("  SpectatorClass readable=" .. tostring(readable) ..
                  " value=" .. full(before))
                local match_state = "<unreadable>"
                pcall(function()
                    local v = gs.MatchState
                    match_state = v:ToString()
                end)
                w("  MatchState=" .. tostring(match_state))

                -- Agent selection itself uses SpectatorClass while the player
                -- has no pawn. Replacing it in WaitingToStart skips the agent
                -- UI and drops the client directly into freecam. The first
                -- successful ServerSelectAgent changes MatchState to
                -- InProgress, so arm only after that exact transition.
                local armed = match_state == "InProgress"
                if replace == 1 and not armed and not waiting_logged[name] then
                    waiting_logged[name] = true
                    log("waiting for agent selection (MatchState=" ..
                        tostring(match_state) .. ")")
                end

                if replace == 1 and armed and readable and free_class ~= nil and
                   not handled[name] then
                    local wrote = pcall(function() gs.SpectatorClass = free_class end)
                    local after
                    pcall(function() after = gs.SpectatorClass end)
                    w("  WRITE attempted=" .. tostring(wrote) ..
                      " after=" .. full(after))
                    local stuck = wrote and full(after) == full(free_class)
                    log("SpectatorClass replacement " .. (stuck and "STUCK" or "FAILED"))
                    if stuck then handled[name] = true end
                end
            end
        end
    end

    if live > 0 then
        w("live GameStates=" .. live)
        w("################ end ################")
        log("probe complete -> " .. OUT)
    end
    return live > 0
end

LoopAsync(2000, function()
    if not probe_done then
        local ok, done = pcall(probe)
        if ok and done and replace == 0 then probe_done = true end
    end
    if replace == 1 or debug_toggle == 1 then pcall(verify_spawned_pawn) end
    if debug_toggle == 1 then pcall(toggle_debug_freecam) end
    -- Probe mode needs one snapshot. Replacement mode stays alive so it can
    -- apply to the new GameState after every server-travel/map rotation.
    if replace == 0 and debug_toggle == 0 then
        local states
        pcall(function() states = FindAllOf("GameStateBase") end)
        return states ~= nil and #states > 0
    end
    return false
end)

log("loaded: ReplaceClass=" .. tostring(replace) ..
    " DebugToggleFreecam=" .. tostring(debug_toggle) ..
    " DebugToggleDelayMs=" .. tostring(debug_delay_ms) ..
    " ForcePossessDebug=" .. tostring(force_possess_debug))
ExecuteWithDelay(3000, function() pcall(scan_target_functions) end)
