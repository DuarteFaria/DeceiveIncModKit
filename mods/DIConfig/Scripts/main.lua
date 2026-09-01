-- DIConfig: apply server-side gameplay overrides that TripwireServer.ini
-- does not expose. Reads DIConfig.ini from the Win64 folder.
--
-- [Timing]
-- LobbyWaitTime   = 30    ; pregame lobby countdown, seconds (default 90)
-- IntroPhaseTime  = 10    ; spy intro/posing phase, seconds (default 19)

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
log("config: LobbyWaitTime=" .. tostring(cfg.LobbyWaitTime) ..
    " IntroPhaseTime=" .. tostring(cfg.IntroPhaseTime) ..
    " MaxSpectators=" .. tostring(cfg.MaxSpectators))

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

log("loaded")
