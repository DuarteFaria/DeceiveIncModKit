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
--   HOOKS ARE GONE, and this is the important lesson. RegisterHook on
--   HandleXPEvent and HandleVaultTerminalDeactivation reported
--   registered=true but produced nothing across three live matches - the
--   earlier conclusion was that UE4SS intercepts ProcessEvent while these are
--   native C++ calls that never reach it.
--
--   That conclusion was only half right. On 2026-09-02, the first time a vault
--   terminal was ever actually hacked, one of the two DID fire and killed the
--   server: EXCEPTION_ACCESS_VIOLATION, status-3 exit, top five stack frames
--   all inside ue4ss.dll, 39ms after CompleteInteraction on
--   BP_VaultUnlockTerminal_C. The callbacks called identify(), which resolved
--   the agent via player_state:GetAgentId() - a game UFunction returning a
--   struct by value, invoked from inside a ProcessEvent hook. pcall cannot
--   catch a native access violation, so nothing was logged.
--
--   Both hooks were deleted rather than repaired: the poll below is the entire
--   feature and neither hook had ever contributed a number. The transferable
--   rule is that a hook callback may record cheap facts ONLY - no game
--   UFunction calls, no struct traversal, no identity resolution. All of that
--   belongs in the report path, which runs from LoopAsync outside any hook.
--
-- Read-only in the sense that matters for gameplay: no property is written and
-- no side-effecting function is called. That is NOT by itself enough to be
-- crash-safe, as the above shows - WHERE a read happens matters as much as
-- what it reads. See docs/05-findings.md.
--
-- Output: Win64/DIScore.log

local OUT = "DIScore.log"

-- Win64/DIScore.report on demand, mirroring the trigger-marker convention the
-- rest of the kit uses.
local TRIGGER = "DIScore.report"

-- Machine-readable twin of the log, consumed by the website pusher.
local JSON_OUT = "DIScore.report.json"

-- ---------------------------------------------------------------- scoring

-- DIXPEvent -> the scrims site's own score fields. `field` is the exact key the
-- API expects, so this table is the single place the two vocabularies meet.
--
-- `cap` follows the site's field TYPE, not the game's MaxTrigger: a "number"
-- field scores per occurrence, a "checkbox" scores once. Those agree with the
-- game everywhere except Ret Scanner, where the game allows repeats (MaxTrigger
-- = INT_MAX) but the site's checkbox does not - so we clamp to 1 and the log
-- shows "(capped from N)" if it ever happens.
--
-- Events absent from this table (Intel, Extract, MatchPlayed, DoorUnlock, the
-- multipliers, the Kill_N milestones) score nothing; they are still reported
-- under `events` so the site can display them.
local MP = {
    [2]  = { name = "Kill",                 field = "Elims",        mp = 2, cap = nil },  -- number
    [18] = { name = "EnterVault",           field = "Enter vault ", mp = 1, cap = 1   },  -- checkbox
    [19] = { name = "FirstObjectivePickup", field = "Podium",       mp = 4, cap = 1   },  -- checkbox
    [20] = { name = "PickupObjective",      field = "Package Hold", mp = 1, cap = 1   },  -- checkbox
    [22] = { name = "VaultComputer",        field = "Terms",        mp = 2, cap = nil },  -- number
    [38] = { name = "ReticalScanner",       field = "Ret Scanner",  mp = 4, cap = 1   },  -- checkbox
}

-- "Enter vault " carries a trailing space because the site's field list does.
-- Kept byte-exact deliberately: if that is a typo it must be fixed on their
-- side first, not silently diverged from here.

-- The win bonus is not one field. The site has three mutually exclusive win
-- checkboxes and EMatchResult says which applies, so a winner scores exactly
-- one of these rather than a flat +7.
local WIN_FIELDS = {
    [1] = { field = "Win",     mp = 7 },  -- MissionSucess_ObjectiveExtracted
    [2] = { field = "LMS",     mp = 5 },  -- MissionSucess_LastManStanding
    [4] = { field = "Timeout", mp = 7 },  -- MissionFailed_TimeOut  (ASSUMED)
}

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

-- ------------------------------------------------------------------ json
--
-- Hand-rolled because UE4SS ships no json library. Only what this payload
-- needs: string/number/boolean/nil, arrays (marked with __array so an empty one
-- does not serialise as {}), and string-keyed objects with sorted keys so
-- successive reports diff cleanly.

local json_encode

local JSON_ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function json_string(s)
    s = tostring(s):gsub('[%c"\\]', function(ch)
        return JSON_ESCAPES[ch] or string.format('\\u%04x', ch:byte())
    end)
    return '"' .. s .. '"'
end

json_encode = function(value)
    local t = type(value)
    if value == nil then return "null" end
    if t == "boolean" then return tostring(value) end
    if t == "number" then
        -- No inf/nan in JSON, and integers must not render as "3.0".
        if value ~= value or value == math.huge or value == -math.huge then return "null" end
        if value == math.floor(value) then return string.format("%d", value) end
        return tostring(value)
    end
    if t == "string" then return json_string(value) end
    if t ~= "table" then return json_string(tostring(value)) end

    if value.__array then
        local parts = {}
        for i = 1, #value do parts[#parts + 1] = json_encode(value[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for k in pairs(value) do
        if k ~= "__array" then keys[#keys + 1] = tostring(k) end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = json_string(k) .. ":" .. json_encode(value[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function array(t) t = t or {}; t.__array = true; return t end

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

-- The site accepts exactly these twelve agent names, in this spelling. Keys are
-- the folded form (lowercased, every non-alphanumeric ASCII byte dropped) so
-- that both spellings we can encounter resolve to the same entry:
--   * asset/class names       "Cavaliere"  -> "cavaliere"
--   * bot display names       "Cavaliere" with an accent -> "cavalire", because
--     folding drops the multi-byte UTF-8 sequence rather than transliterating it
-- Both keys are therefore listed. Same story for "Madame Xiu"/"MadameXiu" and
-- "Yu-Mi"/"YuMi".
local AGENT_CANON = {
    ace = "Ace",
    cavaliere = "Cavalière", cavalire = "Cavalière",
    chavez = "Chavez",
    hans = "Hans",
    larcin = "Larcin",
    madamexiu = "Madame Xiu", xiu = "Madame Xiu",
    octo = "Octo",
    red = "Red", socialite = "Red",
    sasori = "Sasori",
    squire = "Squire", squireseason4 = "Squire",
    vigil = "Vigil",
    yumi = "Yu-Mi",
}

-- The internal codename is NOT the display name, and two of them differ enough
-- that the site name cannot be guessed from the asset. Confirmed 2026-09-02
-- from DIScore.catalogue.txt (13 DA_AgentData_* assets) and from the log, which
-- had been recording the failures all along:
--
--   agent = nil  raw=Socialite     -> Red
--   agent = nil  raw=Xiu           -> Madame Xiu
--
-- Both pushed with no agent field for six matches before this was caught.
-- SquireSeason4 is an alternate Squire asset and folds onto the same agent.
-- AgentBalancingName was no help: it read back nil for all 13, same as every
-- other FText on a dedicated server.

local function fold_agent(name)
    if name == nil then return nil end
    return (tostring(name):lower():gsub("[^a-z0-9]", ""))
end

-- Maps whatever the game gave us onto the site's spelling. Returns nil when it
-- does not match a known agent, so an unrecognised value is reported as such
-- rather than silently pushed to the API.
local function canon_agent(name)
    local folded = fold_agent(name)
    if folded == nil or folded == "" then return nil end
    return AGENT_CANON[folded]
end

-- The scrims API wants the AGENT the player used, which is not the player's
-- name. For bots the two coincide (a bot is named after its agent - "Hans",
-- "Cavaliere"), but for a human PlayerDisplayName is the account name and the
-- agent lives in AgentSelection. Three routes are tried and all three are
-- logged, so the first live match tells us which actually resolves rather than
-- us guessing at a struct traversal that UE4SS may not support.
-- Routes are ordered least to most dangerous, and the first hit wins.
--
-- `player_state:GetAgentId()` USED to be one of them and has been removed: it
-- is a game UFunction returning FPrimaryAssetId by value, and invoking that is
-- the prime suspect for the 2026-09-02 status-3 crash (see the header). Nothing
-- here calls a game UFunction any more - only class-name reflection and plain
-- property reads.
local function agent_of(player_state)
    local found, how = nil, {}

    -- Route 1: the spy pawn's class name - "BPSpy_Ace_Turquoise_V1_C" -> "Ace".
    -- Pure reflection over an FName, the cheapest and best-proven read in the
    -- kit, and it touches no struct at all.
    pcall(function()
        local spy = unwrap(player_state.OwnedSpy)
        if not object_valid(spy) then return end
        local cls
        pcall(function() cls = spy:GetClass():GetFName():ToString() end)
        if cls == nil then return end
        local n = cls:match("^BPSpy_([A-Za-z0-9]+)_")
        how[#how + 1] = "SpyClass=" .. tostring(cls) .. "->" .. tostring(n)
        if n ~= nil and n ~= "" then found = found or n end
    end)

    -- Route 2: the replicated selection struct. A nested read
    -- (AgentSelection.AgentId.PrimaryAssetName), so it is tried only if the
    -- class name did not answer.
    if found == nil then
        pcall(function()
            local sel = player_state.AgentSelection
            if sel == nil then return end
            local id = sel.AgentId
            if id == nil then return end
            local n = to_string_prop(id.PrimaryAssetName)
            how[#how + 1] = "AgentSelection=" .. tostring(n)
            if n ~= nil and n ~= "" and n ~= "None" then found = found or n end
        end)
    end

    -- Data-asset names carry a prefix ("DA_Agent_Cavaliere"); the API wants the
    -- bare agent, so strip anything up to the last underscore-delimited prefix
    -- we recognise. Left as-is when it does not match a known shape.
    local cleaned = found
    if cleaned ~= nil then
        cleaned = cleaned:gsub("^DA_Agent_", ""):gsub("^Agent_", ""):gsub("^DA_", "")
    end

    -- The player's own display name is a last resort that happens to be right
    -- for bots, which are named after their agent.
    if cleaned == nil then
        local n = to_string_prop(player_state.PlayerDisplayName)
        if n ~= nil and canon_agent(n) ~= nil then
            cleaned = n
            how[#how + 1] = "DisplayName=" .. tostring(n)
        end
    end

    local canon = canon_agent(cleaned)
    if cleaned ~= nil and canon == nil then
        how[#how + 1] = "UNRECOGNISED=" .. tostring(cleaned)
    end
    return canon, cleaned, table.concat(how, " ")
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

    -- Keys a website can actually use. PlayerDisplayName cannot be one: it is
    -- not unique (one lobby held three "Hans" and another two "Ace"), not
    -- stable across matches, and ADIPlayerState.HidePlayerName lets a player
    -- anonymise it. BanditIDCRC is the candidate primary key - an int32, so
    -- free to read - with UniqueId as the fallback if it turns out to be 0 or
    -- unstable. PlayerID is per-match only and is recorded for debugging, never
    -- as a key.
    local ident = {}
    ident.agent, ident.agent_raw, ident.agent_routes = agent_of(player_state)
    pcall(function() ident.bandit_id_crc = to_number(player_state.BanditIDCRC) end)
    pcall(function() ident.platform_type = to_number(player_state.PlatformType) end)
    pcall(function() ident.player_id = to_number(player_state.PlayerID) end)
    pcall(function() ident.hide_player_name = to_number(player_state.HidePlayerName) end)
    pcall(function()
        local uid = player_state.UniqueId
        local s = to_string_prop(uid)
        if s == nil and uid ~= nil then pcall(function() s = uid:ToString() end) end
        if s ~= nil and s ~= "" then ident.unique_id = s end
    end)

    return name, is_bot, table.concat(evidence, ","), ident
end

-- ------------------------------------------------------------ hook tally
--
-- Keyed by PlayerState full name rather than by the object, because UObject
-- wrappers must never be retained across callbacks (docs/05-findings.md).

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

-- Returns the log lines, the MP total, the breakdown rows, and `score`: the
-- field->points object the API's playerScores entry takes verbatim.
local function score_from_counts(counts, won, match_result)
    local lines, total, breakdown, score = {}, 0, array(), {}
    -- Stable order: by DIXPEvent ordinal.
    local ids = {}
    for id in pairs(MP) do ids[#ids + 1] = id end
    table.sort(ids)

    local function add(field, event, event_id, raw, counted, mp_each)
        local points = counted * mp_each
        total = total + points
        score[field] = (score[field] or 0) + points
        breakdown[#breakdown + 1] = {
            event = event, field = field, event_id = event_id,
            raw_count = raw, counted = counted, mp_each = mp_each, mp = points,
        }
        local note = ""
        if counted ~= raw then note = string.format("  (capped from %d)", raw) end
        lines[#lines + 1] = string.format("      %-14s %-22s x%-3d @%d = %3d MP%s",
                                          field, event, counted, mp_each, points, note)
    end

    for _, id in ipairs(ids) do
        local rule = MP[id]
        local n = counts[id] or 0
        if n > 0 then
            local counted = n
            if rule.cap and counted > rule.cap then counted = rule.cap end
            add(rule.field, rule.name, id, n, counted, rule.mp)
        end
    end

    -- Exactly one win field, chosen by how the match ended. A winner under an
    -- EMatchResult we have no field for is reported rather than scored, so a
    -- silent zero can never be mistaken for "did not win".
    if won then
        local w = WIN_FIELDS[match_result or -1]
        if w ~= nil then
            add(w.field, "MatchWin(result=" .. tostring(match_result) .. ")", -1, 1, 1, w.mp)
        else
            lines[#lines + 1] = string.format(
                "      %-14s won=true but no win field for MatchResult=%s - NOT SCORED",
                "(none)", tostring(match_result))
        end
    end

    return lines, total, breakdown, score
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

-- ------------------------------------------------------- payload helpers

local RESULT_SCREEN = 7   -- ESpyGamePhase

local MATCH_RESULTS = {
    [0] = "Invalid",
    [1] = "MissionSucess_ObjectiveExtracted",
    [2] = "MissionSucess_LastManStanding",
    [3] = "MissionFailed_NoAgentsLeft",
    [4] = "MissionFailed_TimeOut",
}

-- Identifies one match so the receiving site can dedupe retries. Minted at
-- StartPlay rather than at report time, because a mid-match snapshot and the
-- final report must carry the SAME id for the final one to supersede it.
local current_match_id = nil
local match_seq = 0

local function new_match_id()
    match_seq = match_seq + 1
    current_match_id = string.format("%s-%d-%d", os.date("!%Y%m%dT%H%M%SZ"),
                                     match_seq, os.time())
    return current_match_id
end

local function match_id()
    if current_match_id == nil then return new_match_id() end
    return current_match_id
end

local function current_map(gs)
    if gs == nil then return nil end
    -- ".../LVL_Silverreef/LVL_Silverreef.LVL_Silverreef:PersistentLevel..."
    return (full(gs)):match("/([^/.:]+)%.[^/.:]+:PersistentLevel") or nil
end

-- The level name alone cannot identify a map to the site: it lists Day and
-- Night variants of Hard Sell and Fragrant Shore, and both variants plausibly
-- share one LVL_ name. UMapData carries the authoritative display name, so ask
-- the game instead of maintaining a translation table.
local function map_identity(gs)
    local out = {}
    if gs == nil then return out end
    pcall(function()
        local md = gs:GetCurrentMapData()
        if not object_valid(md) then return end
        out.map_display_name = to_string_prop(md.MapDisplayName)
        out.map_code = to_string_prop(md.mapCode)
        out.map_file_name = to_string_prop(md.MapFileName)
        out.map_data_object = full(md)
        -- The asset name minus its prefix is the MapRotation "short name"
        -- (DA_MapData_Tutorial -> Tutorial, per the PickMap log line). This is
        -- the best map key available: it is the same vocabulary the server's
        -- own rotation uses, and unlike mapCode it separates the Day and Night
        -- variants - Hardsell/Hardsell_Day and FragrantShore/FragrantShore_Night.
        local asset
        pcall(function() asset = md:GetFName():ToString() end)
        if asset ~= nil then
            out.map_asset = asset
            out.map_short_name = asset:gsub("^DA_MapData_", "")
        end
    end)
    return out
end

-- Echoed into the payload so a stored match record stays interpretable even if
-- the MP values are retuned later.
local function mp_table_json()
    local t = {}
    for id, rule in pairs(MP) do
        t[rule.field] = { event = rule.name, event_id = id,
                          mp = rule.mp, cap = rule.cap or false }
    end
    for result, w in pairs(WIN_FIELDS) do
        t[w.field] = { event = "MatchWin", match_result = result, mp = w.mp, cap = 1 }
    end
    return t
end

-- ------------------------------------------------------- catalogue recon
--
-- One-shot dump of the two catalogues the scrims push needs to translate the
-- game's vocabulary into the site's. Written once per server run.
--
-- Why this exists rather than a hardcoded table: the live 2026-09-02 run showed
-- bot "Red" playing spy class BPSpy_Socialite_..., i.e. the internal agent
-- codename is NOT the display name, so guessing the mapping is unsafe. Same
-- story for maps - the site distinguishes Day/Night variants and only the
-- game knows which mapCode belongs to which.
--
-- FText is deliberately not relied on. MapDisplayName read back nil on the
-- dedicated server (localisation data is almost certainly not loaded there), so
-- the FString fields - mapCode, MapFileName, AgentBalancingName - plus each
-- asset's own object name are the usable keys. FText is still attempted and
-- logged, in case it turns out to work for some assets.

local CATALOGUE_OUT = "DIScore.catalogue.txt"

local function catalogue()
    local function w(line)
        local fh = io.open(CATALOGUE_OUT, "a")
        if fh then fh:write(tostring(line) .. "\n"); fh:close() end
    end

    w("")
    w("======== DIScore catalogue " .. os.date("!%Y-%m-%dT%H:%M:%SZ") .. " ========")

    for _, class_name in ipairs({ "AgentData", "MapData" }) do
        local objs
        pcall(function() objs = FindAllOf(class_name) end)
        local n = objs and #objs or 0
        w("")
        w("---- " .. class_name .. " (" .. tostring(n) .. ")")
        for i = 1, n do
            local o = objs[i]
            local is_class = false
            pcall(function() is_class = o:IsAnyClass() end)
            if not is_class then
                local parts = {}
                local function field(label, getter)
                    local v
                    if pcall(function() v = getter() end) and v ~= nil and v ~= "" then
                        parts[#parts + 1] = label .. "=" .. tostring(v)
                    else
                        parts[#parts + 1] = label .. "=nil"
                    end
                end
                field("object", function() return o:GetFName():ToString() end)
                if class_name == "AgentData" then
                    field("balancing", function() return to_string_prop(o.AgentBalancingName) end)
                    field("name_ftext", function() return to_string_prop(o.AgentName) end)
                    field("released", function() return o.bIsAgentReleased end)
                    field("canBot", function() return o.bCanSpawnAsBot end)
                else
                    field("code", function() return to_string_prop(o.mapCode) end)
                    field("file", function() return to_string_prop(o.MapFileName) end)
                    field("display_ftext", function() return to_string_prop(o.MapDisplayName) end)
                end
                w("   " .. table.concat(parts, "  "))
            end
        end
    end

    w("======== END catalogue ========")
    print("[DIScore] catalogue written -> " .. CATALOGUE_OUT .. "\n")
end

local function report(reason)
    append("")
    append("################ DIScore report (" .. tostring(reason) .. ") ################")

    local payload = {
        schema = 1,
        match_id = match_id(),
        reason = tostring(reason),
        reported_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        mp_table = mp_table_json(),
        players = array(),
    }

    local gs, gs_class = game_state()
    append("game_state=" .. full(gs) .. " class=" .. tostring(gs_class))
    payload.map = current_map(gs)
    local mid = map_identity(gs)
    payload.map_display_name = mid.map_display_name
    payload.map_code = mid.map_code
    payload.map_file_name = mid.map_file_name
    payload.map_short_name = mid.map_short_name
    payload.map_asset = mid.map_asset
    append("map short=" .. tostring(mid.map_short_name) ..
           " level=" .. tostring(payload.map) ..
           " display=" .. tostring(mid.map_display_name) ..
           " code=" .. tostring(mid.map_code) ..
           " file=" .. tostring(mid.map_file_name) ..
           " data=" .. tostring(mid.map_data_object))

    -- The XP gate. If this is false on a self-hosted server, HandleXPEvent very
    -- likely early-outs and both tallies will be empty - that is the single
    -- most important thing this recon run establishes.
    if gs ~= nil then
        local can_give, ok
        ok = pcall(function() can_give = gs:CanGiveXpEvent() end)
        append("CanGiveXpEvent() ok=" .. tostring(ok) .. " value=" .. tostring(can_give))
        if ok then payload.can_give_xp = can_give and true or false end

        local phase
        pcall(function() phase = to_number(gs.GamePhase) end)
        append("GamePhase=" .. tostring(phase))
        payload.phase = phase
        payload.is_final = (phase ~= nil and phase >= RESULT_SCREEN) or false

        local result
        pcall(function() result = to_number(gs.MatchResult) end)
        append("MatchResult=" .. tostring(result))
        payload.match_result = result
        payload.match_result_name = MATCH_RESULTS[result or -1]
    end

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
            local name, is_bot, evidence, ident = identify(ps)
            local won
            pcall(function() won = ps.bWon end)

            append("")
            append(string.format("   [%s] %s", is_bot and "BOT  " or "HUMAN", name))
            append("      object   = " .. ps_full)
            append("      bWon     = " .. tostring(won) .. "   detection: " .. evidence)
            append("      identity = bandit_id_crc=" .. tostring(ident.bandit_id_crc) ..
                   " unique_id=" .. tostring(ident.unique_id) ..
                   " platform=" .. tostring(ident.platform_type) ..
                   " hide_name=" .. tostring(ident.hide_player_name))
            append("      agent    = " .. tostring(ident.agent) ..
                   "  raw=" .. tostring(ident.agent_raw) ..
                   "   routes: " .. tostring(ident.agent_routes))

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

            -- The poll is authoritative. Measured 2026-09-01: every MaxTrigger
            -- in the scored set matches the intended cap exactly (Kill,
            -- VaultComputer and ReticalScanner are INT_MAX; EnterVault,
            -- FirstObjectivePickup and PickupObjective are 1), so there is no
            -- clamping to work around and nothing to gain from the hook.
            local lines, total, breakdown, score =
                score_from_counts(poll_counts, won == true, payload.match_result)
            append("      -- score (poll) --")
            if #lines == 0 then
                append("      (nothing scored)")
            else
                for _, l in ipairs(lines) do append(l) end
            end
            append(string.format("      TOTAL = %d MP", total))

            local events = {}
            for id, count in pairs(poll_counts) do
                if count > 0 then events[event_name(id)] = count end
            end

            payload.players[#payload.players + 1] = {
                name = name,
                agent = ident.agent,
                agent_raw = ident.agent_raw,
                agent_routes = ident.agent_routes,
                is_bot = is_bot,
                bandit_id_crc = ident.bandit_id_crc,
                unique_id = ident.unique_id,
                platform_type = ident.platform_type,
                hide_player_name = ident.hide_player_name,
                player_id = ident.player_id,
                won = won == true,
                events = events,
                breakdown = breakdown,
                score = score,
                mp = total,
            }
        end
    end

    -- Machine-readable sidecar for the website pusher. Written last and only
    -- once the whole payload is assembled, so a reader never sees a half file.
    -- Overwritten each report: a mid-match snapshot is provisional and the
    -- final one (is_final=true) supersedes it under the same match_id.
    local json_ok, json_err = pcall(function()
        local fh = io.open(JSON_OUT, "w")
        if fh == nil then error("cannot open " .. JSON_OUT) end
        fh:write(json_encode(payload))
        fh:close()
    end)
    append("json sidecar ok=" .. tostring(json_ok) ..
           " players=" .. tostring(#payload.players) ..
           " match_id=" .. tostring(payload.match_id) ..
           " final=" .. tostring(payload.is_final) ..
           (json_ok and "" or (" error=" .. tostring(json_err))))

    append("")
    append("################ END DIScore report ################")
    print("[DIScore] report written -> " .. OUT .. " (+ " .. JSON_OUT .. ")\n")
end

-- ---------------------------------------------------------------- hooks

local function register(path, callback)
    local ok, pre, post = pcall(function() return RegisterHook(path, callback) end)
    append("hook " .. path .. " registered=" .. tostring(ok) ..
           " pre=" .. tostring(pre) .. " post=" .. tostring(post))
    return ok
end

-- REMOVED 2026-09-02: the HandleXPEvent and HandleVaultTerminalDeactivation
-- hooks were registered here. One of them fired for the first time when a vault
-- terminal was finally hacked and took the server down with an
-- EXCEPTION_ACCESS_VIOLATION whose top frames were all ue4ss.dll. They are
-- deleted rather than made safe: the poll is the whole feature, and in three
-- live matches neither hook ever contributed a single number.
--
-- The rule learned, if a hook is ever needed again: a callback may record cheap
-- facts ONLY. No game UFunction calls, no struct traversal, no identity
-- resolution. Defer all of that to the report path, which runs from LoopAsync
-- outside any game hook.

-- Mints the first match id of the process. Deliberately the ONLY hook left,
-- and its callback touches no UObject at all - it assigns two locals and
-- appends a line.
--
-- NOT sufficient on its own, which cost a scrim map on 2026-09-02. This hook
-- was added precisely to stop a second match in one process reusing the first
-- match's id, and it does not fire again after a ProcessServerTravel:
-- match_seq stayed at 1 across two matches, both reports carried
-- match_id=20260902T171326Z-1-1788369206, and the pusher skipped the second as
-- "already pushed". The phase watcher above now mints on the result-screen ->
-- in-play transition, which does happen every match; this hook only covers the
-- very first one.
--
-- It stayed hidden until the map rotation started working. Before that every
-- map needed a server restart, so every match got a fresh process and a fresh
-- id by accident.
register("/Script/Engine.GameModeBase:StartPlay", function()
    local id = new_match_id()
    append("")
    append("==== StartPlay: tally cleared, match_id=" .. tostring(id) .. " ====")
end)

-- ------------------------------------------------------------- triggering
--
-- End-of-match auto-report. RegisterHook on MatchResultsPosted was tried first
-- and refused to register (returned a bare function instead of hook ids,
-- measured 2026-09-01) - it is a delegate signature, not a callable UFunction
-- on the class. Watching the replicated phase is both simpler and independent
-- of that distinction.

local reported_phase = nil
local catalogue_done = false

LoopAsync(2000, function()
    -- Manual mid-match snapshot.
    local marker = io.open(TRIGGER, "r")
    if marker ~= nil then
        marker:close()
        os.remove(TRIGGER)
        pcall(report, "manual-trigger")
    end

    -- One-shot catalogue dump. Runs from this poll rather than at load time so
    -- the data assets are certain to exist, and outside any hook.
    if not catalogue_done then
        catalogue_done = true
        local ok, err = pcall(catalogue)
        if not ok then append("catalogue error: " .. tostring(err)) end
    end

    -- Auto-report once, when the match reaches the result screen.
    local ok = pcall(function()
        local gs = game_state()
        if gs == nil then return end
        local phase = to_number(gs.GamePhase)
        if phase == nil then return end
        if phase < RESULT_SCREEN then
            if reported_phase ~= nil then
                -- We were on the result screen and the phase has moved on, so
                -- a NEW match is starting inside this same server process.
                -- Minting here rather than only at StartPlay is what keeps two
                -- matches in one process from sharing a match_id.
                --
                -- Deliberately on the TRANSITION, not on every tick where
                -- phase < 7: the id has to stay stable for the whole match, or
                -- a mid-match snapshot would carry a different id each poll
                -- and the pusher would treat each one as a new match.
                local id = new_match_id()
                append("")
                append("==== new match in this process (phase " ..
                       tostring(reported_phase) .. " -> " .. tostring(phase) ..
                       "), match_id=" .. tostring(id) .. " ====")
            end
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
print("[DIScore] loaded - polling XpData; auto-report at match end\n")
