-- Axiom Navigation Systems v1.0.7
-- Navigation control system for the AXIOM airship

local VERSION     = "1.2.1"
local CONFIG_PATH = "ans_config.json"
local PROTOCOL    = "axiom_nav"

local GITHUB_RAW  = "https://raw.githubusercontent.com/queenofnowhere11/Nowhere-CC-Utilities/main/"
local PROGRAM_SRC = "Programs/Axiom Navigation Systems/program.lua"
local SOUNDS_PATH = fs.getDir(shell.getRunningProgram()) .. "/sounds/"

-- AutoNav arrival: horizontal distance threshold in blocks
local ARRIVAL_RADIUS = 15

-- Redstone Link Bridge frequencies
local THROTTLE_F1 = "everycomp:tf/biomeswevegone/hollow_ebony_log"
local THROTTLE_F2 = "simulated:throttle_lever"
local REVERSE_F1  = "everycomp:tf/biomeswevegone/hollow_ebony_log"
local REVERSE_F2  = "minecraft:lever"
local FUEL_F1     = "everycomp:tf/biomeswevegone/hollow_ebony_log"
local FUEL_F2     = "create_connected:fluid_vessel"

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
    { id = "sensor",       label = "Sensor",   desc = "Reads sensors, broadcasts to network"         },
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
-- Module: Sensor
--------------------------------------------------------------------------------

local function runSensor()
    local bridge    = peripheral.find("redstone_link_bridge")
    local altSensor = peripheral.find("altitude_sensor")
    local velSensor = peripheral.find("velocity_sensor")
    local navTable  = peripheral.find("navigation_table")

    local missing = {}
    if not bridge    then missing[#missing+1] = "redstone_link_bridge" end
    if not altSensor then missing[#missing+1] = "altitude_sensor"      end
    if not velSensor then missing[#missing+1] = "velocity_sensor"      end
    if not navTable  then missing[#missing+1] = "navigation_table"     end

    if #missing > 0 then
        cls()
        header("Sensor Module - ERROR")
        term.setCursorPos(1, 3)
        print("  Missing peripherals:")
        for _, name in ipairs(missing) do
            printError("    - " .. name)
        end
        sleep(5)
        return
    end

    cls()
    header("Sensor Module")
    footer("[U] Restart All")

    local function broadcastLoop()
        while true do
            local throttle  = bridge.getLinkSignal(THROTTLE_F1, THROTTLE_F2)
            local reverse   = bridge.getLinkSignal(REVERSE_F1,  REVERSE_F2) == 15
            local altitude  = altSensor.getHeight()
            local velocity  = -velSensor.getVelocity()
            local autopilot = navTable.hasTarget()
            -- getRelativeAngle: 0/360=behind, 90=left, 180=ahead, 270=right
            local heading   = navTable.getRelativeAngle()
            local distance  = autopilot and navTable.getDistanceToTarget() or nil
            local hDistSq   = distance and math.max(0, distance * distance - altitude * altitude)
            local arrived   = autopilot and hDistSq ~= nil and (hDistSq < ARRIVAL_RADIUS * ARRIVAL_RADIUS)
            local fuel      = bridge.getLinkSignal(FUEL_F1, FUEL_F2)

            rednet.broadcast({
                type      = "sensor_data",
                throttle  = throttle,
                reverse   = reverse,
                altitude  = altitude,
                velocity  = velocity,
                autopilot = autopilot,
                heading   = heading,
                distance  = distance,
                arrived   = arrived,
                fuel      = fuel,
            }, PROTOCOL)

            local apStatus
            if not autopilot then
                apStatus = "OFF"
            elseif arrived then
                apStatus = "ON - ARRIVED"
            else
                apStatus = string.format("ON  (%.0f m)", distance or 0)
            end

            statusLine(3, string.format("  Altitude : %.1f m", altitude))
            statusLine(4, string.format("  Velocity : %.2f m/s", velocity))
            statusLine(5, string.format("  Throttle : %d/15%s", throttle, reverse and "  [REVERSE]" or ""))
            statusLine(6, string.format("  Autopilot: %s", apStatus))
            statusLine(7, string.format("  Heading  : %.1f deg", heading))
            statusLine(8, string.format("  Fuel     : %d/15", fuel))

            sleep(0.05)
        end
    end

    parallel.waitForAny(broadcastLoop, restartListener)
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

if     module == "sensor"       then runSensor()
elseif module == "readout"      then runReadout()
elseif module == "pilot"        then runPilot()
elseif module == "engine"       then runEngine(cfg)
elseif module == "announcement" then runAnnouncement(cfg)
end
