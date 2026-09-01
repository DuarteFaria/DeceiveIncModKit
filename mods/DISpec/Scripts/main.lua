-- DISpec v2: UNFILTERED dump of the few objects that decide spectator status.
--
-- v1 filtered property names to spectate/player/restart and found nothing on
-- DIPlayerState. But APlayerState::bIsSpectator and bOnlySpectator are stock
-- UE properties that should have matched. Either this build lacks them or the
-- filter dropped them, and a filtered dump cannot tell those apart - the same
-- failure that made DICensus miss the spawn points.
--
-- So: no name filtering at all. These classes are small enough to print whole,
-- and every property and every function is listed with its type. Whatever is
-- there, we will see.
--
-- Strictly read-only. Output: Win64/DISpec_dump.txt
local OUT = "DISpec_dump.txt"

local TARGETS = {
    "DIPlayerState",
    "DeceiveIncPlayerController",
    "BP_DeceiveIncBaseGameMode_C",
    "DeceiveIncGameSession",
}

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

local REF = { ObjectProperty = true, ClassProperty = true,
              SoftObjectProperty = true, SoftClassProperty = true }

local function render(v)
    local t = type(v)
    if v == nil then return "<nil>" end
    if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
    if t == "userdata" then
        local ok, s = pcall(function() return v:ToString() end)
        if ok and type(s) == "string" and s ~= "" then return s end
        return "<userdata>"
    end
    return "<" .. t .. ">"
end

-- Walk everything up to UObject. bIsSpectator lives on APlayerState and
-- bStartPlayersAsSpectators on AGameModeBase, so stopping at Actor - the usual
-- habit in these probes - would hide exactly what we are looking for.
local STOP = { Object = true, ["None"] = true }

local function dump_obj(obj, label)
    local full; pcall(function() full = obj:GetFullName() end)
    w("")
    w("--- " .. label .. " :: " .. tostring(full))
    local cls; pcall(function() cls = obj:GetClass() end)
    local guard = 0
    while cls and guard < 12 do
        guard = guard + 1
        local cn; pcall(function() cn = cls:GetFName():ToString() end)
        if not cn or STOP[cn] then break end
        w("  [" .. cn .. "]")
        local n = 0
        pcall(function()
            cls:ForEachProperty(function(p)
                n = n + 1
                pcall(function()
                    local pn; pcall(function() pn = p:GetFName():ToString() end)
                    if not pn then w("     <unnamed>"); return end
                    local kind = kind_of(p)
                    w("     " .. pn .. "  [" .. kind .. "]")   -- breadcrumb first
                    if REF[kind] then w("         <ref>"); return end
                    local v, got = nil, false
                    got = pcall(function() v = obj[pn] end)
                    if not got then w("         <read error>")
                    else w("         = " .. render(v)) end
                end)
                return false
            end)
        end)
        if n == 0 then w("     (none)") end
        local nxt; pcall(function() nxt = cls:GetSuperStruct() end)
        cls = nxt
    end
end

local function dump_funcs(obj, label)
    local seen, out = {}, {}
    local cls; pcall(function() cls = obj:GetClass() end)
    local guard = 0
    while cls and guard < 12 do
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
    table.sort(out)
    w("  all functions on " .. label .. " (" .. #out .. "):")
    for _, f in ipairs(out) do w("     " .. f) end
end

local function run(tag)
    w("")
    w("################ DISpec v2 UNFILTERED " .. tag .. " ################")
    for _, cn in ipairs(TARGETS) do
        w("")
        w("======== " .. cn)
        local objs; pcall(function() objs = FindAllOf(cn) end)
        local total = objs and #objs or 0
        w("   instances: " .. total)
        for i = 1, math.min(total, 1) do
            local o = objs[i]
            local isc = false; pcall(function() isc = o:IsAnyClass() end)
            if not isc then
                pcall(dump_funcs, o, cn)
                pcall(dump_obj, o, cn .. " #" .. i)
            end
        end
    end
    w("")
    w("################ END " .. tag .. " ################")
    print("[DISpec] v2 " .. tag .. " done -> " .. OUT .. "\n")
end

-- Two passes: one during agent select, one in-match. bIsSpectator may only be
-- meaningful once the player has actually been given a pawn.
ExecuteWithDelay(75000,  function() pcall(run, "t+75s")  end)
ExecuteWithDelay(200000, function() pcall(run, "t+200s") end)
print("[DISpec] v2 loaded - unfiltered probes at t+75s and t+200s\n")
