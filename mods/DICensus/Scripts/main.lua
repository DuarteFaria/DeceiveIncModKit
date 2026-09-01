-- DICensus: answer "what is actually moddable?" empirically instead of by guesswork.
--
-- DIProbe only ever looked at six class names we had already guessed. That can
-- confirm a hunch but it can never tell us what we failed to think of. This
-- walks the WHOLE UObject graph, tallies every game-owned class, then deep-dumps
-- one exemplar per class so we can see the real tunable surface.
--
-- Strictly read-only. Output: Win64/DICensus_dump.txt
local OUT = "DICensus_dump.txt"

-- Engine classes vastly outnumber game classes and none of them are what we
-- want, so keep only things the studio authored. DI* is their C++ prefix,
-- Spy/Agent/Gadget/etc are the gameplay nouns seen in the logs.
local KEEP = {
    "^DI", "Spy", "Agent", "Gadget", "Weapon", "Objective", "Vault",
    "Suspicio", "Spawn", "Phase", "Loadout", "Perk", "Powerup", "Gamble",
    "Reward", "Progression", "MapData", "GameMode", "GameState", "Guard",
    "NPC", "Population", "Interact", "Camera", "Door", "Deceive", "Match",
    "Tripwire", "Cosmetic", "Currency", "Ability", "Damage", "Health",
}

-- Property names that look like a knob a server owner would want to turn.
local TUNABLE = {
    "duration", "time", "delay", "cooldown", "speed", "rate", "damage",
    "health", "shield", "radius", "range", "amount", "count", "max", "min",
    "weight", "chance", "percent", "factor", "multiplier", "scale", "limit",
    "threshold", "enable", "allow", "bcan", "bis", "buse", "num", "size",
}

local lines = {}
local function w(s)
    s = tostring(s)
    lines[#lines + 1] = s
    if #lines > 400 then
        pcall(function()
            local fh = io.open(OUT, "a")
            if fh then fh:write(table.concat(lines, "\n") .. "\n"); fh:close() end
        end)
        lines = {}
    end
end
local function flush()
    pcall(function()
        local fh = io.open(OUT, "a")
        if fh then fh:write(table.concat(lines, "\n") .. "\n"); fh:close() end
    end)
    lines = {}
end

local function interesting(cn)
    for _, pat in ipairs(KEEP) do if cn:find(pat) then return true end end
    return false
end

local function is_tunable(pn)
    local l = pn:lower()
    for _, t in ipairs(TUNABLE) do if l:find(t, 1, true) then return true end end
    return false
end

local function scalar(v)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
    return nil
end

-- PASS 1 -----------------------------------------------------------------
-- Tally live instances per class. Cheap work only: one GetClass + one name.
local counts, exemplar = {}, {}

local function census()
    local total, kept = 0, 0
    ForEachUObject(function(obj)
        total = total + 1
        local isc = false; pcall(function() isc = obj:IsAnyClass() end)
        if isc then return false end          -- skip CDOs/class objects
        local cn
        if not pcall(function() cn = obj:GetClass():GetFName():ToString() end) then
            return false
        end
        if cn and interesting(cn) then
            kept = kept + 1
            counts[cn] = (counts[cn] or 0) + 1
            if not exemplar[cn] then exemplar[cn] = obj end
        end
        return false
    end)
    w("objects walked: " .. total .. "   game-owned instances: " .. kept)
end

-- PASS 2 -----------------------------------------------------------------
-- For each distinct class, dump the scalar properties of one instance,
-- walking the superclass chain (own-properties-only is the trap that cost us
-- a full iteration last time).
local STOP = { Actor = true, Object = true, DataAsset = true,
               PrimaryDataAsset = true, Pawn = true, Character = true,
               ActorComponent = true, SceneComponent = true, ["None"] = true }

local function dump_class(cn, obj)
    local shown = {}
    local out = {}
    local cls; pcall(function() cls = obj:GetClass() end)
    local guard = 0
    while cls and guard < 10 do
        guard = guard + 1
        local n; pcall(function() n = cls:GetFName():ToString() end)
        if not n or STOP[n] then break end
        pcall(function()
            cls:ForEachProperty(function(p)
                pcall(function()
                    local pn = p:GetFName():ToString()
                    if pn and not shown[pn] then
                        shown[pn] = true
                        local v; pcall(function() v = obj[pn] end)
                        local s = scalar(v)
                        if s then
                            local mark = is_tunable(pn) and "  <== " or "      "
                            out[#out+1] = mark .. pn .. " = " .. s
                        end
                    end
                end)
                return false
            end)
        end)
        local nxt; pcall(function() nxt = cls:GetSuperStruct() end)
        cls = nxt
    end
    if #out > 0 then
        w("")
        w("=== " .. cn .. "   x" .. counts[cn])
        for _, l in ipairs(out) do w(l) end
    end
end

local function run(tag)
    -- each snapshot starts from a clean tally, so a later pass genuinely
    -- reflects what exists *now* rather than accumulating stale instances
    counts, exemplar = {}, {}
    w("")
    w("################ DICensus " .. tag .. " ################")
    census()

    -- sort class names so successive runs diff cleanly
    local names = {}
    for cn in pairs(counts) do names[#names+1] = cn end
    table.sort(names)

    w("")
    w("---- class tally (" .. #names .. " distinct) ----")
    for _, cn in ipairs(names) do w(string.format("%6d  %s", counts[cn], cn)) end

    w("")
    w("---- scalar properties per class ('<==' = looks tunable) ----")
    for _, cn in ipairs(names) do pcall(dump_class, cn, exemplar[cn]) end

    w("")
    w("################ END ################")
    flush()
    print("[DICensus] done -> " .. OUT .. "\n")
end

-- TIMING. A single early snapshot is what made the first room-item hunt come
-- up empty: spawn points, NPCs, guards and loadouts do not exist until a match
-- is actually underway, and a lone t+45s pass lands in the pregame lobby.
-- So take several across the match and diff them. The census profile also
-- shortens the lobby so play starts before the first snapshot.
local SNAPSHOTS = { 45000, 120000, 300000 }
for _, ms in ipairs(SNAPSHOTS) do
    ExecuteWithDelay(ms, function()
        pcall(run, "t+" .. math.floor(ms / 1000) .. "s")
    end)
end
print("[DICensus] loaded - snapshots at t+45s, t+120s, t+300s\n")
