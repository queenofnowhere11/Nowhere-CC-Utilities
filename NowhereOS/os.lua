-- NowhereOS v1.0.0
-- Program browser, installer, and auto-updater for ComputerCraft.
-- Receives registry JSON as its first argument (passed by startup.lua).

local GITHUB_RAW     = "https://raw.githubusercontent.com/queenofnowhere11/Nowhere-CC-Utilities/main/"
local CONFIG_PATH    = "/.nowhere/config.json"
local REGISTRY_CACHE = "/.nowhere/registry.json"
local PROGRAMS_PATH  = "/.nowhere/programs/"
local VERSION        = "1.0.1"

local W, H    = term.getSize()
local isColor = term.isColour()

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

local function downloadFile(url, destPath)
    local response = http.get(url)
    if not response then return false, "HTTP request failed" end
    local content = response.readAll()
    response.close()
    local dir = fs.getDir(destPath)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local file = fs.open(destPath, "w")
    file.write(content)
    file.close()
    return true
end

local function loadConfig()
    if not fs.exists(CONFIG_PATH) then return {} end
    local file = fs.open(CONFIG_PATH, "r")
    local data = textutils.unserialiseJSON(file.readAll())
    file.close()
    return data or {}
end

local function saveConfig(cfg)
    local file = fs.open(CONFIG_PATH, "w")
    file.write(textutils.serialiseJSON(cfg))
    file.close()
end

local function installProgram(prog, config)
    local progDir = PROGRAMS_PATH .. prog.id .. "/"
    if not fs.exists(progDir) then fs.makeDir(progDir) end
    for _, f in ipairs(prog.files) do
        local ok, err = downloadFile(GITHUB_RAW .. f.src, progDir .. f.dest)
        if not ok then
            return false, "Failed to download " .. f.src .. ": " .. tostring(err)
        end
    end
    if not config.installed then config.installed = {} end
    config.installed[prog.id] = { version = prog.version }
    return true
end

--------------------------------------------------------------------------------
-- UI helpers
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

local function drawHeader()
    term.setCursorPos(1, 1)
    fg(colours.black); bg(colours.cyan)
    writePadded(" NowhereOS v" .. VERSION)
    resetColors()
end

local function drawFooter(text)
    term.setCursorPos(1, H)
    fg(colours.black); bg(colours.lightGrey)
    writePadded(" " .. (text or ""))
    resetColors()
end

local function drawStatus(msg)
    term.clear()
    drawHeader()
    term.setCursorPos(1, 4)
    resetColors()
    print("  " .. tostring(msg))
    drawFooter("")
end

--------------------------------------------------------------------------------
-- Countdown screen
--------------------------------------------------------------------------------

local function drawCountdown(progName, secondsLeft)
    term.clear()
    drawHeader()
    term.setCursorPos(1, 4)
    resetColors()
    print("  Default program: " .. progName)
    print("")
    fg(colours.yellow)
    local s = secondsLeft == 1 and "second" or "seconds"
    print("  Launching in " .. secondsLeft .. " " .. s .. "...")
    resetColors()
    print("")
    fg(colours.lightGrey)
    print("  Hold LEFT SHIFT to open NowhereOS menu")
    resetColors()
    drawFooter("")
end

--------------------------------------------------------------------------------
-- Menu screen
--------------------------------------------------------------------------------

local LIST_TOP  = 3   -- first row of the program list
local LIST_H    = H - LIST_TOP - 1  -- rows available for the list

local function drawMenu(programs, config, selected, scroll)
    term.clear()
    drawHeader()

    -- Description bar (row 2)
    term.setCursorPos(1, 2)
    fg(colours.lightGrey)
    if programs[selected] then
        local desc = programs[selected].description or ""
        term.write("  " .. desc:sub(1, W - 2))
    end
    resetColors()

    -- Program list
    for row = 1, LIST_H do
        term.setCursorPos(1, LIST_TOP + row - 1)
        local idx  = row + scroll
        local prog = programs[idx]
        if prog then
            local isSel     = (idx == selected)
            local isDefault = (config.default == prog.id)
            local isInst    = config.installed and config.installed[prog.id]

            if isSel then
                fg(colours.black); bg(colours.white)
            else
                resetColors()
            end

            local marker = isDefault and "\7 " or "  "
            local badge  = isDefault and " [DEFAULT]" or (isInst and " [installed]" or "")
            writePadded(marker .. prog.name .. badge)
        else
            term.clearLine()
        end
    end

    resetColors()
    drawFooter("[Up/Down] Select   [Enter] Install & Set Default   [Q] Quit")
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

local regFile = fs.open(REGISTRY_CACHE, "r")
local registry
if regFile then
    registry = textutils.unserialiseJSON(regFile.readAll())
    regFile.close()
end

if not registry then
    term.clear()
    printError("NowhereOS: Could not load registry.")
    print("Press any key to halt.")
    os.pullEvent("key")
    return
end

local config   = loadConfig()
local programs = registry.programs or {}

local openMenu = (#programs == 0) or not config.default

-- If a default program is set, countdown then launch it
if not openMenu then
    local defaultProg
    for _, p in ipairs(programs) do
        if p.id == config.default then defaultProg = p; break end
    end

    if not defaultProg then
        -- Default was removed from registry; reset
        config.default = nil
        saveConfig(config)
        openMenu = true
    else
        -- 3-second countdown; Left Shift aborts into menu
        local secsLeft = 3
        drawCountdown(defaultProg.name, secsLeft)
        local tick = os.startTimer(1)

        while secsLeft > 0 do
            local ev, p1 = os.pullEvent()
            if ev == "key" and p1 == keys.leftShift then
                openMenu = true
                break
            elseif ev == "timer" and p1 == tick then
                secsLeft = secsLeft - 1
                if secsLeft > 0 then
                    drawCountdown(defaultProg.name, secsLeft)
                    tick = os.startTimer(1)
                end
            end
        end

        if not openMenu then
            -- Update program if version changed
            local inst = config.installed and config.installed[defaultProg.id]
            if not inst or inst.version ~= defaultProg.version then
                drawStatus("Updating " .. defaultProg.name .. " to v" .. defaultProg.version .. "...")
                local ok, err = installProgram(defaultProg, config)
                if ok then
                    saveConfig(config)
                else
                    drawStatus("Update failed: " .. tostring(err) .. "\nRunning cached version.")
                    sleep(2)
                end
            end

            -- Run the program
            local mainPath = PROGRAMS_PATH .. defaultProg.id .. "/" .. defaultProg.main
            if fs.exists(mainPath) then
                term.clear()
                resetColors()
                pcall(shell.run, mainPath)
            else
                drawStatus("Program file not found. Please reinstall from the menu.")
                sleep(3)
            end

            -- After the program exits, fall through to menu
            openMenu = true
        end
    end
end

-- Menu loop
local selected = 1
local scroll   = 0

while true do
    -- Clamp selected within bounds
    if selected < 1 then selected = 1 end
    if selected > #programs and #programs > 0 then selected = #programs end

    drawMenu(programs, config, selected, scroll)

    local _, key = os.pullEvent("key")

    if key == keys.up then
        if selected > 1 then
            selected = selected - 1
            if selected <= scroll then scroll = selected - 1 end
        end

    elseif key == keys.down then
        if selected < #programs then
            selected = selected + 1
            if selected > scroll + LIST_H then scroll = selected - LIST_H end
        end

    elseif key == keys.enter and programs[selected] then
        local prog = programs[selected]
        drawStatus("Installing " .. prog.name .. "...")
        local ok, err = installProgram(prog, config)
        if ok then
            config.default = prog.id
            saveConfig(config)
            drawStatus("Installed! Rebooting...")
            sleep(2)
            os.reboot()
        else
            drawStatus("Install failed: " .. tostring(err) .. "\n\n  Press any key to return.")
            os.pullEvent("key")
        end

    elseif key == keys.q then
        break
    end
end

-- Exited to shell
term.clear()
term.setCursorPos(1, 1)
resetColors()
print("NowhereOS closed. Reboot to reopen, or run: shell.run('/.nowhere/os.lua')")
