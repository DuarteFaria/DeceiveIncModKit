-- DIKill: make designated players die on spawn so they end up spectating.
--
-- Two problems to solve, and this mod's first job is to answer the second.
--
-- 1. WHO. There is no way to identify a player server-side. DIPlayerState
--    reflects only Score, and PlayerName is not reflected, so "kill Bob" is
--    impossible. The workaround is join order: kill the LAST N pawns to
--    appear. You control who joins last, so that is usable in practice.
--
-- 2. HOW. Killing has to run the game's own elimination path, or the player
--    will not enter the spectate flow. Destroying the pawn outright may just
--    leave a broken connection. So this dumps the pawn's full function list
--    first and kills nothing until told to.
--
-- [Spectate]
-- DumpOnly     = 1   ; 1 = probe only (default). 0 = actually kill.
-- KillLastN    = 2   ; how many of the most recent pawns to kill
-- KillMethod   = destroy   ; destroy | <function name from the dump>
-- KillDelayMs  = 3000      ; wait after a pawn appears before killing it
--
-- Output: Win64/DIKill_dump.txt
local OUT = "DIKill_dump.txt"
local INI = "DIConfig.ini"

local cfg = { DumpOnly = 1, KillLastN = 2, KillDelayMs = 3000,
              KillMethod = "destroy" }
do
    local fh = io.open(INI, "r")
    if fh then
        for line in fh:lines() do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*([^;]+)")
            if k and v and cfg[k] ~= nil then
                v = v:gsub("%s+$", "")
                cfg[k] = tonumber(v) or v
            end
        end
        fh:close()
    end
end

local function w(s)
    local fh = io.open(OUT, "a")
    if fh then fh:write(tostring(s) .. "\n"); fh:close() end
end
local function log(s) print("[DIKill] " .. tostring(s) .. "\n") end

-- Spy pawns are named BPSpy_<Agent>_Main_V1_C, one class per agent, so there
-- is no single class to search. Walk the graph for anything matching instead.
local function live_spy_pawns()
    local out = {}
    pcall(function()
        ForEachUObject(function(obj)
            local isc = false; pcall(function() isc = obj:IsAnyClass() end)
            if isc then return false end
            local cn
            if not pcall(function() cn = obj:GetClass():GetFName():ToString() end) then
                return false
            end
            if cn and cn:find("^BPSpy_") and cn:find("_Main_") then
                out[#out + 1] = obj
            end
            return false
        end)
    end)
    return out
end

local STOP = { Object = true, ["None"] = true }

local function dump_funcs(obj, label)
    local seen, out = {}, {}
    local cls; pcall(function() cls = obj:GetClass() end)
    local guard = 0
    while cls and guard < 14 do
        guard = guard + 1
        local n; pcall(function() n = cls:GetFName():ToString() end)
        if not n or STOP[n] then break end
        pcall(function()
            cls:ForEachFunction(function(f)
                pcall(function()
                    local fn = f:GetFName():ToString()
                    if fn and not seen[fn] then
                        seen[fn] = true
                        out[#out + 1] = n .. "::" .. fn
                    end
                end)
                return false
            end)
        end)
        local nxt; pcall(function() nxt = cls:GetSuperStruct() end)
        cls = nxt
    end
    table.sort(out)
    w("")
    w("  functions on " .. label .. " (" .. #out .. "):")
    for _, f in ipairs(out) do
        -- flag anything that looks like it could end a life
        local l = f:lower()
        local mark = (l:find("kill") or l:find("die") or l:find("death") or
                      l:find("damage") or l:find("destroy") or l:find("elimin")
                      or l:find("health")) and "  <== " or "      "
        w(mark .. f)
    end
end

local probed = false

local function probe()
    local pawns = live_spy_pawns()
    if #pawns == 0 then return end
    probed = true
    w("")
    w("################ DIKill probe ################")
    w("  live spy pawns: " .. #pawns)
    for i = 1, #pawns do
        local full; pcall(function() full = pawns[i]:GetFullName() end)
        w("   [" .. i .. "] " .. tostring(full))
    end
    pcall(dump_funcs, pawns[1], "spy pawn")

    -- the controller and player state are the other places a kill might live
    local pcs; pcall(function() pcs = FindAllOf("DeceiveIncPlayerController") end)
    if pcs and #pcs > 0 then pcall(dump_funcs, pcs[1], "DeceiveIncPlayerController") end
    local ps; pcall(function() ps = FindAllOf("DIPlayerState") end)
    if ps and #ps > 0 then pcall(dump_funcs, ps[1], "DIPlayerState") end

    w("################ END ################")
    log("probe written to " .. OUT)
end

local killed = {}

local function do_kill()
    local pawns = live_spy_pawns()
    if #pawns == 0 then return end
    -- last N in enumeration order; UObject order tracks allocation, so the
    -- most recently spawned pawns land at the end
    local first = math.max(1, #pawns - cfg.KillLastN + 1)
    for i = first, #pawns do
        local p = pawns[i]
        local full; pcall(function() full = p:GetFullName() end)
        if full and not killed[full] then
            killed[full] = true
            log("killing [" .. i .. "/" .. #pawns .. "] " .. tostring(full))
            local ok
            if cfg.KillMethod == "destroy" then
                ok = pcall(function() p:K2_DestroyActor() end)
            else
                ok = pcall(function() p[cfg.KillMethod](p) end)
            end
            log("   " .. (ok and "call returned ok" or "call FAILED"))
        end
    end
end

if cfg.DumpOnly == 1 then
    log("probe mode (DumpOnly=1) - nothing will be killed")
    LoopAsync(5000, function()
        if not probed then pcall(probe) end
        return probed
    end)
else
    log("ARMED: will kill the last " .. cfg.KillLastN ..
        " pawns, method=" .. tostring(cfg.KillMethod))
    LoopAsync(cfg.KillDelayMs, function()
        pcall(do_kill)
        return false
    end)
end

log("loaded")
