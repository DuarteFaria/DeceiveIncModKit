-- DIProperSpectator: legacy read-only cheat-component availability probe.
-- Read-only in this version. It links each SpyCheatsComponent to its owning
-- spy and each human DeceiveIncPlayerController to its currently possessed
-- pawn. Output: Win64/DIProperSpectator_dump.txt
local OUT = "DIProperSpectator_dump.txt"
local done = false
local attempts = 0

local function w(s)
    local f = io.open(OUT, "a")
    if f then f:write(tostring(s) .. "\n"); f:close() end
end
local function log(s) print("[DIProperSpectator] " .. tostring(s) .. "\n") end
local function full(o)
    if o == nil then return "<nil>" end
    local s
    if pcall(function() s = o:GetFullName() end) and s then return s end
    return "<unrenderable>"
end
local function is_live(o)
    if o == nil then return false end
    local c = false; pcall(function() c = o:IsAnyClass() end)
    local n = full(o)
    return not c and not n:find("Default__", 1, true)
end

local function in_progress()
    local states; pcall(function() states = FindAllOf("GameStateBase") end)
    if not states then return false end
    for i = 1, #states do
        if is_live(states[i]) then
            local s; pcall(function() s = states[i].MatchState:ToString() end)
            if s == "InProgress" then return true end
        end
    end
    return false
end

local function probe()
    if done or not in_progress() then return end
    attempts = attempts + 1
    local comps, pcs
    pcall(function() comps = FindAllOf("SpyCheatsComponent") end)
    pcall(function() pcs = FindAllOf("DeceiveIncPlayerController") end)
    local live_comps, live_pcs = 0, 0

    w("")
    w("################ proper spectator route ################")
    if comps then
        for i = 1, #comps do
            local c = comps[i]
            if is_live(c) then
                live_comps = live_comps + 1
                local owner, ok
                ok = pcall(function() owner = c:GetOwner() end)
                w("component[" .. i .. "]=" .. full(c))
                w("  GetOwner ok=" .. tostring(ok) .. " owner=" .. full(owner))
            end
        end
    end
    if pcs then
        for i = 1, #pcs do
            local pc = pcs[i]
            if is_live(pc) then
                live_pcs = live_pcs + 1
                local pawn, ok
                ok = pcall(function() pawn = pc:GetPawn() end)
                w("controller[" .. i .. "]=" .. full(pc))
                w("  GetPawn ok=" .. tostring(ok) .. " pawn=" .. full(pawn))
            end
        end
    end
    w("live components=" .. live_comps .. " live human controllers=" .. live_pcs)
    w("################ end ################")
    -- Wait until a human controller has a pawn and at least one component is
    -- present; otherwise this snapshot landed before deployment completed.
    if live_comps > 0 and live_pcs > 0 then
        done = true
        log("ownership map complete -> " .. OUT)
    elseif attempts >= 10 then
        done = true
        log("probe stopped: no live SpyCheatsComponent after 10 snapshots")
    end
end

LoopAsync(3000, function()
    pcall(probe)
    return done
end)
log("loaded read-only")
