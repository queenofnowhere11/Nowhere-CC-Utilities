-- NowhereOS Boot Shim v1.0.0
-- Lives at /startup.lua on the CC computer.
-- Fetches registry.json, self-updates if needed, then runs NowhereOS.

local GITHUB_RAW = "https://raw.githubusercontent.com/queenofnowhere11/Nowhere-CC-Utilities/main/"
local CONFIG_PATH = "/.nowhere/config.json"
local OS_PATH     = "/.nowhere/os.lua"

local function downloadFile(url, path)
    local response = http.get(url)
    if not response then return false end
    local content = response.readAll()
    response.close()
    local file = fs.open(path, "w")
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

-- Fetch registry
term.clear()
term.setCursorPos(1, 1)
print("NowhereOS - Connecting...")

local registryResponse = http.get(GITHUB_RAW .. "registry.json")
if not registryResponse then
    printError("Failed to fetch registry. Check your internet connection.")
    print("Press any key to halt.")
    os.pullEvent("key")
    return
end

local registryContent = registryResponse.readAll()
registryResponse.close()
local registry = textutils.unserialiseJSON(registryContent)

if not registry then
    printError("Failed to parse registry.json.")
    print("Press any key to halt.")
    os.pullEvent("key")
    return
end

local config = loadConfig()

-- Self-update shim if version changed
if (config.startup_version or "0.0.0") ~= registry.startup_version then
    print("Updating boot shim to v" .. registry.startup_version .. "...")
    if downloadFile(GITHUB_RAW .. "NowhereOS/startup.lua", "/startup.lua") then
        config.startup_version = registry.startup_version
        saveConfig(config)
        print("Updated. Rebooting...")
        sleep(1)
        os.reboot()
    else
        printError("Failed to update boot shim. Continuing.")
    end
end

-- Update os.lua if version changed or missing
local needsOsUpdate = (config.nowhereos_version or "0.0.0") ~= registry.nowhereos_version
if needsOsUpdate or not fs.exists(OS_PATH) then
    print("Updating NowhereOS to v" .. registry.nowhereos_version .. "...")
    if downloadFile(GITHUB_RAW .. "NowhereOS/os.lua", OS_PATH) then
        config.nowhereos_version = registry.nowhereos_version
        saveConfig(config)
    else
        printError("Failed to download NowhereOS.")
        if not fs.exists(OS_PATH) then
            print("Press any key to halt.")
            os.pullEvent("key")
            return
        end
        printError("Running cached version.")
    end
end

-- Run NowhereOS, passing the already-fetched registry to avoid a second download
shell.run(OS_PATH, registryContent)
