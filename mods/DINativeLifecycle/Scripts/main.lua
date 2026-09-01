-- DINativeLifecycle: Stage 1 read-only lifecycle observer.
-- No function calls alter gameplay, possession, factions, match state, or exit.
local OUT = "DINativeLifecycle.log"
local TRIGGER = "DINativeSpectator.stage1-trigger"

local function append(line)
    local fh = io.open(OUT, "a")
    if fh then
        fh:write(os.date("!%Y-%m-%dT%H:%M:%SZ") .. " " .. tostring(line) .. "\n")
        fh:close()
    end
end

local function unwrap(value)
    if value == nil then return nil end
    local result = value
    pcall(function() result = value:get() end)
    return result
end

local function full(value)
    local object = unwrap(value)
    if object == nil then return "<nil>" end
    local rendered
    if pcall(function() rendered = object:GetFullName() end) and rendered then return rendered end
    if pcall(function() rendered = object:ToString() end) and rendered then return rendered end
    return "<unrenderable>"
end

local function property(object, name)
    local value = "<unavailable>"
    pcall(function()
        local raw = object[name]
        if type(raw) == "boolean" or type(raw) == "number" or type(raw) == "string" then
            value = tostring(raw)
        else
            value = full(raw)
        end
    end)
    return value
end

local function count(class_name)
    local objects
    pcall(function() objects = FindAllOf(class_name) end)
    return objects and #objects or 0
end

local function controller_line(controller)
    local pc = unwrap(controller)
    if pc == nil then return "controller=<nil>" end
    return "controller=" .. full(pc) ..
        " pawn=" .. property(pc, "Pawn") ..
        " spectator_pawn=" .. property(pc, "SpectatorPawn") ..
        " acknowledged_pawn=" .. property(pc, "AcknowledgedPawn") ..
        " player_waiting=" .. property(pc, "bPlayerIsWaiting") ..
        " auto_spectating=" .. property(pc, "bIsAutoSpectating") ..
        " player_state=" .. property(pc, "PlayerState")
end

local function player_state_line(state)
    local ps = unwrap(state)
    if ps == nil then return "player_state=<nil>" end
    return "player_state=" .. full(ps) ..
        " owner=" .. property(ps, "Owner") ..
        " pawn=" .. property(ps, "PawnPrivate") ..
        " faction=" .. property(ps, "Faction") ..
        " faction_id=" .. property(ps, "FactionId") ..
        " team=" .. property(ps, "TeamId") ..
        " spectator=" .. property(ps, "bIsSpectator") ..
        " only_spectator=" .. property(ps, "bOnlySpectator")
end

local last_snapshot = ""
local function snapshot(reason)
    local match_state = "<none>"
    local players = -1
    local states
    pcall(function() states = FindAllOf("GameStateBase") end)
    if states and #states > 0 then
        pcall(function() match_state = states[1].MatchState:ToString() end)
        pcall(function() players = #states[1].PlayerArray end)
    end
    local line = "snapshot reason=" .. tostring(reason) ..
        " match_state=" .. tostring(match_state) ..
        " player_array=" .. tostring(players) ..
        " controllers=" .. count("DeceiveIncPlayerController") ..
        " player_states=" .. count("DIPlayerState") ..
        " spies=" .. count("Spy") ..
        " debug_freecams=" .. count("DebugFreecam") ..
        " free_spectators=" .. count("DIFreeSpectator")
    local changed = reason ~= "periodic" or line ~= last_snapshot
    if changed then
        append(line)
        local controllers
        pcall(function() controllers = FindAllOf("DeceiveIncPlayerController") end)
        if controllers then
            for i = 1, #controllers do append("  " .. controller_line(controllers[i])) end
        end
        local player_states
        pcall(function() player_states = FindAllOf("DIPlayerState") end)
        if player_states then
            for i = 1, #player_states do append("  " .. player_state_line(player_states[i])) end
        end
    end
    last_snapshot = line:gsub("reason=[^ ]+", "reason=periodic")
end

local function after(reason)
    ExecuteWithDelay(1, function() snapshot(reason .. "-after") end)
end

local function register(path, callback)
    local ok, result = pcall(function() return RegisterHook(path, callback) end)
    append("hook " .. path .. " registered=" .. tostring(ok) .. " result=" .. tostring(result))
end

local event_sequence = 0
local function event(name, controller, detail)
    event_sequence = event_sequence + 1
    local sequence = event_sequence
    append(string.format("trace[%04d] %s %s %s", sequence, name,
           controller_line(controller), tostring(detail or "")))
end

register("/Script/Engine.Controller:Possess", function(self, pawn)
    append("Possess " .. controller_line(self) .. " new_pawn=" .. full(pawn))
    snapshot("Possess-before")
    after("Possess")
end)

register("/Script/Engine.Controller:UnPossess", function(self)
    append("UnPossess " .. controller_line(self))
    snapshot("UnPossess-before")
    after("UnPossess")
end)

register("/Script/Engine.GameModeBase:StartPlay", function(self)
    append("StartPlay game_mode=" .. full(self))
    snapshot("StartPlay")
end)

-- Route 19 observer hooks. These callbacks only record calls made by the game
-- or Route 18; they never invoke a spectator, camera, UI, state, or pawn API.
register("/Script/DeceiveInc.DeceiveIncPlayerController:RPC_SpectateActor",
function(self, actor, player_state)
    event("RPC_SpectateActor", self, "actor=" .. full(actor) ..
          " target_player_state=" .. full(player_state))
end)

register("/Script/DeceiveInc.DeceiveIncPlayerController:Server_AskForNextSpectatedActor",
function(self, next_value)
    event("Server_AskForNextSpectatedActor", self,
          "bNext=" .. property({value = unwrap(next_value)}, "value"))
end)

register("/Script/DeceiveInc.DeceiveIncPlayerController:Server_ToggleAutoSpectate",
function(self)
    event("Server_ToggleAutoSpectate", self)
end)

register("/Script/DeceiveInc.DeceiveIncPlayerController:Server_DEBUGToggleFreecam",
function(self)
    event("Server_DEBUGToggleFreecam", self)
end)

register("/Script/Engine.PlayerController:ClientRestart", function(self, pawn)
    event("ClientRestart", self, "new_pawn=" .. full(pawn))
end)

register("/Script/Engine.PlayerController:ClientSetSpectatorWaiting",
function(self, waiting)
    event("ClientSetSpectatorWaiting", self,
          "waiting=" .. property({value = unwrap(waiting)}, "value"))
end)

register("/Script/Engine.PlayerController:ClientSetViewTarget",
function(self, target)
    event("ClientSetViewTarget", self, "target=" .. full(target))
end)

register("/Script/Engine.PlayerController:ClientGotoState", function(self, state)
    event("ClientGotoState", self,
          "state=" .. property({value = unwrap(state)}, "value"))
end)

register("/Script/Engine.PlayerController:SetViewTargetWithBlend",
function(self, target)
    event("SetViewTargetWithBlend", self, "target=" .. full(target))
end)

register("/Script/DeceiveInc.DeceiveIncPlayerController:OnRep_IsAutoSpectating",
function(self)
    event("OnRep_IsAutoSpectating", self)
end)

local function consume_trigger()
    local fh = io.open(TRIGGER, "r")
    if not fh then return end
    local command = fh:read("*a") or ""
    fh:close()
    os.remove(TRIGGER) -- consume before the RPC; a crash cannot repeat it
    if not command:find("TRIGGER", 1, true) then
        append("ignored invalid Stage 1 trigger marker")
        return
    end

    local controllers
    pcall(function() controllers = FindAllOf("DeceiveIncPlayerController") end)
    if not controllers or #controllers ~= 1 then
        append("trigger refused: expected exactly one human controller, found=" ..
               tostring(controllers and #controllers or 0))
        return
    end
    local controller = controllers[1]
    append("consuming explicit Stage 1 trigger " .. controller_line(controller))
    snapshot("trigger-before")
    local ok, err = pcall(function() controller:Server_DEBUGToggleFreecam() end)
    append("Server_DEBUGToggleFreecam returned ok=" .. tostring(ok) ..
           " result=" .. tostring(err))
    after("trigger")
end

LoopAsync(1000, function()
    snapshot("periodic")
    pcall(consume_trigger)
    return false
end)

append("DINativeLifecycle Stage 1 observer loaded; read-only mode")
snapshot("loaded")
