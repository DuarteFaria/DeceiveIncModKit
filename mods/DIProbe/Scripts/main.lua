-- DIProbe v3: deep-dump target assets, walking the superclass chain and
-- recursing into structs and arrays-of-structs. Read-only.
-- Output: Win64/DIProbe_dump.txt

local OUT = "DIProbe_dump.txt"
local MAXDEPTH = 5

local TARGET_CLASSES = {
    "PregameLobbyMapData",
    "DIObjectSpawnPresetsDataAsset",
    "ObjectSpawningManager",
    "DIPopulationManagerNPCSuspiciousnessDataAsset",
    "MapData",
    "SpyGameModeMapData",
}

-- classes to stop at when walking up the superclass chain (engine noise)
local STOP = { Actor = true, Object = true, DataAsset = true,
               PrimaryDataAsset = true, ["None"] = true }

local lines = {}
local function w(s)
    s = tostring(s)
    print("[DIProbe] " .. s .. "\n")
    lines[#lines + 1] = s
end

local function flush_lines()
    local ok, err = pcall(function()
        local fh = io.open(OUT, "a")
        if fh then fh:write(table.concat(lines, "\n") .. "\n"); fh:close() end
    end)
    if not ok then print("[DIProbe] write failed: " .. tostring(err) .. "\n") end
    lines = {}
end

local function ptype(prop, kind)
    local ok, r = pcall(function() return prop:IsA(PropertyTypes[kind]) end)
    return ok and r
end

local function short(v)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
    if t == "userdata" then
        local ok, s = pcall(function() return v:ToString() end)
        if ok and type(s) == "string" then return s end
    end
    return nil
end

local dump_struct

local function dump_value(name, val, prop, indent, depth)
    local s = short(val)
    if s then w(indent .. name .. " = " .. s); return end

    if ptype(prop, "StructProperty") then
        w(indent .. name .. ":")
        local inner; pcall(function() inner = prop:GetStruct() end)
        if inner and depth < MAXDEPTH then dump_struct(val, inner, indent .. "    ", depth + 1) end
        return
    end

    if ptype(prop, "ArrayProperty") then
        local n = 0
        pcall(function() n = val:GetArrayNum() end)
        w(indent .. name .. ":  (" .. n .. " entries)")
        if n == 0 or depth >= MAXDEPTH then return end
        local innerprop; pcall(function() innerprop = prop:GetInner() end)
        local innerstruct
        if innerprop and ptype(innerprop, "StructProperty") then
            pcall(function() innerstruct = innerprop:GetStruct() end)
        end
        local shown = math.min(n, 16)
        for i = 1, shown do
            local e
            if pcall(function() e = val[i] end) and e ~= nil then
                local es = short(e)
                if es then
                    w(indent .. "  [" .. i .. "] " .. es)
                elseif innerstruct then
                    w(indent .. "  [" .. i .. "]")
                    dump_struct(e, innerstruct, indent .. "      ", depth + 1)
                else
                    local fn; pcall(function() fn = e:GetFullName() end)
                    w(indent .. "  [" .. i .. "] " .. tostring(fn))
                end
            end
        end
        if n > shown then w(indent .. "  ... " .. (n - shown) .. " more") end
        return
    end

    local fn; pcall(function() fn = val:GetFullName() end)
    w(indent .. name .. " = " .. (fn or ("<" .. type(val) .. ">")))
end

-- iterate the properties declared directly on `struct`, reading them from `owner`
local function dump_own(owner, struct, indent, depth)
    pcall(function()
        struct:ForEachProperty(function(prop)
            local name; pcall(function() name = prop:GetFName():ToString() end)
            if not name then return false end
            local val, got
            got = pcall(function() val = owner[name] end)
            if not got or val == nil then
                w(indent .. name .. " = <unreadable>")
            else
                pcall(dump_value, name, val, prop, indent, depth)
            end
            return false
        end)
    end)
end

dump_struct = function(val, struct, indent, depth)
    if not val or not struct or depth > MAXDEPTH then return end
    dump_own(val, struct, indent, depth)
end

local function dump_object(obj)
    local full; pcall(function() full = obj:GetFullName() end)
    local isclass = false; pcall(function() isclass = obj:IsAnyClass() end)
    if isclass then return end
    w("")
    w("=== " .. tostring(full))
    local cls; pcall(function() cls = obj:GetClass() end)
    local guard = 0
    while cls and guard < 12 do
        guard = guard + 1
        local cn; pcall(function() cn = cls:GetFName():ToString() end)
        if not cn or STOP[cn] then break end
        w("  [" .. cn .. "]")
        dump_own(obj, cls, "    ", 1)
        local nxt; pcall(function() nxt = cls:GetSuperStruct() end)
        cls = nxt
    end
end

local function scan(tag)
    w("")
    w("############ SCAN " .. tag .. " ############")
    for _, cn in ipairs(TARGET_CLASSES) do
        local objs; local ok = pcall(function() objs = FindAllOf(cn) end)
        local n = (ok and objs) and #objs or 0
        w("")
        w("---------- " .. cn .. ": " .. n .. " instance(s)")
        for i = 1, n do pcall(dump_object, objs[i]) end
    end
    w("############ END " .. tag .. " ############")
end

local function run(tag)
    local ok, err = pcall(scan, tag)
    if not ok then w("SCAN ERROR: " .. tostring(err)) end
    flush_lines()
end

ExecuteWithDelay(20000,  function() run("t+20s") end)
ExecuteWithDelay(120000, function() run("t+120s") end)

print("[DIProbe] v3 loaded; scans at 20s / 120s\n")
