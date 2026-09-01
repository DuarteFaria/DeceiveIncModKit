-- DITut v4: find the door-opening entry points, dump their signatures,
-- then try to open every tutorial sliding door.
local OUT = "DITut_dump.txt"
local lines = {}
local function w(s) s = tostring(s); print("[DITut] " .. s .. "\n"); lines[#lines+1] = s end
local function flush()
    pcall(function()
        local fh = io.open(OUT, "a")
        if fh then fh:write(table.concat(lines, "\n") .. "\n"); fh:close() end
    end)
    lines = {}
end

-- list a UFunction's parameters (params are the function's own properties)
local function sig(fn)
    local parts = {}
    pcall(function()
        fn:ForEachProperty(function(p)
            local n; pcall(function() n = p:GetFName():ToString() end)
            local cls
            pcall(function() cls = p:GetClass():GetFName():ToString() end)
            parts[#parts+1] = tostring(cls) .. " " .. tostring(n)
            return false
        end)
    end)
    return table.concat(parts, ", ")
end

local function dump_fns(obj, label)
    local cls; pcall(function() cls = obj:GetClass() end)
    local guard = 0
    while cls and guard < 4 do
        guard = guard + 1
        local cn; pcall(function() cn = cls:GetFName():ToString() end)
        if not cn then break end
        pcall(function()
            cls:ForEachFunction(function(fn)
                local n; pcall(function() n = fn:GetFName():ToString() end)
                if n then w("    " .. label .. " [" .. cn .. "] " .. n .. "(" .. sig(fn) .. ")") end
                return false
            end)
        end)
        local nxt; pcall(function() nxt = cls:GetSuperStruct() end)
        cls = nxt
    end
end

local function scan()
    w("")
    w("######## DITut v4 ########")

    local doors; pcall(function() doors = FindAllOf("BP_Tutorial_SlidingDoor_C") end)
    local nd = doors and #doors or 0
    w("sliding doors: " .. nd)

    -- names, so we can see which is the start bunker
    for i = 1, nd do
        local fn; pcall(function() fn = doors[i]:GetFullName() end)
        w("  door[" .. i .. "] " .. tostring(fn))
    end

    -- signatures on a door and on the player start
    if nd > 0 then
        w("")
        w("  -- signatures on a sliding door --")
        dump_fns(doors[1], "door")
    end
    local ps; pcall(function() ps = FindAllOf("BP_PlayerStart_Tutorial_C") end)
    if ps and #ps > 0 then
        w("")
        w("  -- signatures on BP_PlayerStart_Tutorial_C --")
        dump_fns(ps[1], "pstart")
    end

    -- try to open every door, no-arg first
    w("")
    w("  -- attempting to open doors --")
    for i = 1, nd do
        local d = doors[i]
        local nm; pcall(function() nm = d:GetFullName() end)
        local done = false
        local ok1 = pcall(function() d:BPI_SlidingDoor_Open() end)
        if ok1 then w("    [" .. i .. "] BPI_SlidingDoor_Open() OK  " .. tostring(nm)); done = true end
        if not done then
            local ok2 = pcall(function() d:ChooseDoor() end)
            if ok2 then w("    [" .. i .. "] ChooseDoor() OK  " .. tostring(nm)); done = true end
        end
        if not done then w("    [" .. i .. "] no callable open  " .. tostring(nm)) end
    end

    w("######## END ########")
end

ExecuteWithDelay(30000, function()
    local ok, err = pcall(scan)
    if not ok then w("ERROR: " .. tostring(err)) end
    flush()
end)
print("[DITut] v4 loaded\n")
