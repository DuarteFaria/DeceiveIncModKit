-- DIPlayers: find a writable MaxPlayers.
--
-- The server reads MaxPlayers from TripwireServer.ini and then clamps it:
--
--   Init          :: ServerName:Glass Cannon MaxPlayers:10
--   ClampIntSetting :: Name:MaxPlayers Value:10 Clamped:8 Range:1,8
--   BeginServerSession :: MaxPlayers:8
--
-- So the ini is not the lever - the clamp is. Other people run 12-player
-- lobbies, so the limit is not enforced anywhere authoritative; it is just
-- this one clamp at startup.
--
-- The clamp runs during Init, long before UE4SS loads, so we cannot prevent
-- it. But the value it produced is stored on live objects, and the EOS session
-- re-publishes NumPublicConnections every ~30s. If MaxPlayers is writable on
-- any of these, a later write may both raise the login gate and refresh the
-- advertised slot count.
--
-- Phase 1 (this mod) is read-only: find where the 8 lives and whether it is
-- reflected. Writing comes after we can see it.
--
-- Output: Win64/DIPlayers_dump.txt
local OUT = "DIPlayers_dump.txt"

local TARGETS = {
    "TripwireServerSettings",
    "TripwireDedicatedServerManager",
    "DIDedicatedServerManager",
    "DeceiveIncGameSession",
    "GameSession",
    "Tripwire",
    "TripwireTool",
    "DeceiveIncGameStateBase",
    "DIAllowedGameModesHandler",
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

-- Walk to UObject. AGameSession::MaxPlayers is a stock engine property, so
-- stopping at Actor would hide the single most likely answer.
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

local function run(tag)
    w("")
    w("################ DIPlayers " .. tag .. " ################")
    for _, cn in ipairs(TARGETS) do
        w("")
        w("======== " .. cn)
        local objs; pcall(function() objs = FindAllOf(cn) end)
        local total = objs and #objs or 0
        w("   instances: " .. total)
        for i = 1, math.min(total, 2) do
            local o = objs[i]
            local isc = false; pcall(function() isc = o:IsAnyClass() end)
            if not isc then
                if i == 1 then pcall(dump_funcs, o, cn) end
                pcall(dump_obj, o, cn .. " #" .. i)
            end
        end
    end
    w("")
    w("################ END " .. tag .. " ################")
    print("[DIPlayers] " .. tag .. " done -> " .. OUT .. "\n")
end

-- No players needed: these are all server-lifetime objects.
ExecuteWithDelay(25000, function() pcall(run, "t+25s") end)
print("[DIPlayers] loaded - probe at t+25s (no need to join)\n")
