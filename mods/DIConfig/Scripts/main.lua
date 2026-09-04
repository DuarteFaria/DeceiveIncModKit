-- DIConfig: apply server-side gameplay overrides that TripwireServer.ini
-- does not expose. Reads DIConfig.ini from the Win64 folder.
--
-- [Timing]
-- LobbyWaitTime   = 30    ; pregame lobby countdown, seconds (default 90)
-- IntroPhaseTime  = 10    ; spy intro/posing phase, seconds (default 19)
--
-- [Gameplay]
-- DisableSuspicion = 0    ; applies to every game mode
-- DisableCover     = 0    ; keeps agents permanently out of cover

local INI = "DIConfig.ini"
local cfg = {}

local function log(s) print("[DIConfig] " .. tostring(s) .. "\n") end

local function load_ini()
    local fh = io.open(INI, "r")
    if not fh then
        log("no " .. INI .. " found - writing a default one")
        local out = io.open(INI, "w")
        if out then
            out:write("[Timing]\n")
            out:write("; pregame lobby countdown in seconds (packaged default: 90)\n")
            out:write("LobbyWaitTime = 30\n")
            out:write("; spy intro / posing phase in seconds (packaged default: 19)\n")
            out:write("IntroPhaseTime = 19\n")
            out:write("\n[Gameplay]\n")
            out:write("DisableSuspicion = 0\n")
            out:write("DisableCover = 0\n")
            out:close()
        end
        fh = io.open(INI, "r")
        if not fh then return end
    end
    for line in fh:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*([^;]+)")
        if k and v then
            v = v:gsub("%s+$", "")
            cfg[k] = tonumber(v) or v
        end
    end
    fh:close()
end

local function enabled(value)
    if type(value) == "number" then return value ~= 0 end
    local text = tostring(value or ""):lower()
    return text == "1" or text == "true" or text == "yes" or text == "on"
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

local function full(object)
    if object == nil then return "<nil>" end
    local rendered
    if pcall(function() rendered = object:GetFullName() end) and rendered then
        return tostring(rendered)
    end
    return "<unrenderable>"
end

local function live_spies()
    local found, result = nil, {}
    pcall(function() found = FindAllOf("Spy") end)
    if not found then return result end
    for i = 1, #found do
        local object = found[i]
        local name = full(object)
        if name ~= "<nil>" and name ~= "<unrenderable>" and
           not name:find("Default__", 1, true) and
           not name:find(".PersistentLevel.None", 1, true) then
            result[#result + 1] = object
        end
    end
    return result
end

local function active_match()
    local phase_names = {
        VAULT_LOCKED = 3, VAULT_UNLOCKED = 4, EXTRACTION_CALLED = 5,
        EXTRACTION_ARRIVED = 6,
    }
    local states
    pcall(function() states = FindAllOf("DeceiveIncMatchGameState") end)
    if not states then return false end
    for i = 1, #states do
        local state = states[i]
        if not full(state):find("Default__", 1, true) then
            local phase, raw
            pcall(function() raw = unwrap(state.GamePhase) end)
            if type(raw) == "number" then
                phase = raw
            else
                pcall(function() phase = tonumber(raw) end)
                if phase == nil then
                    local rendered
                    pcall(function() rendered = tostring(raw:ToString()) end)
                    if rendered == nil then
                        pcall(function() rendered = tostring(raw) end)
                    end
                    if type(rendered) == "string" then
                        phase = phase_names[rendered:gsub("^ESpyGamePhase::", "")]
                    end
                end
            end
            -- VAULT_LOCKED through EXTRACTION_ARRIVED. These phases are shared
            -- by the stock Solo, Duo, and Trio flows.
            if phase and phase >= 3 and phase <= 6 then return true end
        end
    end
    return false
end

local disable_suspicion = false
local disable_cover = false
local gameplay_ready = {}
local gameplay_last_error = {}

local function suppress_suspicion(pawn)
    local changed = false
    local before = {}
    local read_ok = pcall(function()
        before.npc_check = unwrap(pawn.SusEnableNPCCheck)
        before.suspicious = unwrap(pawn.bIsSuspicious)
        before.stamina = unwrap(pawn.StaminaCurrent)
        before.stamina_max = unwrap(pawn.StaminaMax)
        before.drain = unwrap(pawn.StaminaDrainRate)
        before.multiplier = unwrap(pawn.StaminaDrainRateMultiplier)
    end)
    if not read_ok or type(before.stamina_max) ~= "number" then
        return false, "suspicion properties unavailable", changed, ""
    end

    local write_ok, write_error = pcall(function()
        if before.npc_check ~= false then
            pawn.SusEnableNPCCheck = false
            changed = true
        end
        if before.suspicious ~= false then
            pawn.bIsSuspicious = false
            changed = true
        end
        if before.drain ~= 0 then
            pawn.StaminaDrainRate = 0.0
            changed = true
        end
        if before.multiplier ~= 0 then
            pawn.StaminaDrainRateMultiplier = 0.0
            changed = true
        end
    end)
    if not write_ok then
        return false, "suspicion write failed: " .. tostring(write_error),
               changed, ""
    end

    if type(before.stamina) ~= "number" or
       before.stamina < before.stamina_max then
        pcall(function() pawn:ResetStaminaToMax() end)
        local reset_value
        pcall(function() reset_value = unwrap(pawn.StaminaCurrent) end)
        if type(reset_value) ~= "number" or
           reset_value < before.stamina_max then
            pcall(function() pawn.StaminaCurrent = before.stamina_max end)
        end
        changed = true
    end

    local interacter
    pcall(function() interacter = unwrap(pawn.InteracterComponent) end)
    if interacter ~= nil then
        local can_trigger
        pcall(function()
            can_trigger = unwrap(interacter.bCanTriggerBotSuspiciousness)
        end)
        if can_trigger ~= false then
            pcall(function()
                interacter.bCanTriggerBotSuspiciousness = false
            end)
            changed = true
        end
    end

    local after = {}
    local verify_ok = pcall(function()
        after.npc_check = unwrap(pawn.SusEnableNPCCheck)
        after.suspicious = unwrap(pawn.bIsSuspicious)
        after.stamina = unwrap(pawn.StaminaCurrent)
        after.stamina_max = unwrap(pawn.StaminaMax)
        after.drain = unwrap(pawn.StaminaDrainRate)
        after.multiplier = unwrap(pawn.StaminaDrainRateMultiplier)
        if interacter then
            after.can_trigger =
                unwrap(interacter.bCanTriggerBotSuspiciousness)
        end
    end)
    local verified = verify_ok and after.npc_check == false and
        after.suspicious == false and after.drain == 0 and
        after.multiplier == 0 and after.can_trigger == false and
        type(after.stamina) == "number" and
        type(after.stamina_max) == "number" and
        after.stamina >= after.stamina_max
    local detail = string.format(
        "suspicion[npc=%s state=%s stamina=%s/%s drain=%s multiplier=%s]",
        tostring(after.npc_check), tostring(after.suspicious),
        tostring(after.stamina), tostring(after.stamina_max),
        tostring(after.drain), tostring(after.multiplier))
    return verified, verified and nil or "suspicion read-back failed", changed,
           detail
end

local function suppress_cover(pawn)
    local before = {}
    local read_ok = pcall(function()
        before.disabled = unwrap(pawn.bCheatDisableCover)
        before.ratio = unwrap(pawn.CoverRatio)
    end)
    if not read_ok then return false, "cover properties unavailable", false, "" end

    local changed = before.disabled ~= true or before.ratio ~= 0
    if changed then
        -- Do not call AllowCover(false) here. On the dedicated server that
        -- native transition calls BlowCover and immediately requests process
        -- exit when deployment begins. IsUndercover() is avoided for the same
        -- reason: scalar reflected fields are the crash-safe server surface.
        local write_ok, write_error = pcall(function()
            pawn.bCheatDisableCover = true
            pawn.CoverRatio = 0.0
        end)
        if not write_ok then
            return false, "cover write failed: " .. tostring(write_error),
                   changed, ""
        end
    end

    local after = {}
    local verify_ok = pcall(function()
        after.disabled = unwrap(pawn.bCheatDisableCover)
        after.ratio = unwrap(pawn.CoverRatio)
    end)
    local verified = verify_ok and after.disabled == true and
                     after.ratio == 0
    local detail = string.format("cover[disabled=%s ratio=%s]",
        tostring(after.disabled), tostring(after.ratio))
    return verified, verified and nil or "cover read-back failed", changed,
           detail
end

local function apply_gameplay()
    if not disable_suspicion and not disable_cover then return end
    if not active_match() then return end
    for _, pawn in ipairs(live_spies()) do
        local key = full(pawn)
        local ok, changed, reasons, details = true, false, {}, {}
        if disable_suspicion then
            local worked, why, altered, detail = suppress_suspicion(pawn)
            ok, changed = ok and worked, changed or altered
            if why then reasons[#reasons + 1] = why end
            details[#details + 1] = detail
        end
        if disable_cover then
            local worked, why, altered, detail = suppress_cover(pawn)
            ok, changed = ok and worked, changed or altered
            if why then reasons[#reasons + 1] = why end
            details[#details + 1] = detail
        end
        if changed then pcall(function() pawn:ForceNetUpdate() end) end
        if ok then
            gameplay_last_error[key] = nil
            if not gameplay_ready[key] then
                gameplay_ready[key] = true
                log("gameplay overrides verified: " .. key .. " " ..
                    table.concat(details, " "))
            elseif changed then
                log("gameplay overrides restored: " .. key .. " " ..
                    table.concat(details, " "))
            end
        else
            local reason = table.concat(reasons, "; ")
            if gameplay_last_error[key] ~= reason then
                gameplay_last_error[key] = reason
                log("gameplay overrides pending: " .. key .. " " .. reason)
            end
        end
    end
end

-- set a field inside a struct-valued property and verify it stuck
local function set_struct_field(obj, structprop, field, value)
    local before, after
    local ok = pcall(function() before = obj[structprop][field] end)
    if not ok or before == nil then return nil, "unreadable" end
    if before == value then return before, "already" end
    local sok = pcall(function() obj[structprop][field] = value end)
    if not sok then return before, "write-failed" end
    pcall(function() after = obj[structprop][field] end)
    if after == value then return before, "ok" end
    return before, "did-not-stick (now " .. tostring(after) .. ")"
end

-- set a plain (non-struct) property and verify it stuck
local function set_field(obj, field, value)
    local before, after
    local ok = pcall(function() before = obj[field] end)
    if not ok or before == nil then return nil, "unreadable" end
    if before == value then return before, "already" end
    local sok = pcall(function() obj[field] = value end)
    if not sok then return before, "write-failed" end
    pcall(function() after = obj[field] end)
    if after == value then return before, "ok" end
    return before, "did-not-stick (now " .. tostring(after) .. ")"
end

local function apply(verbose)
    -- 0. spectator slots. This is the ONLY spectator control reachable by
    -- reflection in this build - bIsSpectator, bOnlySpectator and
    -- bStartPlayersAsSpectators are all absent (see docs/05 section 8). It
    -- caps how many spectators the session accepts; it cannot make anyone one.
    if cfg.MaxSpectators then
        local objs = FindAllOf("DeceiveIncGameSession")
        if objs then
            for i = 1, #objs do
                local o = objs[i]
                local isclass = false; pcall(function() isclass = o:IsAnyClass() end)
                if not isclass then
                    local before, status = set_field(o, "MaxSpectators", cfg.MaxSpectators)
                    if verbose or (status ~= "ok" and status ~= "already") then
                        log(string.format("MaxSpectators: %s -> %s  [%s]",
                            tostring(before), tostring(cfg.MaxSpectators), tostring(status)))
                    end
                end
            end
        end
    end

    -- 1. pregame lobby countdown
    if cfg.LobbyWaitTime then
        local objs = FindAllOf("PregameLobbyMapData")
        if objs then
            for i = 1, #objs do
                local o = objs[i]
                local isclass = false; pcall(function() isclass = o:IsAnyClass() end)
                if not isclass then
                    local before, status = set_struct_field(o, "PregameLobbyPhaseData",
                                                            "DefaultPhaseDuration", cfg.LobbyWaitTime)
                    if verbose or (status ~= "ok" and status ~= "already") then
                        log(string.format("LobbyWaitTime: %s -> %s  [%s]",
                            tostring(before), tostring(cfg.LobbyWaitTime), tostring(status)))
                    end
                end
            end
        end
    end

    -- 2. spy intro phase, per map
    if cfg.IntroPhaseTime then
        local objs = FindAllOf("SpyGameModeMapData")
        if objs then
            local n, okc = 0, 0
            for i = 1, #objs do
                local o = objs[i]
                local isclass = false; pcall(function() isclass = o:IsAnyClass() end)
                if not isclass then
                    n = n + 1
                    local _, status = set_struct_field(o, "IntroPhaseData",
                                                       "DefaultPhaseDuration", cfg.IntroPhaseTime)
                    if status == "ok" or status == "already" then okc = okc + 1 end
                end
            end
            if verbose or okc ~= n then
                log(string.format("IntroPhaseTime -> %s applied to %d/%d map data assets",
                    tostring(cfg.IntroPhaseTime), okc, n))
            end
        end
    end
end

load_ini()
disable_suspicion = enabled(cfg.DisableSuspicion)
disable_cover = enabled(cfg.DisableCover)
log("config: LobbyWaitTime=" .. tostring(cfg.LobbyWaitTime) ..
    " IntroPhaseTime=" .. tostring(cfg.IntroPhaseTime) ..
    " MaxSpectators=" .. tostring(cfg.MaxSpectators) ..
    " DisableSuspicion=" .. tostring(disable_suspicion) ..
    " DisableCover=" .. tostring(disable_cover))

-- TIMING MATTERS. The game copies DefaultPhaseDuration out of the data asset
-- when the pregame phase begins (ADeceiveIncMatchGameState::
-- SetCurrentPhaseInfoFromMapData). Writing the asset after that instant has no
-- effect on the match already running - it only takes hold on the next map
-- cycle. So: apply immediately at mod load, hammer briefly to win the race,
-- then settle into a slow loop that survives map changes.
pcall(apply, true)

local fast = 0
LoopAsync(500, function()          -- every 0.5s for ~30s
    fast = fast + 1
    pcall(apply, false)
    return fast >= 60              -- returning true stops this loop
end)

LoopAsync(30000, function()        -- then keep it applied across map changes
    pcall(apply, false)
    return false
end)

-- Pawn controls are dynamic and can be restored by deploy, cover, or respawn
-- paths, so keep these broad gameplay rules authoritative once per second.
LoopAsync(1000, function()
    pcall(apply_gameplay)
    return false
end)

log("loaded")
