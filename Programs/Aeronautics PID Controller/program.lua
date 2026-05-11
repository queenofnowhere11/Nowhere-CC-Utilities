-- Aeronautics PID Controller v1.0.0
-- Height controller using CC: Sable and CC: Redstone Link Bridge

local CONFIG_PATH    = fs.getDir(shell.getRunningProgram()) .. "/config.json"
local DEFAULT_KP     = 2.0
local DEFAULT_KI     = 0.05
local DEFAULT_KD     = 1.0
local LOOP_INTERVAL  = 0.1
local INTEGRAL_CLAMP = 100

local W, H    = term.getSize()
local isColor = term.isColour()

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

local function fg(c) if isColor then term.setTextColour(c) end end
local function bg(c) if isColor then term.setBackgroundColour(c) end end
local function resetColors()
    if isColor then
        term.setTextColour(colours.white)
        term.setBackgroundColour(colours.black)
    end
end

local function writePadded(text)
    local s = tostring(text)
    local pad = W - #s
    if pad > 0 then s = s .. string.rep(" ", pad) end
    term.write(s:sub(1, W))
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function loadConfig()
    if not fs.exists(CONFIG_PATH) then return nil end
    local f = fs.open(CONFIG_PATH, "r")
    local data = textutils.unserialiseJSON(f.readAll())
    f.close()
    return data
end

local function saveConfig(cfg)
    local f = fs.open(CONFIG_PATH, "w")
    f.write(textutils.serialiseJSON(cfg))
    f.close()
end

--------------------------------------------------------------------------------
-- Display
--------------------------------------------------------------------------------

local function drawHeader(title)
    term.setCursorPos(1, 1)
    fg(colours.black); bg(colours.cyan)
    writePadded(" " .. (title or "Aeronautics PID Controller"))
    resetColors()
end

local function drawFooter(text)
    term.setCursorPos(1, H)
    fg(colours.black); bg(colours.lightGrey)
    writePadded(" " .. (text or ""))
    resetColors()
end

local function drawStatus(currentY, targetY, rawSignal, output, err, cfg)
    term.clear()
    drawHeader()

    local function row(r, label, value)
        term.setCursorPos(1, r)
        fg(colours.lightGrey)
        term.write(label)
        resetColors()
        term.write(tostring(value))
    end

    row(3, "Current height: ", string.format("%.2f", currentY))
    row(4, "Target height:  ", string.format("%.2f  (signal: %d/15)", targetY, rawSignal))
    row(5, "PID output:     ", output .. "/15")
    row(6, "Error:          ", string.format("%.2f", err))

    term.setCursorPos(1, 8)
    fg(colours.lightGrey)
    term.write(string.format("Kp=%.2f  Ki=%.3f  Kd=%.2f", cfg.kp, cfg.ki, cfg.kd))
    resetColors()

    drawFooter("[Q] Quit   [R] Reconfigure")
end

--------------------------------------------------------------------------------
-- Setup wizard
--------------------------------------------------------------------------------

local function prompt(label, default)
    if default ~= nil and default ~= "" then
        term.write(label .. " [" .. tostring(default) .. "]: ")
    else
        term.write(label .. ": ")
    end
    local input = read()
    if input == "" then return default end
    local n = tonumber(input)
    return n ~= nil and n or input
end

local function runSetup(existing)
    term.clear()
    drawHeader("PID Controller Setup")
    term.setCursorPos(1, 3)
    resetColors()

    local e = existing or {}
    local cfg = {}

    print("-- Height Range --")
    cfg.minHeight = prompt("Min height", e.minHeight or 60)
    cfg.maxHeight = prompt("Max height", e.maxHeight or 120)

    print("")
    print("-- Input Frequency (receives target signal) --")
    cfg.inFreq1 = prompt("Input freq1 (item ID)", e.inFreq1 or "")
    cfg.inFreq2 = prompt("Input freq2 (item ID)", e.inFreq2 or "")

    print("")
    print("-- Output Frequency (sends thrust signal) --")
    cfg.outFreq1 = prompt("Output freq1 (item ID)", e.outFreq1 or "")
    cfg.outFreq2 = prompt("Output freq2 (item ID)", e.outFreq2 or "")

    print("")
    print("-- PID Gains --")
    cfg.kp = prompt("Kp", e.kp or DEFAULT_KP)
    cfg.ki = prompt("Ki", e.ki or DEFAULT_KI)
    cfg.kd = prompt("Kd", e.kd or DEFAULT_KD)

    saveConfig(cfg)
    return cfg
end

--------------------------------------------------------------------------------
-- Startup checks
--------------------------------------------------------------------------------

if not sublevel then
    term.clear()
    term.setCursorPos(1, 1)
    printError("sublevel API not available.")
    print("Is this computer on a Sub-Level (physics object)?")
    print("Press any key to exit.")
    os.pullEvent("key")
    return
end

local bridge = peripheral.find("redstone_link_bridge")
if not bridge then
    term.clear()
    term.setCursorPos(1, 1)
    printError("No redstone_link_bridge peripheral found.")
    print("Place a CC Redstone Link Bridge adjacent to this computer.")
    print("Press any key to exit.")
    os.pullEvent("key")
    return
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

local cfg = loadConfig()
if not cfg then
    cfg = runSetup(nil)
end

local integral   = 0
local lastTarget = nil

local function resetPID()
    integral   = 0
    lastTarget = nil
end

resetPID()

local action = nil

local function controlLoop()
    while not action do
        local pose     = sublevel.getLogicalPose()
        local currentY = pose.position.y

        local rawSignal = bridge.getLinkSignal(cfg.inFreq1, cfg.inFreq2)
        local targetY   = cfg.minHeight + (rawSignal / 15) * (cfg.maxHeight - cfg.minHeight)

        if lastTarget and math.abs(targetY - lastTarget) > 5 then
            integral = 0
        end
        lastTarget = targetY

        local err       = targetY - currentY
        integral        = clamp(integral + err * LOOP_INTERVAL, -INTEGRAL_CLAMP, INTEGRAL_CLAMP)
        local velocityY = sublevel.getLinearVelocity().y
        local outputF   = cfg.kp * err + cfg.ki * integral + cfg.kd * (-velocityY)
        local output    = clamp(math.floor(outputF + 0.5), 0, 15)

        bridge.sendLinkSignal(cfg.outFreq1, cfg.outFreq2, output)
        drawStatus(currentY, targetY, rawSignal, output, err, cfg)

        sleep(LOOP_INTERVAL)
    end
end

local function keyListener()
    while not action do
        local _, key = os.pullEvent("key")
        if key == keys.q then
            action = "quit"
        elseif key == keys.r then
            action = "reconfigure"
        end
    end
end

while true do
    action = nil
    parallel.waitForAny(controlLoop, keyListener)

    if action == "quit" then
        bridge.sendLinkSignal(cfg.outFreq1, cfg.outFreq2, 0)
        term.clear()
        term.setCursorPos(1, 1)
        resetColors()
        print("PID Controller stopped. Output set to 0.")
        break
    elseif action == "reconfigure" then
        cfg = runSetup(cfg)
        resetPID()
    end
end
