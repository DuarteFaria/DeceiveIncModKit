-- DISpawn v2: deep-probe room item spawn points and match rules.
--
-- v1 hard-crashed the server at t+60s and wrote NOTHING, because it buffered
-- 300 lines before its first flush. A crash inside UE4SS is not catchable by
-- pcall (see docs/05, the door functions), so buffering means losing the one
-- thing that matters: which property killed it.
--
-- v2 is built around that. Every line is appended and the file closed
-- immediately, and the property name and type are written BEFORE the value is
-- read. If it dies again, the last line of the dump names the exact culprit.
--
-- Object-reference values are the prime suspect: a null or stale UObject
-- pointer that GetFullName() happily dereferences. So reading them is OFF by
-- default. Run once to get a complete name+type map, then switch it on.
--
-- [Probe]
-- ReadObjectRefs = 0   ; 1 = also resolve ObjectProperty values by name
-- Samples        = 2   ; instances printed per class
--
-- Strictly read-only. Output: Win64/DISpawn_dump.txt
local OUT = "DISpawn_dump.txt"
local INI = "DIConfig.ini"

local cfg = { ReadObjectRefs = 0, Samples = 2 }
do
    local fh = io.open(INI, "r")
    if fh then
        for line in fh:lines() do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*([^;]+)")
            if k and v and cfg[k] ~= nil then cfg[k] = tonumber(v) or cfg[k] end
        end
        fh:close()
    end
end

local TARGETS = {
    -- room item spawning (the original goal)
    "BP_ObjectSpawn_Generic_C",
    "BP_ObjectSpawn_BigLootable_C",
    "BP_ObjectSpawn_LAFBoxes_C",
    "BP_ObjectSpawn_VaultPrinter_C",
    "BP_Small_Object_Spawn_C",
    "BP_ObjectSpawningManager_C",
    "DIObjectSpawnPresetsDataAsset",
    -- match rules: player counts, phases, allowed modes
    "DeceiveIncMatchGameState",
    "BP_DeceiveIncMatchGameState_C",
    "BP_DeceiveIncSpyGameState_C",
    "BP_DeceiveIncBaseGameMode_C",
    "DIAllowedGameModesHandler",
    -- suspicion
    "DIPopulationManagerNPCSuspiciousnessDataAsset",
    "NPCBehaviorDefault",
}

-- Anything already known to kill the process goes here, so a rerun gets past
-- it instead of dying in the same spot. Format: ["ClassName.PropName"] = true
local BLACKLIST = {}

-- Unbuffered by design: a crash must not cost us the breadcrumb.
local function w(s)
    local fh = io.open(OUT, "a")
    if fh then fh:write(tostring(s) .. "\n"); fh:close() end
end

local KINDS = { "BoolProperty", "IntProperty", "FloatProperty", "DoubleProperty",
                "ByteProperty", "EnumProperty", "NameProperty", "StrProperty",
                "TextProperty", "StructProperty", "ArrayProperty", "MapProperty",
                "SetProperty", "ObjectProperty", "ClassProperty",
                "SoftObjectProperty", "SoftClassProperty" }

local function kind_of(p)
    for _, k in ipairs(KINDS) do
        local ok, is = pcall(function() return p:IsA(PropertyTypes[k]) end)
        if ok and is then return k end
    end
    return "?"
end

-- Kinds whose values are plain data and safe to read.
local SAFE = {
    BoolProperty = true, IntProperty = true, FloatProperty = true,
    DoubleProperty = true, ByteProperty = true, EnumProperty = true,
    NameProperty = true, StrProperty = true, TextProperty = true,
}
local REF = {
    ObjectProperty = true, ClassProperty = true,
    SoftObjectProperty = true, SoftClassProperty = true,
}

local function render(v)
    local t = type(v)
    if v == nil then return "<nil>" end
    if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
    if t == "userdata" then
        local ok, s = pcall(function() return v:ToString() end)
        if ok and type(s) == "string" and s ~= "" then return s end
        local ok2, n = pcall(function() return v:GetFName():ToString() end)
        if ok2 and n then return n end
        return "<userdata>"
    end
    return "<" .. t .. ">"
end

local dump_props

local function handle(owner, p, cls_name, indent, depth)
    local pn
    if not pcall(function() pn = p:GetFName():ToString() end) or not pn then
        w(indent .. "<unnamed property>")
        return
    end
    local kind = kind_of(p)

    -- breadcrumb FIRST. If the process dies on the next line, this is the last
    -- thing in the file and it names the culprit exactly.
    w(indent .. pn .. "  [" .. kind .. "]")

    if BLACKLIST[cls_name .. "." .. pn] then
        w(indent .. "    <skipped: blacklisted>")
        return
    end

    if REF[kind] and cfg.ReadObjectRefs ~= 1 then
        w(indent .. "    <ref not read; set [Probe] ReadObjectRefs=1>")
        return
    end

    local v, got = nil, false
    got = pcall(function() v = owner[pn] end)
    if not got then w(indent .. "    <read error>"); return end
    if v == nil then w(indent .. "    = <nil>"); return end

    if kind == "ArrayProperty" then
        local cnt = -1
        pcall(function() cnt = v:GetArrayNum() end)
        w(indent .. "    (" .. cnt .. " entries)")
        if depth >= 3 or cnt <= 0 then return end
        local inner, innerstruct
        pcall(function() inner = p:GetInner() end)
        if inner then
            pcall(function()
                if inner:IsA(PropertyTypes.StructProperty) then
                    innerstruct = inner:GetStruct()
                end
            end)
        end
        for i = 1, math.min(cnt, 8) do
            local e
            if pcall(function() e = v[i] end) and e ~= nil then
                if innerstruct then
                    w(indent .. "    [" .. i .. "]")
                    dump_props(e, innerstruct, cls_name, indent .. "        ", depth + 1)
                else
                    w(indent .. "    [" .. i .. "] " .. render(e))
                end
            end
        end
    elseif kind == "StructProperty" then
        if depth >= 3 then return end
        local st; pcall(function() st = p:GetStruct() end)
        if st then dump_props(v, st, cls_name, indent .. "    ", depth + 1) end
    elseif SAFE[kind] or REF[kind] then
        w(indent .. "    = " .. render(v))
    else
        w(indent .. "    = " .. render(v))
    end
end

dump_props = function(owner, struct, cls_name, indent, depth)
    local n = 0
    pcall(function()
        struct:ForEachProperty(function(p)
            n = n + 1
            pcall(handle, owner, p, cls_name, indent, depth)
            return false
        end)
    end)
    return n
end

local STOP = { Actor = true, Object = true, DataAsset = true,
               PrimaryDataAsset = true, ["None"] = true }

local function dump_obj(obj, label)
    local full; pcall(function() full = obj:GetFullName() end)
    w("")
    w("--- " .. label .. " :: " .. tostring(full))
    local cls; pcall(function() cls = obj:GetClass() end)
    local guard = 0
    while cls and guard < 10 do
        guard = guard + 1
        local cn; pcall(function() cn = cls:GetFName():ToString() end)
        if not cn or STOP[cn] then break end
        w("  [" .. cn .. "]")
        local n = dump_props(obj, cls, cn, "     ", 1)
        if n == 0 then w("     (no own properties)") end
        local nxt; pcall(function() nxt = cls:GetSuperStruct() end)
        cls = nxt
    end
end

-- A spawn point that picks its contents at runtime is a hook target, not a
-- property write, so the function list matters as much as the properties.
local function dump_funcs(obj, cn)
    local seen, out = {}, {}
    local cls; pcall(function() cls = obj:GetClass() end)
    local guard = 0
    while cls and guard < 10 do
        guard = guard + 1
        local n; pcall(function() n = cls:GetFName():ToString() end)
        if not n or STOP[n] then break end
        pcall(function()
            cls:ForEachFunction(function(f)
                pcall(function()
                    local fn = f:GetFName():ToString()
                    if fn and not seen[fn] then
                        seen[fn] = true
                        out[#out+1] = n .. "::" .. fn
                    end
                end)
                return false
            end)
        end)
        local nxt; pcall(function() nxt = cls:GetSuperStruct() end)
        cls = nxt
    end
    if #out > 0 then
        table.sort(out)
        w("")
        w("  functions on " .. cn .. ":")
        for _, f in ipairs(out) do w("     " .. f) end
    end
end

local function run(tag)
    w("")
    w("################ DISpawn v2 " .. tag ..
      "  (ReadObjectRefs=" .. cfg.ReadObjectRefs .. ") ################")
    for _, cn in ipairs(TARGETS) do
        w("")
        w("======== " .. cn)          -- breadcrumb before FindAllOf too
        local objs; pcall(function() objs = FindAllOf(cn) end)
        local total = objs and #objs or 0
        w("   instances: " .. total)
        if total > 0 then
            local shown = 0
            for i = 1, total do
                local o = objs[i]
                local isc = false; pcall(function() isc = o:IsAnyClass() end)
                if not isc then
                    shown = shown + 1
                    if shown == 1 then pcall(dump_funcs, o, cn) end
                    pcall(dump_obj, o, cn .. " #" .. i)
                    if shown >= cfg.Samples then break end
                end
            end
        end
    end
    w("")
    w("################ END " .. tag .. " ################")
    print("[DISpawn] " .. tag .. " done -> " .. OUT .. "\n")
end

ExecuteWithDelay(60000,  function() pcall(run, "t+60s")  end)
ExecuteWithDelay(180000, function() pcall(run, "t+180s") end)
print("[DISpawn] v2 loaded - probes at t+60s and t+180s\n")
