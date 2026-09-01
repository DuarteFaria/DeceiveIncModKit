-- DISession: find where the advertised slot count lives.
--
-- With all five constant sites patched in memory the match cap is genuinely 12
-- (FactionPlan: TeamSize:1 NumTeams:12 MaxPlayers:12), but the server still
-- advertises 8:
--
--   EOS_SessionModification_AddAttribute() named (NumPublicConnections) with value (8)
--
-- That number is not a constant in the code - it tracks the cap for Duo (10) -
-- so it is a runtime field. TripwireDedicatedServerManager holds an EOSSession
-- object reference we never followed, and DIGameServerSession exists in the
-- object graph. The session re-publishes its attributes every ~30s, so a
-- writable field here would reach the browser on the next refresh.
--
-- This dumps those objects fully, INCLUDING object references (unlike earlier
-- probes, where refs were left unread) since following EOSSession is the whole
-- point.
--
-- Read-only. Output: Win64/DISession_dump.txt
local OUT = "DISession_dump.txt"

local TARGETS = {
    "DIGameServerSession",
    "TripwireDedicatedServerManager",
    "DIDedicatedServerManager",
    "EOSServerSession",
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

local function render(v)
    local t = type(v)
    if v == nil then return "<nil>" end
    if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
    if t == "userdata" then
        local ok, s = pcall(function() return v:ToString() end)
        if ok and type(s) == "string" and s ~= "" then return s end
        local ok2, n = pcall(function() return v:GetFullName() end)
        if ok2 and type(n) == "string" and n ~= "" then return n end
        return "<userdata>"
    end
    return "<" .. t .. ">"
end

local STOP = { Object = true, ["None"] = true }
local dump_obj

-- follow object references one level deep, so EOSSession is actually opened
local function dump_props(obj, cls_name, indent, depth, seen)
    local cls; pcall(function() cls = obj:GetClass() end)
    local guard = 0
    while cls and guard < 12 do
        guard = guard + 1
        local cn; pcall(function() cn = cls:GetFName():ToString() end)
        if not cn or STOP[cn] then break end
        w(indent .. "[" .. cn .. "]")
        local n = 0
        pcall(function()
            cls:ForEachProperty(function(p)
                n = n + 1
                pcall(function()
                    local pn; pcall(function() pn = p:GetFName():ToString() end)
                    if not pn then return end
                    local kind = kind_of(p)
                    w(indent .. "  " .. pn .. "  [" .. kind .. "]")
                    local v, got = nil, false
                    got = pcall(function() v = obj[pn] end)
                    if not got then w(indent .. "      <read error>"); return end
                    if v == nil then w(indent .. "      = <nil>"); return end
                    w(indent .. "      = " .. render(v))
                    -- descend into a referenced UObject exactly once
                    if kind == "ObjectProperty" and depth < 2 then
                        local full
                        pcall(function() full = v:GetFullName() end)
                        if full and not seen[full] then
                            seen[full] = true
                            local valid = true
                            pcall(function() valid = v:IsValid() end)
                            if valid then
                                w(indent .. "      -> descending into " .. pn)
                                pcall(dump_props, v, pn, indent .. "        ",
                                      depth + 1, seen)
                            end
                        end
                    end
                end)
                return false
            end)
        end)
        if n == 0 then w(indent .. "  (none)") end
        local nxt; pcall(function() nxt = cls:GetSuperStruct() end)
        cls = nxt
    end
end

dump_obj = function(obj, label)
    local full; pcall(function() full = obj:GetFullName() end)
    w("")
    w("--- " .. label .. " :: " .. tostring(full))
    dump_props(obj, label, "  ", 0, {})
end

local function run(tag)
    w("")
    w("################ DISession " .. tag .. " ################")
    for _, cn in ipairs(TARGETS) do
        w("")
        w("======== " .. cn)
        local objs; pcall(function() objs = FindAllOf(cn) end)
        local total = objs and #objs or 0
        w("   instances: " .. total)
        for i = 1, math.min(total, 1) do
            local o = objs[i]
            local isc = false; pcall(function() isc = o:IsAnyClass() end)
            if not isc then pcall(dump_obj, o, cn) end
        end
    end
    w("")
    w("################ END " .. tag .. " ################")
    print("[DISession] " .. tag .. " done -> " .. OUT .. "\n")
end

ExecuteWithDelay(30000, function() pcall(run, "t+30s") end)
print("[DISession] loaded - probe at t+30s (no need to join)\n")
