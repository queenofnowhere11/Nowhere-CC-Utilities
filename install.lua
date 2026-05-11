-- NowhereOS Installer
-- Run once with:
--   wget run https://raw.githubusercontent.com/queenofnowhere11/Nowhere-CC-Utilities/main/install.lua

local GITHUB_RAW = "https://raw.githubusercontent.com/queenofnowhere11/Nowhere-CC-Utilities/main/"

local function downloadFile(url, path)
    local response = http.get(url)
    if not response then
        return false, "Could not connect to " .. url
    end
    local content = response.readAll()
    response.close()
    local file = fs.open(path, "w")
    file.write(content)
    file.close()
    return true
end

-- Header
term.clear()
term.setCursorPos(1, 1)
print("============================")
print("     NowhereOS Installer    ")
print("============================")
print("")

-- Check HTTP
if not http then
    printError("HTTP is not enabled on this computer.")
    printError("Enable it in the server's computercraft.cfg")
    return
end

-- Create .nowhere directory
if not fs.exists("/.nowhere") then
    fs.makeDir("/.nowhere")
    print("Created /.nowhere directory")
end

-- Download startup shim
print("Downloading startup shim...")
local ok, err = downloadFile(GITHUB_RAW .. "NowhereOS/startup.lua", "/startup.lua")
if not ok then
    printError("Failed: " .. tostring(err))
    return
end
print("Done.")
print("")
print("NowhereOS installed successfully!")
print("Rebooting in 3 seconds...")
sleep(3)
os.reboot()
