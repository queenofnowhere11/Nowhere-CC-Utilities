-- Axiom Navigation Systems v1.0.7
-- Navigation control system for the AXIOM airship

local VERSION     = "1.3.3"
local CONFIG_PATH = "ans_config.json"
local PROTOCOL    = "axiom_nav"

local GITHUB_RAW  = "https://raw.githubusercontent.com/queenofnowhere11/Nowhere-CC-Utilities/main/"
local PROGRAM_SRC = "Programs/Axiom Navigation Systems/program.lua"
local SOUNDS_PATH = fs.getDir(shell.getRunningProgram()) .. "/sounds/"

-- AutoNav arrival: horizontal distance threshold in blocks
local ARRIVAL_RADIUS = 15

-- PID control loop
local LOOP_INTERVAL  = 0.1
local INTEGRAL_CLAMP = 100

-- Redstone Link Bridge frequencies
local THROTTLE_F1 = "everycomp:tf/biomeswevegone/hollow_ebony_log"
local THROTTLE_F2 = "simulated:throttle_lever"
local REVERSE_F1  = "everycomp:tf/biomeswevegone/hollow_ebony_log"
local REVERSE_F2  = "minecraft:lever"
local FUEL_F1     = "everycomp:tf/biomeswevegone/hollow_ebony_log"
local FUEL_F2     = "create_connected:fluid_vessel"

-- Height PID: target signal input (inverted: 0=maxHeight, 15=minHeight)
local HEIGHT_F1 = "everycomp:tf/biomeswevegone/hollow_ebony_log"
local HEIGHT_F2 = "dndecor:stepped_lever"

-- Burner outputs
local FRONT_F1 = "everycomp:tf/biomeswevegone/hollow_ebony_log"  -- nose up
local FRONT_F2 = "createdeco:decal_up"
local BACK_F1  = "everycomp:tf/biomeswevegone/hollow_ebony_log"  -- nose down
local BACK_F2  = "createdeco:decal_down"

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

local function loadConfig()
    if not fs.exists(CONFIG_PATH) then return {} end
    local f = fs.open(CONFIG_PATH, "r")
    local raw = f.readAll()
    f.close()
    return textutils.unserialiseJSON(raw) or {}
end

local function saveConfig(cfg)
    local f = fs.open(CONFIG_PATH, "w")
    f.write(textutils.serialiseJSON(cfg))
    f.close()
end

--------------------------------------------------------------------------------
-- PID helpers
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- Display helpers
--------------------------------------------------------------------------------

local W, H = term.getSize()

local function cls()
    term.clear()
    term.setCursorPos(1, 1)
end

local function header(title)
    term.setCursorPos(1, 1)
    if term.isColour() then
        term.setTextColour(colours.black)
        term.setBackgroundColour(colours.cyan)
    end
    local line = " ANS v" .. VERSION .. " | " .. title
    term.write(line .. string.rep(" ", math.max(0, W - #line)))
    if term.isColour() then
        term.setTextColour(colours.white)
        term.setBackgroundColour(colours.black)
    end
end

local function statusLine(row, text)
    term.setCursorPos(1, row)
    term.clearLine()
    term.write(text)
end

local function footer(text)
    term.setCursorPos(1, H)
    if term.isColour() then
        term.setTextColour(colours.black)
        term.setBackgroundColour(colours.lightGrey)
    end
    local line = " " .. text
    term.write(line .. string.rep(" ", math.max(0, W - #line)))
    if term.isColour() then
        term.setTextColour(colours.white)
        term.setBackgroundColour(colours.black)
    end
end

--------------------------------------------------------------------------------
-- Wireless modem
--------------------------------------------------------------------------------

local function openWirelessModem()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local m = peripheral.wrap(name)
            if m and m.isWireless() then
                rednet.open(name)
                return true
            end
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- Module selector
--------------------------------------------------------------------------------

local MODULES = {
    { id = "control",      label = "Control",  desc = "PID height/tilt control + sensor broadcast"   },
    { id = "readout",      label = "Readout",  desc = "Displays flight data on cockpit monitors"      },
    { id = "pilot",        label = "Pilot",    desc = "Reads steering wheel, broadcasts turn values"  },
    { id = "engine",       label = "Engine",   desc = "Controls left and right engine outputs"        },
    { id = "announcement", label = "Announce", desc = "Plays sounds for system events"               },
}

local function getModule(cfg)
    while true do
        if not cfg.module then
            cls()
            header("Module Selection")
            term.setCursorPos(1, 3)
            print("  Select a module for this computer:")
            print("")
            for i, m in ipairs(MODULES) do
                print(string.format("  [%d] %-8s - %s", i, m.label, m.desc))
            end
            print("")
            term.write("  Module (1-" .. #MODULES .. "): ")
            local n = tonumber(read())
            if n and MODULES[n] then
                cfg.module = MODULES[n].id
                saveConfig(cfg)
            end
        else
            local reselect = false

            local function countDown()
                for i = 3, 1, -1 do
                    cls()
                    header("Starting...")
                    term.setCursorPos(1, 3)
                    print("  Module: " .. cfg.module)
                    print("")
                    print("  Starting in " .. i .. " second" .. (i ~= 1 and "s" or "") .. "...")
                    print("  Press any key to change module.")
                    sleep(1)
                end
            end

            local function keyWatch()
                os.pullEvent("key")
                reselect = true
            end

            parallel.waitForAny(countDown, keyWatch)

            if reselect then
                cfg.module = nil
                saveConfig(cfg)
            else
                return cfg.module
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Network restart / update
--------------------------------------------------------------------------------

local function updateAndRestart()
    local myPath = shell.getRunningProgram()
    footer("  Downloading update...")
    if http then
        local url  = (GITHUB_RAW .. PROGRAM_SRC):gsub(" ", "%%20")
        local resp = http.get(url)
        if resp then
            local content = resp.readAll()
            resp.close()
            local f = fs.open(myPath, "w")
            f.write(content)
            f.close()
            footer("  Updated. Rebooting...")
        else
            footer("  Download failed. Rebooting...")
        end
    else
        footer("  HTTP unavailable. Rebooting...")
    end
    sleep(0.5)
    os.reboot()
end

local function restartListener()
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "key" and p1 == keys.u then
            footer("  Sending update to all modules...")
            rednet.broadcast({ type = "ans_restart" }, PROTOCOL)
            sleep(0.2)
            updateAndRestart()
        elseif event == "rednet_message" and p3 == PROTOCOL then
            if type(p2) == "table" and p2.type == "ans_restart" then
                updateAndRestart()
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Module: Control (height + tilt PID + sensor broadcast)
--------------------------------------------------------------------------------

local function runHeightCalibration(cfg, bridge, altSensor)
    local MAX_RELAY_DURATION = 300
    local MIN_CYCLES         = 5
    local DEADBAND           = 0.5
    local targetY = (cfg.minHeight + cfg.maxHeight) / 2

    local function setBurners(v)
        bridge.sendLinkSignal(FRONT_F1, FRONT_F2, v)
        bridge.sendLinkSignal(BACK_F1,  BACK_F2,  v)
    end

    -- Phase A: Instructions
    cls()
    header("Height Calibration")
    term.setCursorPos(1, 3)
    print("  Relay feedback test (Ziegler-Nichols method)")
    print("")
    print("  Phase 1: Sweeps output levels to find the")
    print("           equilibrium bracket for target height.")
    print("           The airship will move -- allow space.")
    print("")
    print("  Phase 2: Oscillates around target height for")
    print("           up to " .. MAX_RELAY_DURATION .. " s to measure response.")
    print("")
    print("  Test height: " .. string.format("%.1f", targetY))
    print("")
    footer("[Enter] Begin  [Q] Cancel")
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

    local function bracketSearch()
        local output    = 8
        local prevEquil = nil
        local prevOut   = nil
        local searchDir = nil

        while not abortFlag do
            setBurners(output)
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
                cls()
                header("Finding Hover Point...")
                statusLine(3, string.format("  Test output: %d/15", output))
                statusLine(4, string.format("  Current alt: %.2f m", currentY))
                statusLine(5, string.format("  Velocity:    %.2f m/s", velocityY))
                statusLine(6, string.format("  Target:      %.2f m", targetY))
                statusLine(7, string.format("  Stable:      %.0f/10 s", stableCount * LOOP_INTERVAL))
                footer("[Q] Abort")
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
            if output < 0 or output > 15 then searchFail = true; break end
        end
    end

    local function abortListener1()
        while not abortFlag do
            local _, key = os.pullEvent("key")
            if key == keys.q then abortFlag = true end
        end
    end

    parallel.waitForAny(bracketSearch, abortListener1)
    setBurners(0)

    if #equilData >= 2 then
        cfg.equilMap = equilData
        saveConfig(cfg)
    end

    local function failScreen(msg)
        cls(); header("Calibration Failed")
        term.setCursorPos(1, 3)
        print(msg)
        footer("Press any key to return")
        os.pullEvent("key")
    end

    if abortFlag  then return nil end
    if searchFail then
        failScreen("  Target height unreachable.\n  Adjust min/max height range.")
        return nil
    end

    local RELAY_AMP = (relayHigh - relayLow) / 2

    -- Phase C: Relay oscillation
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
            setBurners(relayOut)
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
            local cycles = math.min(#peaks, #troughs)
            cls(); header("Calibrating Height...")
            statusLine(3, string.format("  Current alt:    %.2f m", currentY))
            statusLine(4, string.format("  Target alt:     %.2f m", targetY))
            statusLine(5, string.format("  Relay output:   %d/15  (%d/%d)", relayOut, relayLow, relayHigh))
            statusLine(6, string.format("  Cycles:         %d/%d", cycles, MIN_CYCLES))
            statusLine(7, string.format("  Time remaining: %.0f s", MAX_RELAY_DURATION - elapsed))
            footer("[Q] Abort")
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
    setBurners(0)

    if calibAbort  then return nil end
    if safetyFail  then failScreen("  Airship drifted > 60 m from test height."); return nil end

    local cycles = math.min(#peaks, #troughs)
    if cycles < MIN_CYCLES then
        failScreen("  Not enough oscillation (" .. cycles .. "/" .. MIN_CYCLES .. " cycles).\n  Check burner connection.")
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
        failScreen("  Amplitude too small (a=" .. string.format("%.3f", a) .. ").")
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
        cls(); header("Height Cal. Results")
        term.setCursorPos(1, 3)
        print(string.format("  Ku=%.3f  Tu=%.2fs  Amplitude=%.2f", Ku, Tu, a))
        print(string.format("  Relay: %d / %d", relayLow, relayHigh))
        print("")
        for i, opt in ipairs(options) do
            term.setCursorPos(1, 6 + (i - 1) * 2)
            local line = string.format("  [%d] %s  Kp=%.3f  Ki=%.4f  Kd=%.3f",
                i, opt.label, opt.kp, opt.ki, opt.kd)
            if sel == i and term.isColour() then
                term.setTextColour(colours.black)
                term.setBackgroundColour(colours.white)
            end
            term.write(line)
            if term.isColour() then
                term.setTextColour(colours.white)
                term.setBackgroundColour(colours.black)
            end
        end
        footer("[1/2] Select  [Enter] Apply  [Q] Discard")
        local _, key = os.pullEvent("key")
        if     key == keys.one                    then sel = 1
        elseif key == keys.two                    then sel = 2
        elseif key == keys.up or key == keys.down then sel = sel == 1 and 2 or 1
        elseif key == keys.enter then
            cfg.hKp = options[sel].kp
            cfg.hKi = options[sel].ki
            cfg.hKd = options[sel].kd
            saveConfig(cfg)
            return cfg
        elseif key == keys.q then
            return nil
        end
    end
end

local function runTiltCalibration(cfg, bridge, gimbal)
    local MAX_RELAY_DURATION = 120
    local MIN_CYCLES         = 5
    local DEADBAND           = 0.3
    local TILT_RELAY_AMP     = 4.0

    if not cfg.equilMap or #cfg.equilMap < 2 then
        cls(); header("Tilt Calibration")
        term.setCursorPos(1, 3)
        printError("  Run height calibration first.")
        print("  equilMap needed to set base height output.")
        sleep(4)
        return nil
    end

    local midH    = (cfg.minHeight + cfg.maxHeight) / 2
    local equilOut = ffOutput(midH, cfg.equilMap)

    local function applyRelay(r)
        local f = clamp(math.floor(equilOut + r + 0.5), 0, 15)
        local b = clamp(math.floor(equilOut - r + 0.5), 0, 15)
        bridge.sendLinkSignal(FRONT_F1, FRONT_F2, f)
        bridge.sendLinkSignal(BACK_F1,  BACK_F2,  b)
    end

    local function zeroOut()
        bridge.sendLinkSignal(FRONT_F1, FRONT_F2, 0)
        bridge.sendLinkSignal(BACK_F1,  BACK_F2,  0)
    end

    -- Phase A: Instructions
    cls(); header("Tilt Calibration")
    term.setCursorPos(1, 3)
    print("  Relay feedback test for pitch axis.")
    print("")
    print("  Holds base height output and oscillates")
    print("  front/back burners to induce pitch cycles.")
    print("")
    print("  Base height output: " .. string.format("%.1f/15", equilOut))
    print("  Relay amplitude:    +/- " .. TILT_RELAY_AMP)
    print("")
    footer("[Enter] Begin  [Q] Cancel")
    while true do
        local _, key = os.pullEvent("key")
        if key == keys.enter then break
        elseif key == keys.q then return nil end
    end

    -- Phase C: Relay oscillation (no bracket search needed for tilt)
    local startTime  = os.epoch("utc") / 1000
    local peaks      = {}
    local troughs    = {}
    local prevPitch  = nil
    local direction  = 0
    local tiltRelay  = TILT_RELAY_AMP
    local calibAbort = false

    local function relayLoop()
        while true do
            local elapsed = os.epoch("utc") / 1000 - startTime
            local angles  = gimbal.getAngles()
            local raw     = angles[1]
            local pitch   = raw > 180 and raw - 360 or raw

            tiltRelay = (pitch > 0) and -TILT_RELAY_AMP or TILT_RELAY_AMP
            applyRelay(tiltRelay)

            if prevPitch ~= nil then
                if direction == 0 then
                    if     pitch > prevPitch + 0.01 then direction =  1
                    elseif pitch < prevPitch - 0.01 then direction = -1
                    end
                elseif direction == 1 and pitch < prevPitch - 0.01 then
                    if prevPitch > DEADBAND then
                        peaks[#peaks + 1] = { value = prevPitch, time = elapsed }
                    end
                    direction = -1
                elseif direction == -1 and pitch > prevPitch + 0.01 then
                    if prevPitch < -DEADBAND then
                        troughs[#troughs + 1] = { value = prevPitch, time = elapsed }
                    end
                    direction = 1
                end
            end
            prevPitch = pitch

            local cycles = math.min(#peaks, #troughs)
            cls(); header("Calibrating Tilt...")
            statusLine(3, string.format("  Pitch:          %+.2f deg", pitch))
            statusLine(4, string.format("  Relay:          %+.1f", tiltRelay))
            statusLine(5, string.format("  Front/Back:     %d / %d",
                clamp(math.floor(equilOut + tiltRelay + 0.5), 0, 15),
                clamp(math.floor(equilOut - tiltRelay + 0.5), 0, 15)))
            statusLine(6, string.format("  Cycles:         %d/%d", cycles, MIN_CYCLES))
            statusLine(7, string.format("  Time remaining: %.0f s", MAX_RELAY_DURATION - elapsed))
            footer("[Q] Abort")

            if cycles >= MIN_CYCLES then break end
            if elapsed >= MAX_RELAY_DURATION then break end
            sleep(LOOP_INTERVAL)
        end
    end

    local function abortListener()
        while not calibAbort do
            local _, key = os.pullEvent("key")
            if key == keys.q then calibAbort = true end
        end
    end

    parallel.waitForAny(relayLoop, abortListener)
    zeroOut()

    if calibAbort then return nil end

    local cycles = math.min(#peaks, #troughs)
    if cycles < MIN_CYCLES then
        cls(); header("Tilt Cal. Failed")
        term.setCursorPos(1, 3)
        print("  Not enough oscillation (" .. cycles .. "/" .. MIN_CYCLES .. " cycles).")
        print("  Ensure gimbal sensor is attached.")
        footer("Press any key")
        os.pullEvent("key")
        return nil
    end

    -- Phase D: Analysis
    local peakSum, troughSum = 0, 0
    for _, p in ipairs(peaks)   do peakSum   = peakSum   + p.value end
    for _, t in ipairs(troughs) do troughSum = troughSum + t.value end
    local a = (peakSum / #peaks - troughSum / #troughs) / 2
    local periodSum = 0
    for i = 2, #peaks do periodSum = periodSum + (peaks[i].time - peaks[i-1].time) end
    local Tu = periodSum / (#peaks - 1)
    if a < 0.05 then
        cls(); header("Tilt Cal. Failed")
        term.setCursorPos(1, 3)
        print("  Amplitude too small (a=" .. string.format("%.3f", a) .. ").")
        footer("Press any key")
        os.pullEvent("key")
        return nil
    end
    local Ku = (4 / math.pi) * TILT_RELAY_AMP / a

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
        cls(); header("Tilt Cal. Results")
        term.setCursorPos(1, 3)
        print(string.format("  Ku=%.3f  Tu=%.2fs  Amplitude=%.2f deg", Ku, Tu, a))
        print("")
        for i, opt in ipairs(options) do
            term.setCursorPos(1, 5 + (i - 1) * 2)
            local line = string.format("  [%d] %s  Kp=%.3f  Ki=%.4f  Kd=%.3f",
                i, opt.label, opt.kp, opt.ki, opt.kd)
            if sel == i and term.isColour() then
                term.setTextColour(colours.black)
                term.setBackgroundColour(colours.white)
            end
            term.write(line)
            if term.isColour() then
                term.setTextColour(colours.white)
                term.setBackgroundColour(colours.black)
            end
        end
        footer("[1/2] Select  [Enter] Apply  [Q] Discard")
        local _, key = os.pullEvent("key")
        if     key == keys.one                    then sel = 1
        elseif key == keys.two                    then sel = 2
        elseif key == keys.up or key == keys.down then sel = sel == 1 and 2 or 1
        elseif key == keys.enter then
            cfg.tKp = options[sel].kp
            cfg.tKi = options[sel].ki
            cfg.tKd = options[sel].kd
            saveConfig(cfg)
            return cfg
        elseif key == keys.q then
            return nil
        end
    end
end

local function runControl(cfg)
    local bridge    = peripheral.find("redstone_link_bridge")
    local altSensor = peripheral.find("altitude_sensor")
    local velSensor = peripheral.find("velocity_sensor")
    local navTable  = peripheral.find("navigation_table")
    local gimbal    = peripheral.find("gimbal_sensor")

    local missing = {}
    if not bridge    then missing[#missing+1] = "redstone_link_bridge" end
    if not altSensor then missing[#missing+1] = "altitude_sensor"      end
    if not velSensor then missing[#missing+1] = "velocity_sensor"      end
    if not navTable  then missing[#missing+1] = "navigation_table"     end
    if not gimbal    then missing[#missing+1] = "gimbal_sensor"        end

    if #missing > 0 then
        cls()
        header("Control Module - ERROR")
        term.setCursorPos(1, 3)
        print("  Missing peripherals:")
        for _, name in ipairs(missing) do
            printError("    - " .. name)
        end
        sleep(5)
        return
    end

    local function runSetup()
        cls(); header("Control Module Setup")
        term.setCursorPos(1, 3)
        local function prompt(label, default)
            term.write(label .. " [" .. tostring(default) .. "]: ")
            local s = read()
            local n = tonumber(s)
            return (s == "" and default) or (n ~= nil and n) or default
        end
        print("  -- Height Range --")
        cfg.minHeight = prompt("  Min height", cfg.minHeight or 60)
        cfg.maxHeight = prompt("  Max height", cfg.maxHeight or 180)
        cfg.hKp = cfg.hKp or 2.0;  cfg.hKi = cfg.hKi or 0.05; cfg.hKd = cfg.hKd or 0.0
        cfg.tKp = cfg.tKp or 1.0;  cfg.tKi = cfg.tKi or 0.0;  cfg.tKd = cfg.tKd or 0.0
        cfg.equilMap = cfg.equilMap or {}
        saveConfig(cfg)
    end

    if not cfg.minHeight then runSetup() end

    local hIntegral   = 0
    local tIntegral   = 0
    local lastHTarget = nil
    local prevPitch   = nil
    local action      = nil

    local function controlLoop()
        while not action do
            -- Height PID
            local altitude  = altSensor.getHeight()
            local velocityY = altSensor.getVerticalSpeed()
            local rawSig    = bridge.getLinkSignal(HEIGHT_F1, HEIGHT_F2)
            local targetH   = cfg.minHeight + (1 - rawSig / 15) * (cfg.maxHeight - cfg.minHeight)
            if lastHTarget and math.abs(targetH - lastHTarget) > 5 then hIntegral = 0 end
            lastHTarget = targetH
            local hErr      = targetH - altitude
            hIntegral       = clamp(hIntegral + hErr * LOOP_INTERVAL, -INTEGRAL_CLAMP, INTEGRAL_CLAMP)
            local ff        = ffOutput(targetH, cfg.equilMap)
            local heightOut = clamp(ff + cfg.hKp * hErr + cfg.hKi * hIntegral + cfg.hKd * (-velocityY), 0, 15)

            -- Tilt PID
            local angles    = gimbal.getAngles()
            local raw       = angles[1]
            local pitch     = raw > 180 and raw - 360 or raw
            local pitchRate = prevPitch and ((pitch - prevPitch) / LOOP_INTERVAL) or 0
            prevPitch = pitch
            local tErr    = -pitch
            tIntegral     = clamp(tIntegral + tErr * LOOP_INTERVAL, -INTEGRAL_CLAMP, INTEGRAL_CLAMP)
            local tiltOut = clamp(cfg.tKp * tErr + cfg.tKi * tIntegral + cfg.tKd * (-pitchRate), -7.5, 7.5)

            -- Combine and output
            local frontOut = clamp(math.floor(heightOut + tiltOut + 0.5), 0, 15)
            local backOut  = clamp(math.floor(heightOut - tiltOut + 0.5), 0, 15)
            bridge.sendLinkSignal(FRONT_F1, FRONT_F2, frontOut)
            bridge.sendLinkSignal(BACK_F1,  BACK_F2,  backOut)

            -- Read remaining sensors for broadcast
            local throttle  = bridge.getLinkSignal(THROTTLE_F1, THROTTLE_F2)
            local reverse   = bridge.getLinkSignal(REVERSE_F1,  REVERSE_F2) == 15
            local velocity  = -velSensor.getVelocity()
            local autopilot = navTable.hasTarget()
            local heading   = navTable.getRelativeAngle()
            local distance  = autopilot and navTable.getDistanceToTarget() or nil
            local hDistSq   = distance and math.max(0, distance * distance - altitude * altitude)
            local arrived   = autopilot and hDistSq ~= nil and (hDistSq < ARRIVAL_RADIUS * ARRIVAL_RADIUS)
            local fuel      = bridge.getLinkSignal(FUEL_F1, FUEL_F2)

            rednet.broadcast({
                type         = "sensor_data",
                throttle     = throttle,  reverse      = reverse,
                altitude     = altitude,  velocity     = velocity,
                autopilot    = autopilot, heading      = heading,
                distance     = distance,  arrived      = arrived,
                fuel         = fuel,
                pitch        = pitch,
                targetHeight = targetH,
            }, PROTOCOL)

            local apStatus = not autopilot and "OFF"
                          or arrived and "ON - ARRIVED"
                          or string.format("ON (%.0f m)", distance or 0)

            statusLine(3,  string.format("  Alt    : %.1f / %.1f m", altitude, targetH))
            statusLine(4,  string.format("  VelY   : %+.2f m/s", velocityY))
            statusLine(5,  string.format("  Pitch  : %+.2f deg", pitch))
            statusLine(6,  string.format("  H PID  : %.1f/15 (err: %+.1f)", heightOut, hErr))
            statusLine(7,  string.format("  Tilt   : %+.1f (err: %+.2f)", tiltOut, tErr))
            statusLine(8,  string.format("  Front  : %d/15   Back: %d/15", frontOut, backOut))
            statusLine(9,  string.format("  AP     : %s", apStatus))
            statusLine(10, string.format("  Fuel   : %d/15", fuel))

            sleep(LOOP_INTERVAL)
        end
    end

    local function keyHandler()
        while not action do
            local _, key = os.pullEvent("key")
            if     key == keys.c then action = "calibrateH"
            elseif key == keys.t then action = "calibrateT"
            elseif key == keys.r then action = "reconfigure"
            end
        end
    end

    cls()
    header("Control Module")
    footer("[U] Restart All  [C] Cal.H  [T] Cal.T  [R] Setup")

    while true do
        action = nil
        hIntegral = 0; tIntegral = 0; lastHTarget = nil; prevPitch = nil
        parallel.waitForAny(controlLoop, keyHandler, restartListener)

        bridge.sendLinkSignal(FRONT_F1, FRONT_F2, 0)
        bridge.sendLinkSignal(BACK_F1,  BACK_F2,  0)

        if action == "reconfigure" then
            runSetup()
        elseif action == "calibrateH" then
            local result = runHeightCalibration(cfg, bridge, altSensor)
            if result then cfg = result end
        elseif action == "calibrateT" then
            local result = runTiltCalibration(cfg, bridge, gimbal)
            if result then cfg = result end
        end

        cls()
        header("Control Module")
        footer("[U] Restart All  [C] Cal.H  [T] Cal.T  [R] Setup")
    end
end

--------------------------------------------------------------------------------
-- Module: Announcement
--------------------------------------------------------------------------------

local function runAnnouncement(cfg)
    local speakers = { peripheral.find("speaker") }
    local ok, dfpwm = pcall(require, "cc.audio.dfpwm")
    if not ok then ok, dfpwm = pcall(require, "dfpwm") end
    if not ok then dfpwm = nil end

    local soundVolume   = cfg.soundVolume or 1.0
    local soundQueue    = {}
    local lastAutopilot = false
    local lastArrived   = false
    local lastFuel      = 15

    cls()
    header("Announcement Module")
    footer("[U] Restart All  [+/-] Volume")

    local function playSound(path)
        if not dfpwm or #speakers == 0 or not fs.exists(path) then return end
        local tasks = {}
        for _, spk in ipairs(speakers) do
            tasks[#tasks + 1] = function()
                local decoder = dfpwm.make_decoder()
                local f = fs.open(path, "rb")
                while true do
                    local chunk = f.read(16 * 1024)
                    if not chunk then break end
                    local buf = decoder(chunk)
                    while not spk.playAudio(buf, soundVolume) do
                        os.pullEvent("speaker_audio_empty")
                    end
                end
                f.close()
            end
        end
        parallel.waitForAll(table.unpack(tasks))
    end

    local function soundLoop()
        while true do
            if #soundQueue > 0 then
                local path = table.remove(soundQueue, 1)
                playSound(path)
            else
                sleep(0.1)
            end
        end
    end

    local function receiveLoop()
        while true do
            local _, msg = rednet.receive(PROTOCOL)
            if type(msg) == "table" and msg.type == "sensor_data" then
                local newAp   = msg.autopilot or false
                local newArr  = msg.arrived   or false
                local newFuel = msg.fuel       or 0

                if not lastAutopilot and newAp and not newArr then
                    soundQueue[#soundQueue + 1] = SOUNDS_PATH .. "autonav_start.dfpwm"
                end
                -- Stop only fires when AP was already running and we just arrived
                if lastAutopilot and newAp and newArr and not lastArrived then
                    soundQueue[#soundQueue + 1] = SOUNDS_PATH .. "autonav_stop.dfpwm"
                end
                if lastFuel > 3 and newFuel <= 3 and newFuel > 0 then
                    soundQueue[#soundQueue + 1] = SOUNDS_PATH .. "fuel_low.dfpwm"
                end
                if lastFuel > 0 and newFuel == 0 then
                    soundQueue[#soundQueue + 1] = SOUNDS_PATH .. "fuel_empty.dfpwm"
                end

                lastAutopilot = newAp
                lastArrived   = newArr
                lastFuel      = newFuel

                local apStr
                if not newAp then
                    apStr = "OFF"
                elseif newArr then
                    apStr = "ARRIVED"
                else
                    apStr = "ON"
                end

                statusLine(3, string.format("  Speakers : %d found",    #speakers))
                statusLine(4, string.format("  dfpwm    : %s",          dfpwm and "loaded" or "unavailable"))
                statusLine(5, string.format("  Volume   : %.1f / 3.0",  soundVolume))
                statusLine(6, string.format("  AP       : %s",          apStr))
                statusLine(7, string.format("  Fuel     : %d/15",       newFuel))
            end
        end
    end

    local function keyHandler()
        while true do
            local _, key = os.pullEvent("key")
            if key == keys.equals or key == keys.numPadAdd then
                soundVolume = math.min(3.0, soundVolume + 0.5)
                cfg.soundVolume = soundVolume
                saveConfig(cfg)
                statusLine(5, string.format("  Volume   : %.1f / 3.0", soundVolume))
            elseif key == keys.minus or key == keys.numPadSubtract then
                soundVolume = math.max(0.0, soundVolume - 0.5)
                cfg.soundVolume = soundVolume
                saveConfig(cfg)
                statusLine(5, string.format("  Volume   : %.1f / 3.0", soundVolume))
            end
        end
    end

    -- Draw static lines before loops start
    statusLine(3, string.format("  Speakers : %d found",   #speakers))
    statusLine(4, string.format("  dfpwm    : %s",         dfpwm and "loaded" or "unavailable"))
    statusLine(5, string.format("  Volume   : %.1f / 3.0", soundVolume))
    statusLine(6,  "  AP       : --")
    statusLine(7,  "  Fuel     : --")

    parallel.waitForAny(receiveLoop, soundLoop, keyHandler, restartListener)
end

--------------------------------------------------------------------------------
-- Module: Readout
--------------------------------------------------------------------------------

local function runReadout()
    local leftMon  = peripheral.wrap("left")
    local rightMon = peripheral.wrap("right")

    if not leftMon or not rightMon then
        cls()
        header("Readout Module - ERROR")
        term.setCursorPos(1, 3)
        printError("  Monitors not found.")
        print("  Connect 2x1 advanced monitors to the left and right sides.")
        sleep(5)
        return
    end

    leftMon.setTextScale(0.5)
    rightMon.setTextScale(0.5)

    local function mwrite(mon, x, y, text, col)
        mon.setCursorPos(x, y)
        if col and mon.isColour() then mon.setTextColour(col) end
        mon.write(text)
        if mon.isColour() then mon.setTextColour(colours.white) end
    end

    local function fuelBar(val, width)
        local filled = math.floor(val / 15 * width + 0.5)
        return string.rep("=", filled) .. string.rep("-", width - filled)
    end

    local function redraw(d)
        -- Left monitor: Altitude and Velocity
        if leftMon.isColour() then leftMon.setBackgroundColour(colours.black) end
        leftMon.clear()
        mwrite(leftMon, 2, 1, "FLIGHT DATA", colours.cyan)
        mwrite(leftMon, 2, 3, string.format("ALTITUDE  %.1f m",    d.altitude or 0))
        mwrite(leftMon, 2, 5, string.format("VELOCITY  %.2f m/s",  d.velocity or 0))

        -- Right monitor: Autopilot, Fuel, Throttle
        if rightMon.isColour() then rightMon.setBackgroundColour(colours.black) end
        rightMon.clear()
        mwrite(rightMon, 2, 1, "STATUS", colours.cyan)

        if d.autopilot then
            if d.arrived then
                mwrite(rightMon, 2, 3, "AUTO-NAV ON - ARRIVED", colours.lime)
            else
                mwrite(rightMon, 2, 3,
                    string.format("AUTO-NAV ON - %.0f m", d.distance or 0), colours.lime)
            end
        else
            mwrite(rightMon, 2, 3, "AUTO-NAV OFF", colours.red)
        end

        local fuelVal = d.fuel or 0
        local fuelCol = colours.white
        if     fuelVal <= 3 then fuelCol = colours.red
        elseif fuelVal <= 7 then fuelCol = colours.yellow end
        mwrite(rightMon, 2, 5,
            string.format("FUEL [%s] %d/15", fuelBar(fuelVal, 9), fuelVal), fuelCol)

        local dispThr = d.throttle or 0
        local dispRev = d.reverse or false
        if d.autopilot then
            if d.arrived then
                dispThr, dispRev = 0, false
            else
                local h = d.heading or 180
                dispThr = math.floor(math.abs(math.cos(math.rad(h))) * 15 + 0.5)
                dispRev = (h < 90 or h > 270)
            end
        end
        mwrite(rightMon, 2, 7,
            string.format("THR  %d/15%s%s",
                dispThr, dispRev and "  REV" or "", d.autopilot and "  [AP]" or ""))
    end

    cls()
    header("Readout Module")
    footer("[U] Restart All")
    term.setCursorPos(1, 3)
    print("  Waiting for sensor data...")

    local lastData = {}
    local function loop()
        while true do
            local _, msg = rednet.receive(PROTOCOL, 1)
            if msg and msg.type == "sensor_data" then
                lastData = msg
                redraw(lastData)
            end
        end
    end

    parallel.waitForAny(loop, restartListener)
end

--------------------------------------------------------------------------------
-- Module: Pilot
--------------------------------------------------------------------------------

local function runPilot()
    local wheel = peripheral.find("steering_wheel")
    if not wheel then
        cls()
        header("Pilot Module - ERROR")
        term.setCursorPos(1, 3)
        printError("  No steering_wheel peripheral found.")
        sleep(5)
        return
    end

    local latestSData = {}

    cls()
    header("Pilot Module")
    footer("[U] Update")

    local function pilotLoop()
        while true do
            -- getNormalizedAngle: positive = left, negative = right (confirmed in testing)
            local norm  = wheel.getNormalizedAngle()
            local left  = math.max( norm, 0)
            local right = math.max(-norm, 0)

            rednet.broadcast({
                type  = "pilot_data",
                left  = left,
                right = right,
            }, PROTOCOL)

            local apStr = ""
            if latestSData.autopilot then
                apStr = latestSData.arrived and "  [AP: ARRIVED]" or "  [AP: ON]"
            end

            statusLine(3, string.format("  Wheel : %+.2f%s", norm, apStr))
            statusLine(4, string.format("  Left  : %.2f",  left))
            statusLine(5, string.format("  Right : %.2f",  right))

            sleep(0.05)
        end
    end

    local function receiveLoop()
        while true do
            local _, msg = rednet.receive(PROTOCOL)
            if msg and msg.type == "sensor_data" then
                latestSData = msg
            end
        end
    end

    parallel.waitForAny(pilotLoop, receiveLoop, restartListener)
end

--------------------------------------------------------------------------------
-- Module: Engine
--------------------------------------------------------------------------------

local function runEngineSetup(cfg)
    cls()
    header("Engine Setup")
    term.setCursorPos(1, 3)
    print("  Scanning for analog_transmission peripherals...")
    sleep(0.5)

    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "analog_transmission" then
            found[#found+1] = name
        end
    end

    if #found == 0 then
        cls()
        header("Engine Setup - ERROR")
        term.setCursorPos(1, 3)
        printError("  No analog_transmission peripherals found.")
        print("  Connect them via networking cable.")
        sleep(5)
        return false
    end

    cls()
    header("Engine Setup")
    term.setCursorPos(1, 3)
    print(string.format("  Found %d peripheral(s):", #found))
    print("")
    for i, name in ipairs(found) do
        print(string.format("  [%d] %s", i, name))
    end
    print("")

    local function pick(label)
        while true do
            term.write("  Select " .. label .. " engine (1-" .. #found .. "): ")
            local n = tonumber(read())
            if n and found[n] then return n end
            printError("  Invalid selection. Try again.")
        end
    end

    local li = pick("LEFT")
    local ri = pick("RIGHT")

    if li == ri then
        printError("  Cannot assign the same peripheral to both engines.")
        sleep(3)
        return runEngineSetup(cfg)
    end

    cfg.leftEngineName  = found[li]
    cfg.rightEngineName = found[ri]
    saveConfig(cfg)

    print("")
    print("  Left engine  : " .. cfg.leftEngineName)
    print("  Right engine : " .. cfg.rightEngineName)
    print("  Setup complete.")
    sleep(2)
    return true
end

local function runEngine(cfg)
    if not cfg.leftEngineName or not cfg.rightEngineName then
        local ok = runEngineSetup(cfg)
        if not ok then return end
    end

    local leftEng  = peripheral.wrap(cfg.leftEngineName)
    local rightEng = peripheral.wrap(cfg.rightEngineName)

    if not leftEng or not rightEng then
        cls()
        header("Engine Module - ERROR")
        term.setCursorPos(1, 3)
        printError("  Engine peripheral(s) not found.")
        print("  Left:  " .. (cfg.leftEngineName  or "?"))
        print("  Right: " .. (cfg.rightEngineName or "?"))
        print("  Cables may have changed. Re-running setup...")
        sleep(3)
        cfg.leftEngineName  = nil
        cfg.rightEngineName = nil
        saveConfig(cfg)
        local ok = runEngineSetup(cfg)
        if not ok then return end
        leftEng  = peripheral.wrap(cfg.leftEngineName)
        rightEng = peripheral.wrap(cfg.rightEngineName)
        if not leftEng or not rightEng then return end
    end

    local sData = { throttle = 0, reverse = false }
    local pData = { left = 0, right = 0 }

    local function applyEngines()
        local throttle, reverse, left, right

        if sData.autopilot then
            if sData.arrived then
                throttle = 0
                reverse  = false
                left     = 0
                right    = 0
            else
                local h = sData.heading or 180
                -- full deflection outside ±30° of 180°; interpolate within that window
                local apWheel = math.max(-1, math.min(1, (h - 180) / 30))
                throttle = math.floor(math.abs(math.cos(math.rad(h))) * 15 + 0.5)
                reverse  = (h < 90 or h > 270)
                left     = math.max(-apWheel, 0)
                right    = math.max( apWheel, 0)
            end
        else
            throttle = sData.throttle
            reverse  = sData.reverse
            left     = pData.left
            right    = pData.right
        end

        local base      = (reverse and -1 or 1) * (throttle / 15)
        local turn      = left - right
        local leftFrac  = math.max(-1, math.min(1, base - turn))
        local rightFrac = math.max(-1, math.min(1, base + turn))

        -- Signal is inverted: 15 = stopped, 0 = full power
        rs.setOutput("left",  leftFrac  < 0)
        rs.setOutput("right", rightFrac < 0)
        leftEng.setSignal( math.floor((1 - math.abs(leftFrac))  * 15 + 0.5))
        rightEng.setSignal(math.floor((1 - math.abs(rightFrac)) * 15 + 0.5))

        return leftFrac, rightFrac, throttle, reverse, left, right
    end

    cls()
    header("Engine Module")
    footer("[U] Restart All")

    local function receiveLoop()
        while true do
            local _, msg = rednet.receive(PROTOCOL)
            if msg then
                if msg.type == "sensor_data" then sData = msg end
                if msg.type == "pilot_data"  then pData = msg end
            end
        end
    end

    local function controlLoop()
        while true do
            local lf, rf, thr, rev, lv, rv = applyEngines()
            local apFlag = ""
            if sData.autopilot then
                apFlag = sData.arrived and "  [AP: ARRIVED]" or "  [AP]"
            end
            statusLine(3, string.format("  Throttle : %d/15  Reverse: %s%s",
                thr, rev and "ON" or "OFF", apFlag))
            statusLine(4, string.format("  Steering : L=%.2f  R=%.2f", lv, rv))
            statusLine(5, string.format("  L Engine : %s  %.0f/15",
                lf < 0 and "REV" or "FWD", math.abs(lf) * 15))
            statusLine(6, string.format("  R Engine : %s  %.0f/15",
                rf < 0 and "REV" or "FWD", math.abs(rf) * 15))
            sleep(0.05)
        end
    end

    parallel.waitForAny(receiveLoop, controlLoop, restartListener)
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

local cfg = loadConfig()

if not openWirelessModem() then
    cls()
    header("Error")
    term.setCursorPos(1, 3)
    printError("  No wireless modem found.")
    print("  Attach a wireless modem to this computer.")
    sleep(5)
    return
end

local module = getModule(cfg)

local vesselName = sublevel and sublevel.getName()
if vesselName ~= "AXIOM" then
    cls()
    header("Error")
    term.setCursorPos(1, 3)
    printError("  This program only runs on the AXIOM.")
    print("  Vessel: " .. tostring(vesselName))
    sleep(5)
    return
end

cls()
header("Starting " .. module .. "...")
sleep(0.3)

if     module == "control"      then runControl(cfg)
elseif module == "readout"      then runReadout()
elseif module == "pilot"        then runPilot()
elseif module == "engine"       then runEngine(cfg)
elseif module == "announcement" then runAnnouncement(cfg)
end
