-- DIFree: catch the spectator pawn while it actually exists.
--
-- Every earlier probe reported DISpectatorPawn x0 and DIFreeSpectator x0,
-- because they only ran while everyone was alive. Death-spectate creates them.
-- This polls until they appear, then dumps them once - properties, functions
-- and the whole class chain.
--
-- What we are hunting: the spectator pawn clearly has camera MODES
-- ("ShowUserInterface received a request for an unknown mode", "registering 3P
-- camera" / "unregistering 1P camera"), and ADIFreeSpectator is a separate
-- class from ADISpectatorPawn. The death flow puts you in the follow-a-player
-- mode; free roam is a different one. If the mode is a reflected property or a
-- callable function, we can switch it.
--
-- Read-only. Output: Win64/DIFree_dump.txt
local OUT = "DIFree_dump.txt"

local WATCH = {
    "DISpectatorPawn",
    "DIFreeSpectator",
    "SpectatorPawn",
    "SpectatorManager",
    "AutoSpectateAIComponent",
    "SpyCheatsComponent",
    "DeceiveIncCheatManager",
    "BP_DeceiveIncCheatManager_C",
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
                    if not pn then return end
                    local kind = kind_of(p)
                    w("     " .. pn .. "  [" .. kind .. "]")
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
                    if fn and not seen[fn] then seen[fn] = true; out[#out+1] = n .. "::" .. fn end
                end)
                return false
            end)
        end)
        local nxt; pcall(function() nxt = cls:GetSuperStruct() end)
        cls = nxt
    end
    table.sort(out)
    w("  functions (" .. #out .. "):")
    for _, f in ipairs(out) do w("     " .. f) end
end

-- Dump each class the first time it appears, then stop watching it, so a long
-- spectate does not produce hundreds of identical dumps.
local done = {}

local function poll()
    for _, cn in ipairs(WATCH) do
        if not done[cn] then
            local objs; pcall(function() objs = FindAllOf(cn) end)
            local total = objs and #objs or 0
            if total > 0 then
                done[cn] = true
                w("")
                w("######## " .. cn .. " APPEARED  x" .. total .. " ########")
                for i = 1, math.min(total, 2) do
                    local o = objs[i]
                    local isc = false; pcall(function() isc = o:IsAnyClass() end)
                    if not isc then
                        if i == 1 then pcall(dump_funcs, o, cn) end
                        pcall(dump_obj, o, cn .. " #" .. i)
                    end
                end
                print("[DIFree] captured " .. cn .. " x" .. total .. "\n")
            end
        end
    end
end

w("")
w("################ DIFree session start ################")
LoopAsync(3000, function()
    pcall(poll)
    return false
end)
print("[DIFree] loaded - polling every 3s for spectator objects. Join, deploy, die.\n")
