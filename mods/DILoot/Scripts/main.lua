-- DILoot: inventory what actually spawns in the world.
--
-- The spawn points carry no configuration - DISpawn proved that. ObjectSpawn
-- reflects exactly one useful property, SpawnedActor, a live reference to the
-- thing the point placed. So the only way to learn what a map spawns is to ask
-- every point what it is holding.
--
-- This walks ALL instances (not a sample) and tallies spawned actor classes.
-- Reading an object reference is the operation that has never been exercised
-- here, so it is treated as the dangerous one: an index breadcrumb is written
-- every BREADCRUMB points, and the tally is flushed as it goes. If the process
-- dies, the dump says which class and which index killed it.
--
-- Strictly read-only. Output: Win64/DILoot_dump.txt
local OUT = "DILoot_dump.txt"
local BREADCRUMB = 50

local CLASSES = {
    "BP_ObjectSpawn_Generic_C",
    "BP_ObjectSpawn_BigLootable_C",
    "BP_ObjectSpawn_LAFBoxes_C",
    "BP_ObjectSpawn_VaultPrinter_C",
    "BP_Small_Object_Spawn_C",
    "BP_Fieldupgrade_Spawn_C",
    "BP_GooPodSpawn_C",
    "BP_Wall_Spawn_C",
}

local function w(s)
    local fh = io.open(OUT, "a")
    if fh then fh:write(tostring(s) .. "\n"); fh:close() end
end

local function classname(o)
    local n
    if pcall(function() n = o:GetClass():GetFName():ToString() end) and n then
        return n
    end
    return nil
end

local function scan(cn)
    w("")
    w("======== " .. cn)
    local objs; pcall(function() objs = FindAllOf(cn) end)
    local total = objs and #objs or 0
    w("   spawn points: " .. total)
    if total == 0 then return end

    local tally, empty, unreadable = {}, 0, 0
    for i = 1, total do
        if i % BREADCRUMB == 0 then w("   ... at index " .. i .. "/" .. total) end
        local o = objs[i]
        local isc = false; pcall(function() isc = o:IsAnyClass() end)
        if not isc then
            local sa, got = nil, false
            got = pcall(function() sa = o.SpawnedActor end)
            if not got then
                unreadable = unreadable + 1
            elseif sa == nil then
                empty = empty + 1
            else
                -- a stale pointer is the plausible crasher; IsValid first
                local valid = true
                pcall(function() valid = sa:IsValid() end)
                if not valid then
                    empty = empty + 1
                else
                    local n = classname(sa)
                    if n then tally[n] = (tally[n] or 0) + 1
                    else unreadable = unreadable + 1 end
                end
            end
        end
    end

    local names = {}
    for n in pairs(tally) do names[#names+1] = n end
    table.sort(names, function(a, b)
        if tally[a] ~= tally[b] then return tally[a] > tally[b] end
        return a < b
    end)
    w("   empty: " .. empty .. "   unreadable: " .. unreadable)
    w("   distinct spawned classes: " .. #names)
    for _, n in ipairs(names) do
        w(string.format("   %5d  %s", tally[n], n))
    end
end

local function run(tag)
    w("")
    w("################ DILoot " .. tag .. " ################")
    for _, cn in ipairs(CLASSES) do pcall(scan, cn) end
    w("################ END " .. tag .. " ################")
    print("[DILoot] " .. tag .. " done -> " .. OUT .. "\n")
end

-- Items are placed during room setup, so anything before the match is underway
-- reads as empty. One pass mid-match is enough for an inventory.
ExecuteWithDelay(90000,  function() pcall(run, "t+90s")  end)
ExecuteWithDelay(240000, function() pcall(run, "t+240s") end)
print("[DILoot] loaded - inventory at t+90s and t+240s\n")
