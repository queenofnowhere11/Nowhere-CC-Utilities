-- Aeronautics PID Controller v2.0.1
-- Height controller using Create: Avionics and CC: Redstone Link Bridge

local VERSION        = "2.0.1"
local CONFIG_PATH    = fs.getDir(shell.getRunningProgram()) .. "/config.json"
local DEFAULT_KP     = 2.0
local DEFAULT_KI     = 0.05
local DEFAULT_KD     = 0.0
local LOOP_INTERVAL  = 0.1
local INTEGRAL_CLAMP = 100
local MAX_HISTORY    = 200

local history = {}

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

local function ffOutput(targetY, equilMap)
    if not equilMap or #equilMap < 2 then return 0 end
    table.sort(equilMap, function(a, b) return a.height < b.height end)
    local n = #equilMap
    if targetY <= equilMap[1].height then
        local slope = (equilMap[2].output - equilMap[1].output) /
                      (equilMap[2].height - equilMap[1].height)
        return clamp(equilMap[1].output + slope * (targetY - equilMap[1].height), 0, 15)
    end
    if targetY >= equilMap[n].height then
        local slope = (equilMap[n].output - equilMap[n-1].output) /
                      (equilMap[n].height - equilMap[n-1].height)
        return clamp(equilMap[n].output + slope * (targetY - equilMap[n].height), 0, 15)
    end
    for i = 1, n - 1 do
        if equilMap[i].height <= targetY and equilMap[i+1].height >= targetY then
            local t = (targetY - equilMap[i].height) / (equilMap[i+1].height - equilMap[i].height)
            return equilMap[i].output + t * (equilMap[i+1].output - equilMap[i].output)
        end
    end
    return 0
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

local function pushHistory(actual, target)
    history[#history + 1] = { actual = actual, target = target }
    if #history > MAX_HISTORY then
        table.remove(history, 1)
    end
end

--------------------------------------------------------------------------------
-- Display
--------------------------------------------------------------------------------

local function drawHeader(title)
    term.setCursorPos(1, 1)
    fg(colours.black); bg(colours.cyan)
    writePadded(" " .. (title or ("Aeronautics PID Controller v" .. VERSION)))
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
    local ff = ffOutput(targetY, cfg.equilMap)
    row(5, "PID output:     ", string.format("%d/15  (ff:%.1f)", output, ff))
    row(6, "Error:          ", string.format("%.2f", err))

    term.setCursorPos(1, 8)
    fg(colours.lightGrey)
    local invTag = cfg.invertInput and "  [INV]" or ""
    term.write(string.format("Kp=%.2f  Ki=%.3f  Kd=%.2f%s", cfg.kp, cfg.ki, cfg.kd, invTag))
    resetColors()

    drawFooter("[Q] Quit  [R] Config  [C] Calibrate")
end

--------------------------------------------------------------------------------
-- Monitor graph
--------------------------------------------------------------------------------

local function drawGraph(mon, cfg)
    if not mon then return end

    local mW, mH = mon.getSize()
    mon.setTextScale(0.5)
    mW, mH = mon.getSize()

    local isMonColor = mon.isColour()
    mon.setBackgroundColour(colours.black)
    mon.clear()

    -- visible Y range: minHeight/maxHeight with 10% padding
    local range  = cfg.maxHeight - cfg.minHeight
    local pad    = range * 0.1
    local loY    = cfg.minHeight - pad
    local hiY    = cfg.maxHeight + pad

    local function heightToRow(h)
        local frac = (h - loY) / (hiY - loY)
        return mH - math.floor(frac * (mH - 1))
    end

    -- draw min/max height labels on right edge
    local maxLabel = tostring(math.floor(cfg.maxHeight))
    local minLabel = tostring(math.floor(cfg.minHeight))
    if isMonColor then mon.setTextColour(colours.lightGrey) end
    mon.setCursorPos(mW - #maxLabel + 1, 1)
    mon.write(maxLabel)
    mon.setCursorPos(mW - #minLabel + 1, mH)
    mon.write(minLabel)

    -- draw the last mW samples (one per column)
    local graphW = mW - #maxLabel
    local start  = math.max(1, #history - graphW + 1)

    for i = start, #history do
        local col    = i - start + 1
        local sample = history[i]

        local actualRow = clamp(heightToRow(sample.actual), 1, mH)
        local targetRow = clamp(heightToRow(sample.target), 1, mH)

        if actualRow == targetRow then
            if isMonColor then mon.setTextColour(colours.white)
            else mon.setTextColour(colours.white) end
            mon.setCursorPos(col, actualRow)
            mon.write("*")
        else
            -- actual height
            if isMonColor then mon.setTextColour(colours.yellow) end
            mon.setCursorPos(col, actualRow)
            mon.write(isMonColor and "*" or "+")
            -- target height
            if isMonColor then mon.setTextColour(colours.cyan) end
            mon.setCursorPos(col, targetRow)
            mon.write(isMonColor and "*" or "-")
        end
    end

    if isMonColor then mon.setTextColour(colours.white) end
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
    print("-- Input Direction --")
    local inv = prompt("Invert? 15=MinHeight (y/n)", e.invertInput and "y" or "n")
    cfg.invertInput = (inv == "y" or inv == true)

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

term.clear()
drawHeader()
term.setCursorPos(1, 3)
print("  Starting v" .. VERSION .. "...")

local altSensor = peripheral.find("altitude_sensor")
if not altSensor then
    term.setCursorPos(1, 5)
    printError("  No altitude_sensor peripheral found.")
    print("  Place a Create: Avionics Altitude Sensor adjacent to this computer.")
    sleep(5)
    return
end

local bridge = peripheral.find("redstone_link_bridge")
if not bridge then
    term.setCursorPos(1, 5)
    printError("  No redstone_link_bridge peripheral found.")
    print("  Place a CC Redstone Link Bridge adjacent to this computer.")
    sleep(5)
    return
end

--------------------------------------------------------------------------------
-- Auto-calibration (relay feedback / Ziegler-Nichols)
--------------------------------------------------------------------------------

local function runCalibration(cfg)
    local MAX_RELAY_DURATION = 60
    local MIN_CYCLES         = 3
    local DEADBAND           = 0.5

    local targetY = (cfg.minHeight + cfg.maxHeight) / 2

    -- Phase A: Instructions
    term.clear()
    drawHeader("Auto-Calibration")
    term.setCursorPos(1, 3)
    resetColors()
    print("  Relay feedback test (Ziegler-Nichols method)")
    print("")
    print("  Phase 1: Sweeps output levels to find the")
    print("           equilibrium bracket for target height.")
    print("           The aircraft will move -- allow space.")
    print("")
    print("  Phase 2: Oscillates around target height for")
    print("           up to " .. MAX_RELAY_DURATION .. " seconds to measure response.")
    print("")
    fg(colours.yellow)
    print("  Test height: " .. string.format("%.1f", targetY))
    resetColors()
    print("")
    drawFooter("[Enter] Begin  [Q] Cancel")
    while true do
        local _, key = os.pullEvent("key")
        if key == keys.enter then break
        elseif key == keys.q then return nil end
    end

    -- Phase B: Bracket search
    local relayLow   = nil
    local relayHigh  = nil
    local abortFlag  = false
    local searchFail = false
    local equilData  = {}

    local function drawBracketStatus(output, currentY, velocityY, stableCount)
        term.clear()
        drawHeader("Finding Hover Point...")
        local function row(r, label, val)
            term.setCursorPos(1, r)
            fg(colours.lightGrey); term.write(label); resetColors()
            term.write(tostring(val))
        end
        row(3, "Test output:    ", output .. "/15")
        row(4, "Current height: ", string.format("%.2f", currentY))
        row(5, "Velocity:       ", string.format("%.2f", velocityY) .. " b/s")
        row(6, "Target height:  ", string.format("%.2f", targetY))
        row(7, "Stable for:     ", string.format("%.0f/10 s", stableCount * LOOP_INTERVAL))
        drawFooter("[Q] Abort")
    end

    local function bracketSearch()
        local output    = 8
        local prevEquil = nil
        local prevOut   = nil
        local searchDir = nil

        while not abortFlag do
            bridge.sendLinkSignal(cfg.outFreq1, cfg.outFreq2, output)

            local stableCount = 0
            while stableCount < 100 and not abortFlag do
                local currentY  = altSensor.getHeight()
                local velocityY = altSensor.getVerticalSpeed()
                if math.abs(velocityY) < 0.5 then
                    stableCount = stableCount + 1
                else
                    stableCount = 0
                end
                if currentY < cfg.minHeight - 10 or currentY > cfg.maxHeight + 10 then
                    abortFlag = true; break
                end
                pushHistory(currentY, targetY)
                drawBracketStatus(output, currentY, velocityY, stableCount)
                drawGraph(peripheral.find("monitor"), cfg)
                sleep(LOOP_INTERVAL)
            end
            if abortFlag then break end

            local equilY = altSensor.getHeight()
            equilData[#equilData + 1] = { output = output, height = equilY }

            if searchDir == nil then
                searchDir = equilY > targetY and -1 or 1
            end

            if prevEquil ~= nil then
                local crossed = (prevEquil < targetY and equilY >= targetY)
                             or (prevEquil > targetY and equilY <= targetY)
                if crossed then
                    if prevEquil < targetY then
                        relayLow = prevOut; relayHigh = output
                    else
                        relayLow = output;  relayHigh = prevOut
                    end
                    break
                end
            end

            prevEquil = equilY
            prevOut   = output
            output    = output + searchDir

            if output < 0 or output > 15 then
                searchFail = true; break
            end
        end
    end

    local function abortListener1()
        while not abortFlag do
            local _, key = os.pullEvent("key")
            if key == keys.q then abortFlag = true end
        end
    end

    parallel.waitForAny(bracketSearch, abortListener1)
    bridge.sendLinkSignal(cfg.outFreq1, cfg.outFreq2, 0)

    if not abortFlag and not searchFail and #equilData >= 2 then
        cfg.equilMap = equilData
        saveConfig(cfg)
    end

    local function failScreen(msg)
        term.clear()
        drawHeader("Calibration Failed")
        term.setCursorPos(1, 3)
        resetColors()
        print(msg)
        drawFooter("Press any key to return")
        os.pullEvent("key")
    end

    if abortFlag  then return nil end
    if searchFail then
        failScreen("  Target height unreachable with available outputs.\n  Adjust min/max height range or move aircraft.")
        return nil
    end

    local RELAY_AMP = (relayHigh - relayLow) / 2  -- 0.5 for adjacent integer outputs

    -- Phase C: Relay test
    local startTime  = os.epoch("utc") / 1000
    local peaks      = {}
    local troughs    = {}
    local prevY      = nil
    local direction  = 0
    local relayOut   = relayHigh
    local calibAbort = false
    local safetyFail = false

    local function relayLoop()
        while true do
            local elapsed  = os.epoch("utc") / 1000 - startTime
            local currentY = altSensor.getHeight()

            if currentY < targetY - 60 or currentY > targetY + 60 then
                safetyFail = true; break
            end

            relayOut = (currentY < targetY) and relayHigh or relayLow
            bridge.sendLinkSignal(cfg.outFreq1, cfg.outFreq2, relayOut)

            if prevY ~= nil then
                if direction == 0 then
                    if     currentY > prevY + 0.01 then direction =  1
                    elseif currentY < prevY - 0.01 then direction = -1
                    end
                elseif direction == 1 and currentY < prevY - 0.01 then
                    if prevY > targetY + DEADBAND then
                        peaks[#peaks + 1] = { height = prevY, time = elapsed }
                    end
                    direction = -1
                elseif direction == -1 and currentY > prevY + 0.01 then
                    if prevY < targetY - DEADBAND then
                        troughs[#troughs + 1] = { height = prevY, time = elapsed }
                    end
                    direction = 1
                end
            end
            prevY = currentY

            pushHistory(currentY, targetY)

            local cycles = math.min(#peaks, #troughs)
            term.clear()
            drawHeader("Calibrating...")
            local function row(r, label, val)
                term.setCursorPos(1, r)
                fg(colours.lightGrey); term.write(label); resetColors()
                term.write(tostring(val))
            end
            row(3, "Current height: ", string.format("%.2f", currentY))
            row(4, "Target height:  ", string.format("%.2f", targetY))
            row(5, "Relay output:   ", relayOut .. "/15  (" .. relayLow .. "/" .. relayHigh .. ")")
            row(6, "Cycles:         ", cycles .. "/" .. MIN_CYCLES)
            row(7, "Time remaining: ", string.format("%.0f s", MAX_RELAY_DURATION - elapsed))
            drawFooter("[Q] Abort")
            drawGraph(peripheral.find("monitor"), cfg)

            if cycles >= MIN_CYCLES then break end
            if elapsed >= MAX_RELAY_DURATION then break end
            sleep(LOOP_INTERVAL)
        end
    end

    local function abortListener2()
        while not calibAbort do
            local _, key = os.pullEvent("key")
            if key == keys.q then calibAbort = true end
        end
    end

    parallel.waitForAny(relayLoop, abortListener2)
    bridge.sendLinkSignal(cfg.outFreq1, cfg.outFreq2, 0)

    if calibAbort then return nil end
    if safetyFail then
        failScreen("  Aircraft drifted more than 60 blocks from test height.\n  Try adjusting min/max height range.")
        return nil
    end

    local cycles = math.min(#peaks, #troughs)
    if cycles < MIN_CYCLES then
        failScreen("  Not enough oscillation detected (" .. cycles .. "/" .. MIN_CYCLES .. " cycles).\n\n  - Check thruster connection to output frequency\n  - Try a different target height")
        return nil
    end

    -- Phase D: Analysis
    local peakSum, troughSum = 0, 0
    for _, p in ipairs(peaks)   do peakSum   = peakSum   + p.height end
    for _, t in ipairs(troughs) do troughSum = troughSum + t.height end
    local a = (peakSum / #peaks - troughSum / #troughs) / 2

    local periodSum = 0
    for i = 2, #peaks do periodSum = periodSum + (peaks[i].time - peaks[i-1].time) end
    local Tu = periodSum / (#peaks - 1)

    if a < 0.1 then
        failScreen("  Oscillation amplitude too small (a=" .. string.format("%.3f", a) .. ").\n  System may not be responding to relay control.")
        return nil
    end

    local Ku = (4 / math.pi) * RELAY_AMP / a

    local options = {
        { label = "Classic     ", kp = 0.6  * Ku, ki = 1.2  * Ku / Tu, kd = 0.075 * Ku * Tu },
        { label = "Conservative", kp = 0.33 * Ku, ki = 0.66 * Ku / Tu, kd = 0.11  * Ku * Tu },
    }
    for _, o in ipairs(options) do
        o.kp = clamp(o.kp, 0, 100)
        o.ki = clamp(o.ki, 0, 100)
        o.kd = clamp(o.kd, 0, 100)
    end

    -- Phase E: Results
    local sel = 1
    while true do
        term.clear()
        drawHeader("Calibration Results")
        term.setCursorPos(1, 3)
        resetColors()
        print(string.format("  Ku=%.3f  Tu=%.2fs  Amplitude=%.2f", Ku, Tu, a))
        print(string.format("  Relay: %d / %d", relayLow, relayHigh))
        print("")
        for i, opt in ipairs(options) do
            term.setCursorPos(1, 6 + (i - 1) * 2)
            local line = string.format("  [%d] %s  Kp=%.3f  Ki=%.4f  Kd=%.3f",
                i, opt.label, opt.kp, opt.ki, opt.kd)
            if isColor and sel == i then
                fg(colours.black); bg(colours.white)
                writePadded(line)
            else
                term.write((not isColor and sel == i) and (">" .. line:sub(2)) or line)
            end
            resetColors()
        end
        drawFooter("[1/2] Select  [Enter] Apply  [Q] Discard")

        local _, key = os.pullEvent("key")
        if     key == keys.one                     then sel = 1
        elseif key == keys.two                     then sel = 2
        elseif key == keys.up or key == keys.down  then sel = sel == 1 and 2 or 1
        elseif key == keys.enter then
            cfg.kp = options[sel].kp
            cfg.ki = options[sel].ki
            cfg.kd = options[sel].kd
            saveConfig(cfg)
            return cfg
        elseif key == keys.q then
            return nil
        end
    end
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
        local frac      = cfg.invertInput and (1 - rawSignal / 15) or (rawSignal / 15)
        local targetY   = cfg.minHeight + frac * (cfg.maxHeight - cfg.minHeight)

        if lastTarget and math.abs(targetY - lastTarget) > 5 then
            integral = 0
        end
        lastTarget = targetY

        local err       = targetY - currentY
        integral        = clamp(integral + err * LOOP_INTERVAL, -INTEGRAL_CLAMP, INTEGRAL_CLAMP)
        local velocityY = altSensor.getVerticalSpeed()
        local ff        = ffOutput(targetY, cfg.equilMap)
        local outputF   = ff + cfg.kp * err + cfg.ki * integral + cfg.kd * (-velocityY)
        local output    = clamp(math.floor(outputF + 0.5), 0, 15)

        bridge.sendLinkSignal(cfg.outFreq1, cfg.outFreq2, output)
        pushHistory(currentY, targetY)
        drawStatus(currentY, targetY, rawSignal, output, err, cfg)
        drawGraph(peripheral.find("monitor"), cfg)

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
        elseif key == keys.c then
            action = "calibrate"
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
        history = {}
        resetPID()
    elseif action == "calibrate" then
        local newCfg = runCalibration(cfg)
        if newCfg then cfg = newCfg end
        history = {}
        resetPID()
    end
end
