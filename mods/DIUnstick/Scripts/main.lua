-- DIUnstick: make the tutorial map traversable by removing the scripted
-- sliding doors that the (absent) tutorial flow would normally open.
--
-- Uses only stock AActor engine functions, one door at a time, logging
-- before each call so a crash identifies the exact culprit.
--
-- DIConfig.ini:
--   [Tutorial]
--   OpenTutorialDoors = 1

local cfg = {}
local function log(s) print("[DIUnstick] " .. tostring(s) .. "\n") end

local function load_ini()
    local fh = io.open("DIConfig.ini", "r")
    if not fh then return end
    for line in fh:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*([^;]+)")
        if k and v then cfg[k] = tonumber((v:gsub("%s+$", ""))) or v end
    end
    fh:close()
end

local done = false

local function unstick()
    if done then return end
    local doors
    local ok = pcall(function() doors = FindAllOf("BP_Tutorial_SlidingDoor_C") end)
    if not ok or not doors or #doors == 0 then return end

    log("found " .. #doors .. " tutorial sliding doors")
    local opened = 0
    for i = 1, #doors do
        local d = doors[i]
        local nm = "?"
        pcall(function() nm = d:GetFullName():match("([^%.]+)$") or "?" end)

        -- log BEFORE the call: if the server dies, the log names the door
        log("  [" .. i .. "/" .. #doors .. "] disabling collision on " .. nm)
        local c = pcall(function() d:SetActorEnableCollision(false) end)
        log("      collision " .. (c and "ok" or "FAILED"))

        log("  [" .. i .. "] hiding " .. nm)
        local h = pcall(function() d:SetActorHiddenInGame(true) end)
        log("      hidden " .. (h and "ok" or "FAILED"))

        if c or h then opened = opened + 1 end
    end
    log("done: " .. opened .. "/" .. #doors .. " doors neutralised")
    done = true
end

load_ini()
if cfg.OpenTutorialDoors == 1 then
    log("OpenTutorialDoors enabled; will run once the map is up")
    ExecuteWithDelay(25000, function() pcall(unstick) end)
    LoopAsync(20000, function() pcall(unstick); return false end)
else
    log("OpenTutorialDoors not set; idle")
end
