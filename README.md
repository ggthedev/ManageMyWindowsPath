# PathManager

An interactive terminal UI (TUI) for managing Windows PATH environment variables.

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![Windows](https://img.shields.io/badge/Platform-Windows-0078D6)

## Features

- View all PATH entries in a scrollable, color-coded list
- **Add**, **edit**, and **delete** entries interactively
- **Reorder** entries to control lookup priority
- Toggle between **User** and **System** (Machine) PATH scopes
- Invalid paths highlighted in red for quick cleanup
- Unsaved-changes tracking with save confirmation on exit
- Full audit logging with automatic log rotation
- No external dependencies -- pure PowerShell

## Requirements

- Windows 10 or later
- PowerShell 5.1+ (ships with Windows) or PowerShell 7+
- A terminal that supports ANSI escape codes (Windows Terminal, ConHost, VS Code terminal)

## Quick Start

```powershell
.\PathManager.ps1
```

To modify the **System** PATH, run from an elevated (Administrator) prompt:

```powershell
# Right-click PowerShell -> Run as Administrator
.\PathManager.ps1
```

### Optional: Add as a global command

Add this to your PowerShell `$PROFILE` to use it from anywhere:

```powershell
function pathman { & "C:\Path\To\PathManager.ps1" }
```

## Keyboard Reference

### Navigation

| Key | Action |
|---|---|
| `Up` / `Down` | Move selection |
| `Home` / `End` | Jump to first / last entry |
| `PgUp` / `PgDn` | Scroll by page |

### Actions

| Key | Action |
|---|---|
| `A` | Add a new PATH entry |
| `E` | Edit the selected entry |
| `Del` or `X` | Delete the selected entry (with confirmation) |
| `[` | Move selected entry **up** (higher priority) |
| `]` | Move selected entry **down** (lower priority) |
| `Tab` | Toggle between User and System scope |
| `S` | Save changes to the registry |
| `R` | Reload PATH from the registry (discard unsaved changes) |
| `Q` or `Esc` | Quit (prompts if unsaved changes exist) |
| `Ctrl+C` | Force quit |

## How It Works

PathManager reads the PATH variable from the Windows registry via `[Environment]::GetEnvironmentVariable()`, displays it as individual entries, and writes changes back with `[Environment]::SetEnvironmentVariable()` when you press `S`.

Changes are **not auto-saved**. The title bar shows `[unsaved]` or `[saved]` so you always know the current state.

### User vs System PATH

| Scope | What it affects | Requires Admin |
|---|---|---|
| **User** | Current user's PATH only | No |
| **System** | Machine-wide PATH for all users | Yes |

Press `Tab` to switch between scopes. If you try to save System PATH without Administrator privileges, the operation is blocked with a warning.

## Logging

Every mutating action (add, edit, delete, move, save, scope switch) is logged with a timestamp and the current Windows username.

### Log Location

| Context | Directory |
|---|---|
| Normal user | `%LOCALAPPDATA%\PathManager\logs\` |
| Running as Administrator | `%ProgramData%\PathManager\logs\` |

Log files are named `PathManager_YYYYMMDD.log` (one per day).

### Log Rotation

When a daily log file exceeds **5 MB**, it is rotated automatically:

```
PathManager_20260324.log      <- current
PathManager_20260324.log.1    <- previous
PathManager_20260324.log.2
...
PathManager_20260324.log.5    <- oldest (deleted when a 6th would be created)
```

### Log Format

```
2026-03-24 14:05:12  [INFO]   DOMAIN\User  ── SESSION START ──
2026-03-24 14:05:15  [INFO]   DOMAIN\User  ADD scope=User entry='C:\tools\bin' exists=True
2026-03-24 14:05:18  [INFO]   DOMAIN\User  SAVE scope=User entries=15 length=842
2026-03-24 14:06:01  [INFO]   DOMAIN\User  DELETE scope=User entry='C:\old\path'
2026-03-24 14:06:10  [INFO]   DOMAIN\User  ── SESSION END ──
```

The current log file path is displayed in the bottom bar of the TUI and printed to the console when you quit.

## Deploying to All Users

To make PathManager available system-wide:

1. Copy `PathManager.ps1` to a shared location:
   ```
   C:\ProgramData\PathManager\PathManager.ps1
   ```

2. Optionally, create a wrapper script or shortcut that all users can access:
   ```powershell
   # Save as C:\ProgramData\PathManager\pathman.cmd
   @powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PathManager.ps1"
   ```

3. Add `C:\ProgramData\PathManager` to the System PATH so all users can run `pathman` from any prompt.

## License

Refer to License file
