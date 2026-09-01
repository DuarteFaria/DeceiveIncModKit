-- DIScore: per-player ranked scoring from the game's own XP event system.
--
-- The in-game Mission Report is ADeceiveIncGameStateBase::
-- GetAllXpEventDisplayInfoForPlayer(DIPlayerState) rendered to a widget. Every
-- row on it ("6 ELIMINATIONS", "VAULT ENTERED", "FIRST PACKAGE CAPTURE") is one
-- DIXPEvent with a TriggerAmount. That is exactly the ranked point system, so
-- we do not need to detect gameplay ourselves - we read the counters the server
-- already maintains and multiply them by the MP table.
--
-- SETTLED BY THE 2026-09-01 LIVE RUN (LVL_FragrantShore, 1 human + 7 bots):
--
--   POLL works and is authoritative. ADIPlayerState.XpData.PlayerXpEventInfo
--   is a fully populated array of {EventType, MaxTrigger, TriggerAmount}, for
--   bots as well as humans, and CanGiveXpEvent() returns true on the dedicated
--   server. Crucially every MaxTrigger in the scored set matches the intended
--   cap exactly - Kill/VaultComputer/ReticalScanner are INT_MAX, and
--   EnterVault/FirstObjectivePickup/PickupObjective are 1 - so the clamping
--   worry does not exist and a plain read is the whole feature.
--
--   HOOK does not work and is not needed. RegisterHook on HandleXPEvent
--   reports registered=true but never fires, because UE4SS intercepts
--   ProcessEvent and this is a native C++ call that never goes through it.
--   Same for HandleVaultTerminalDeactivation. Both hooks are left in place:
--   they cost nothing, and they would start reporting if the game ever routed
--   these through the reflected path.
--
-- The consequence for the fallback plan is worth recording: if XP had been
-- gated off, the gameplay-event route would have hit this same wall, since
-- those are native calls too. It would need the Stage 3 native invoker rather
-- than Lua hooks.
--
-- Read-only. No property is written and no function with side effects is
-- called, so none of the crash modes in docs/05-findings.md apply.
--
-- Output: Win64/DIScore.log

local OUT = "DIScore.log"

-- Win64/DIScore.report on demand, mirroring the trigger-marker convention the
-- rest of the kit uses.
local TRIGGER = "DIScore.report"

-- ---------------------------------------------------------------- scoring

-- DIXPEvent -> match points. Values from the ranked spec; events absent from
-- this table (Intel, Extract, MatchPlayed, the multipliers, the Kill_N
-- milestones) score nothing and are logged but not counted.
local MP = {
    [2]  = { name = "Kill",                 mp = 2, cap = nil },  -- eliminations
    [18] = { name = "EnterVault",           mp = 1, cap = 1   },  -- enter phase 2 vault
    [19] = { name = "FirstObjectivePickup", mp = 4, cap = 1   },  -- briefcase grab
    [20] = { name = "PickupObjective",      mp = 1, cap = 1   },  -- case held
    [22] = { name = "VaultComputer",        mp = 2, cap = nil },  -- vault terminals
    [38] = { name = "ReticalScanner",       mp = 4, cap = nil },  -- retinal scanner (their typo)
}

local WIN_MP = 7

-- Every DIXPEvent, so unmapped fires are still legible in the log rather than
-- showing up as a bare integer.
local EVENT_NAMES = {
    [0]="None", [1]="Intel", [2]="Kill", [3]="Kill_10", [4]="Kill_20",
    [5]="Kill_50", [6]="Kill_100", [7]="Kill_200", [8]="Kill_300",
    [9]="Keycard_Green", [10]="Keycard_Blue", [11]="Keycard_Purple",
    [12]="Keycard_Gold", [13]="Powerup_Civilian", [14]="Powerup_Green",
    [15]="Powerup_Blue", [16]="Powerup_Purple", [17]="Powerup_Gold",
    [18]="EnterVault", [19]="FirstObjectivePickup", [20]="PickupObjective",
    [21]="Extract", [22]="VaultComputer", [23]="MatchPlayed",
    [24]="LastSpyStanding", [25]="TeammateRevive", [26]="SoloGameMode",
    [27]="XpBooster", [28]="DoubleXp", [29]="DoorUnlock", [30]="ChestUnlock",
    [31]="Lootable_XP", [32]="Lootable_Bond", [33]="Lootable_Credits",
    [34]="PrivateLobby", [35]="PrivateLobbySandbox", [36]="PremadeTeam",
    [37]="Catwalk", [38]="ReticalScanner", [39]="LimitedEvent1",
    [40]="LimitedEvent2", [41]="LimitedEvent3", [42]="LimitedEvent4",
    [43]="LimitedEvent5",
}

local function event_name(id)
    return EVENT_NAMES[id] or ("Unknown(" .. tostring(id) .. ")")
end

-- ---------------------------------------------------------------- logging

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

local function to_number(value)
    local n
    if pcall(function() n = tonumber(value) end) and n then return n end
    -- Enum-typed properties can surface as a userdata carrying the ordinal.
    if pcall(function() n = tonumber(value:GetIntValue()) end) and n then return n end
    return nil
end

local function to_string_prop(value)
    if value == nil then return nil end
    local s
    if pcall(function() s = value:ToString() end) and type(s) == "string" then return s end
    if type(value) == "string" then return value end
    return nil
end

-- ------------------------------------------------------- player identity
--
-- Bots in Deceive Inc. are full bot players with their own controllers and
-- PlayerStates, so a name check alone cannot tell them apart - and the bots use
-- real agent names ("Ace", "Larcin", "Madame Xiu"), so it is not even a weak
-- signal.
--
-- The prior plan was to treat APlayerController.NetConnection as decisive:
-- non-nil for a human, nil for a bot. Measured 2026-09-01 that is WRONG as
-- written, because UE4SS hands back a wrapper object for a null UObject pointer
-- rather than nil, so `connection ~= nil` was true for all 8 players and
-- mislabelled 7 bots as human. NetConnection must be IsValid()-checked, and
-- even then it is only corroboration here: bIsABot and ASpy.bIsBot both agreed
-- with ground truth on every player in that match, so they lead.

local function object_valid(object)
    if object == nil then return false end
    local valid
    if pcall(function() valid = object:IsValid() end) and valid ~= nil then
        return valid and true or false
    end
    return false
end

local function identify(player_state)
    local name = to_string_prop(player_state and player_state.PlayerDisplayName)
    if name == nil or name == "" then
        name = to_string_prop(player_state and player_state.PlayerNamePrivate)
    end
    if name == nil or name == "" then name = "<unnamed>" end

    local is_bot, evidence = nil, {}

    local engine_flag
    pcall(function() engine_flag = player_state.bIsABot end)
    if engine_flag ~= nil then
        evidence[#evidence + 1] = "bIsABot=" .. tostring(engine_flag)
        is_bot = engine_flag and true or false
    end

    local spy
    pcall(function() spy = unwrap(player_state.OwnedSpy) end)
    if object_valid(spy) then
        local spy_flag
        pcall(function() spy_flag = spy.bIsBot end)
        if spy_flag ~= nil then
            evidence[#evidence + 1] = "Spy.bIsBot=" .. tostring(spy_flag)
            if is_bot == nil then is_bot = spy_flag and true or false end
        end
    end

    -- Corroboration only. Recorded so a future disagreement is visible in the
    -- log, but never allowed to override the flags above.
    local controller
    pcall(function() controller = unwrap(player_state:GetOwner()) end)
    if object_valid(controller) then
        local connection
        pcall(function() connection = unwrap(controller.NetConnection) end)
        local has_connection = object_valid(connection)
        evidence[#evidence + 1] = "NetConnection=" .. tostring(has_connection)
        if is_bot == nil then
            is_bot = not has_connection
        elseif is_bot == has_connection then
            evidence[#evidence + 1] = "DISAGREE"
        end
    end

    if is_bot == nil then is_bot = false; evidence[#evidence + 1] = "undetermined" end
    return name, is_bot, table.concat(evidence, ",")
end

-- ------------------------------------------------------------ hook tally
--
-- Keyed by PlayerState full name rather than by the object, because UObject
-- wrappers must never be retained across callbacks (docs/05-findings.md).

local hook_tally = {}    -- [ps_full_name] = { name=, [event_id] = count }
local hook_fires = 0

local function record_fire(ps_full, display_name, event_id, amount)
    local row = hook_tally[ps_full]
    if row == nil then
        row = { name = display_name }
        hook_tally[ps_full] = row
    end
    row.name = display_name or row.name
    row[event_id] = (row[event_id] or 0) + 1
    row["amount_" .. event_id] = (row["amount_" .. event_id] or 0) + (amount or 0)
end

-- ------------------------------------------------------------ poll tally

-- Reads ADIPlayerState.XpData.PlayerXpEventInfo, the server's own per-player
-- counters. Returns a list of {event, trigger, max}.
local function read_xp_events(player_state)
    local rows = {}
    local xp_data
    if not pcall(function() xp_data = player_state.XpData end) or xp_data == nil then
        return rows, "XpData unreadable"
    end

    local list
    if not pcall(function() list = xp_data.PlayerXpEventInfo end) or list == nil then
        return rows, "PlayerXpEventInfo unreadable"
    end

    local count
    if not pcall(function() count = #list end) or count == nil then
        return rows, "PlayerXpEventInfo not indexable"
    end

    for i = 1, count do
        local entry
        pcall(function() entry = list[i] end)
        if entry ~= nil then
            local event_id, trigger, max_trigger
            pcall(function() event_id = to_number(entry.EventType) end)
            pcall(function() trigger = to_number(entry.TriggerAmount) end)
            pcall(function() max_trigger = to_number(entry.MaxTrigger) end)
            if event_id ~= nil then
                rows[#rows + 1] = {
                    event = event_id,
                    trigger = trigger or 0,
                    max = max_trigger or 0,
                }
            end
        end
    end
    return rows, nil
end

-- ---------------------------------------------------------------- report

local function score_from_counts(counts, won)
    local lines, total = {}, 0
    -- Stable order: by DIXPEvent ordinal.
    local ids = {}
    for id in pairs(MP) do ids[#ids + 1] = id end
    table.sort(ids)

    for _, id in ipairs(ids) do
        local rule = MP[id]
        local n = counts[id] or 0
        if n > 0 then
            local counted = n
            if rule.cap and counted > rule.cap then counted = rule.cap end
            local points = counted * rule.mp
            total = total + points
            local note = ""
            if counted ~= n then note = string.format("  (capped from %d)", n) end
            lines[#lines + 1] = string.format(
                "      %-22s x%-3d @%d = %3d MP%s", rule.name, counted, rule.mp, points, note)
        end
    end

    if won then
        total = total + WIN_MP
        lines[#lines + 1] = string.format("      %-22s x%-3d @%d = %3d MP", "MatchWin", 1, WIN_MP, WIN_MP)
    end

    return lines, total
end

local function game_state()
    local candidates = { "DeceiveIncMatchGameState", "DeceiveIncGameStateBase", "DeceiveIncSpyGameState" }
    for _, cn in ipairs(candidates) do
        local objs
        pcall(function() objs = FindAllOf(cn) end)
        if objs then
            for i = 1, #objs do
                local o = objs[i]
                local is_class = false
                pcall(function() is_class = o:IsAnyClass() end)
                if not is_class then return o, cn end
            end
        end
    end
    return nil, nil
end

local function report(reason)
    append("")
    append("################ DIScore report (" .. tostring(reason) .. ") ################")

    local gs, gs_class = game_state()
    append("game_state=" .. full(gs) .. " class=" .. tostring(gs_class))

    -- The XP gate. If this is false on a self-hosted server, HandleXPEvent very
    -- likely early-outs and both tallies will be empty - that is the single
    -- most important thing this recon run establishes.
    if gs ~= nil then
        local can_give, ok
        ok = pcall(function() can_give = gs:CanGiveXpEvent() end)
        append("CanGiveXpEvent() ok=" .. tostring(ok) .. " value=" .. tostring(can_give))

        local phase
        pcall(function() phase = to_number(gs.GamePhase) end)
        append("GamePhase=" .. tostring(phase))

        local result
        pcall(function() result = to_number(gs.MatchResult) end)
        append("MatchResult=" .. tostring(result))
    end

    append("hook fires observed so far: " .. tostring(hook_fires))

    local states
    pcall(function() states = FindAllOf("DIPlayerState") end)
    local n = states and #states or 0
    append("DIPlayerState instances: " .. tostring(n))

    for i = 1, n do
        local ps = states[i]
        local is_class = false
        pcall(function() is_class = ps:IsAnyClass() end)
        if not is_class then
            local ps_full = full(ps)
            local name, is_bot, evidence = identify(ps)
            local won
            pcall(function() won = ps.bWon end)

            append("")
            append(string.format("   [%s] %s", is_bot and "BOT  " or "HUMAN", name))
            append("      object   = " .. ps_full)
            append("      bWon     = " .. tostring(won) .. "   detection: " .. evidence)

            -- Source A: the server's own counters.
            local rows, err = read_xp_events(ps)
            local poll_counts = {}
            if err then
                append("      POLL     = <" .. err .. ">")
            elseif #rows == 0 then
                append("      POLL     = <empty: no XP events recorded>")
            else
                for _, r in ipairs(rows) do
                    poll_counts[r.event] = r.trigger
                    local scored = MP[r.event] and "" or "   (not scored)"
                    append(string.format("      POLL     %-22s trigger=%-3d max=%-3d%s",
                           event_name(r.event), r.trigger, r.max, scored))
                end
            end

            -- Source B: what we counted ourselves off the hook.
            local hook_row = hook_tally[ps_full]
            local hook_counts = {}
            if hook_row == nil then
                append("      HOOK     = <no fires seen for this player>")
            else
                local ids = {}
                for k in pairs(hook_row) do
                    if type(k) == "number" then ids[#ids + 1] = k end
                end
                table.sort(ids)
                for _, id in ipairs(ids) do
                    hook_counts[id] = hook_row[id]
                    append(string.format("      HOOK     %-22s fires=%-3d xp=%d",
                           event_name(id), hook_row[id], hook_row["amount_" .. id] or 0))
                end
            end

            -- Disagreement between the two is the finding, so state it plainly
            -- rather than leaving it to be eyeballed across two blocks.
            for id in pairs(MP) do
                local p, h = poll_counts[id] or 0, hook_counts[id] or 0
                if p ~= h then
                    append(string.format("      DIVERGE  %-22s poll=%d hook=%d",
                           event_name(id), p, h))
                end
            end

            -- The poll is authoritative. Measured 2026-09-01: every MaxTrigger
            -- in the scored set matches the intended cap exactly (Kill,
            -- VaultComputer and ReticalScanner are INT_MAX; EnterVault,
            -- FirstObjectivePickup and PickupObjective are 1), so there is no
            -- clamping to work around and nothing to gain from the hook.
            local lines, total = score_from_counts(poll_counts, won == true)
            append("      -- score (poll) --")
            if #lines == 0 then
                append("      (nothing scored)")
            else
                for _, l in ipairs(lines) do append(l) end
            end
            append(string.format("      TOTAL = %d MP", total))
        end
    end

    append("")
    append("################ END DIScore report ################")
    print("[DIScore] report written -> " .. OUT .. "\n")
end

-- ---------------------------------------------------------------- hooks

local function register(path, callback)
    local ok, pre, post = pcall(function() return RegisterHook(path, callback) end)
    append("hook " .. path .. " registered=" .. tostring(ok) ..
           " pre=" .. tostring(pre) .. " post=" .. tostring(post))
    return ok
end

-- The funnel. Every scoring event in the Mission Report passes through here.
register("/Script/DeceiveInc.DeceiveIncGameStateBase:HandleXPEvent",
    function(self, player_state_param, event_type_param, amount_param)
        local ok, err = pcall(function()
            local ps = unwrap(player_state_param)
            local event_id = to_number(unwrap(event_type_param))
            local amount = to_number(unwrap(amount_param)) or 0

            hook_fires = hook_fires + 1

            local ps_full = full(ps)
            local name, is_bot = "<nil playerstate>", false
            if ps ~= nil then name, is_bot = identify(ps) end

            if event_id ~= nil and ps ~= nil then
                record_fire(ps_full, name, event_id, amount)
            end

            append(string.format("XP  %-22s amount=%-5s %s %s  [%s]",
                   event_name(event_id), tostring(amount),
                   is_bot and "BOT  " or "HUMAN", name, ps_full))
        end)
        if not ok then append("XP hook error: " .. tostring(err)) end
    end)

-- Independent corroboration for the +2 terminal rule: this fires from the
-- gameplay side, not the XP side, so if XP is gated off server-side this hook
-- still proves terminal attribution is reachable.
register("/Script/DeceiveInc.DeceiveIncGameStateBase:HandleVaultTerminalDeactivation",
    function(self, player_state_param)
        local ok, err = pcall(function()
            local ps = unwrap(player_state_param)
            local name = "<nil>"
            if ps ~= nil then name = (identify(ps)) end
            append("TERMINAL deactivation by " .. name .. "  [" .. full(ps) .. "]")
        end)
        if not ok then append("terminal hook error: " .. tostring(err)) end
    end)

-- Clear per-match state so a second match in the same server process does not
-- inherit the first one's tally.
register("/Script/Engine.GameModeBase:StartPlay", function()
    hook_tally = {}
    hook_fires = 0
    append("")
    append("==== StartPlay: tally cleared ====")
end)

-- ------------------------------------------------------------- triggering
--
-- End-of-match auto-report. RegisterHook on MatchResultsPosted was tried first
-- and refused to register (returned a bare function instead of hook ids,
-- measured 2026-09-01) - it is a delegate signature, not a callable UFunction
-- on the class. Watching the replicated phase is both simpler and independent
-- of that distinction.

local RESULT_SCREEN = 7   -- ESpyGamePhase
local reported_phase = nil

LoopAsync(2000, function()
    -- Manual mid-match snapshot.
    local marker = io.open(TRIGGER, "r")
    if marker ~= nil then
        marker:close()
        os.remove(TRIGGER)
        pcall(report, "manual-trigger")
    end

    -- Auto-report once, when the match reaches the result screen.
    local ok = pcall(function()
        local gs = game_state()
        if gs == nil then return end
        local phase = to_number(gs.GamePhase)
        if phase == nil then return end
        if phase < RESULT_SCREEN then
            reported_phase = nil          -- re-arm for the next match
        elseif reported_phase == nil then
            reported_phase = phase
            pcall(report, "phase=" .. tostring(phase) .. " (result screen)")
        end
    end)
    if not ok then append("phase watcher error") end

    return false
end)

append("")
append("======== DIScore loaded ========")
print("[DIScore] loaded - hooking HandleXPEvent; auto-report at match end\n")
