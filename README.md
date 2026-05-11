# Nowhere CC Utilities

A lightweight OS and program manager for [ComputerCraft](https://computercraft.cc/) computers. Install once with a single command — NowhereOS handles the rest.

## Installation

On any ComputerCraft computer with HTTP enabled, run:

```
wget run https://raw.githubusercontent.com/queenofnowhere11/Nowhere-CC-Utilities/main/install.lua
```

The installer will download NowhereOS and reboot. On every subsequent boot, NowhereOS starts automatically.

> **Requirement:** HTTP must be enabled in your server's `computercraft.cfg` (it is on by default in most modpacks).

## First Boot

After installation, NowhereOS opens the program menu automatically. Use the arrow keys to browse available programs and press **Enter** to install one and set it as the default.

## Usage

| Key | Action |
|-----|--------|
| Up / Down | Browse programs |
| Enter | Install selected program and set as default |
| Q | Quit to shell |

Once a default program is set, NowhereOS will count down 3 seconds and launch it automatically on every boot. Hold **Left Shift** during the countdown to open the menu instead.

## Auto-Updates

NowhereOS checks for updates every boot. If a new version of your default program, the boot shim, or NowhereOS itself is available, it downloads and applies the update automatically before launching.

## Available Programs

| Program | Description |
|---------|-------------|
| Elevator Controller | Controls elevator lift mechanisms |
| Aeronautics PID Controller | PID flight controller for aeronautics |

## File Layout (on the CC computer)

```
/startup.lua              ← boot shim (auto-installed)
/.nowhere/
  config.json             ← stores default program and installed versions
  os.lua                  ← NowhereOS core (auto-updated)
  programs/
    <program-id>/
      program.lua         ← installed program files
```
