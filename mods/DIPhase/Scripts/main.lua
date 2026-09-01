-- DIPhase v2: read-only, EXHAUSTIVE property dump.
--
-- v1 under-reported badly: an error thrown inside a ForEachProperty callback
-- escapes and aborts the whole iteration, so we only ever saw properties up to
-- the first awkward one. Every callback body here is individually pcall'd and
-- always returns false, so one bad property can no longer hide the rest.
local OUT = "DIPhase_dump.txt"
local lines = {}
local function w(s) s = tostring(s); print("[DIPhase] " .. s .. "\n"); lines[#lines+1] = s end
local function flush()
    pcall(function()
        local fh = io.open(OUT, "a")
        if fh then fh:write(table.concat(lines, "\n") .. "\n"); fh:close() end
    end)
    lines = {}
end

local function val(v)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
    if t == "userdata" then
        local ok, s = pcall(function() return v:ToString() end)
        if ok and type(s) == "string" then return s end
        local ok2, n = pcall(function() return v:GetFullName() end)
        if ok2 and n then return n end
    end
    return "<" .. t .. ">"
end

local dump_struct

local function handle_prop(owner, p, indent, depth)
    local n
    if not pcall(function() n = p:GetFName():ToString() end) or not n then
        w(indent .. "<unnamed property>")
        return
    end

    local v, got = nil, false
    got = pcall(function() v = owner[n] end)
    if not got then w(indent .. n .. " = <read error>"); return end
    if v == nil then w(indent .. n .. " = <nil>"); return end

    local isstruct, isarray = false, false
    pcall(function() isstruct = p:IsA(PropertyTypes.StructProperty) end)
    pcall(function() isarray = p:IsA(PropertyTypes.ArrayProperty) end)

    if isstruct and depth < 4 then
        w(indent .. n .. ":")
        local inner
        pcall(function() inner = p:GetStruct() end)
        if inner then dump_struct(v, inner, indent .. "    ", depth + 1) end
    elseif isarray then
        local cnt = 0
        pcall(function() cnt = v:GetArrayNum() end)
        w(indent .. n .. ":  (" .. cnt .. " entries)")
        local innerp, inners
        pcall(function() innerp = p:GetInner() end)
        if innerp then pcall(function()
            if innerp:IsA(PropertyTypes.StructProperty) then inners = innerp:GetStruct() end
        end) end
        if depth < 4 then
            for i = 1, math.min(cnt, 12) do
                local e
                if pcall(function() e = v[i] end) and e ~= nil then
                    if inners then
                        w(indent .. "  [" .. i .. "]")
                        dump_struct(e, inners, indent .. "      ", depth + 1)
                    else
                        w(indent .. "  [" .. i .. "] " .. val(e))
                    end
                end
            end
        end
    else
        w(indent .. n .. " = " .. val(v))
    end
end

local function dump_own(owner, struct, indent, depth)
    local count = 0
    pcall(function()
        struct:ForEachProperty(function(p)
            count = count + 1
            pcall(handle_prop, owner, p, indent, depth)   -- never let it escape
            return false
        end)
    end)
    if count == 0 then w(indent .. "(no properties)") end
end

dump_struct = function(v, s, indent, depth)
    if v and s and depth <= 4 then dump_own(v, s, indent, depth) end
end

local function dump_chain(obj, label)
    local full; pcall(function() full = obj:GetFullName() end)
    w("")
    w("### " .. label .. " :: " .. tostring(full))
    local cls; pcall(function() cls = obj:GetClass() end)
    local guard = 0
    while cls and guard < 8 do
        guard = guard + 1
        local cn; pcall(function() cn = cls:GetFName():ToString() end)
        if not cn or cn == "Object" or cn == "Actor" then break end
        w("  [" .. cn .. "]")
        dump_own(obj, cls, "    ", 1)
        local nxt; pcall(function() nxt = cls:GetSuperStruct() end)
        cls = nxt
    end
end

local TARGETS = { "PregameLobbyMapData", "SpyGameModeMapData",
                  "DeceiveIncMatchGameState", "MapData" }

local function snap(tag)
    w("")
    w("======== " .. tag .. " ========")
    for _, cn in ipairs(TARGETS) do
        local objs; pcall(function() objs = FindAllOf(cn) end)
        local n = objs and #objs or 0
        w("")
        w("---- " .. cn .. " x" .. n)
        for i = 1, n do
            local o = objs[i]
            local isc = false; pcall(function() isc = o:IsAnyClass() end)
            if not isc then
                pcall(dump_chain, o, cn)
                if cn ~= "SpyGameModeMapData" then break end   -- all map variants
            end
        end
    end
end

ExecuteWithDelay(20000, function() pcall(snap, "t+20s"); flush() end)
print("[DIPhase] v2 loaded\n")
