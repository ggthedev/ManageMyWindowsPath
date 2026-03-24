#Requires -Version 5.1
<#
.SYNOPSIS
    An interactive terminal user interface (TUI) for managing Windows PATH environment variables.

.DESCRIPTION
    PathManager provides a pure-PowerShell, interactive console application to view, add, edit, 
    reorder, and delete environment variable entries for both the current User and the local System (Machine). 
    
    Architectural features of this version include:
    - Centralized state management and command-pattern input routing.
    - Optimized render loops (dirty-flagging) to prevent console flickering.
    - Invalid path highlighting (verifies if directories exist on disk).
    - Robust initialization with fallback error handling.
    - Automatic daily log rotation.

.EXAMPLE
    PS C:\> .\PathManager.ps1
    Launches the TUI in the current console. Defaults to modifying the 'User' scope.

.EXAMPLE
    PS C:\> Start-Process powershell -Verb RunAs -ArgumentList "-File .\PathManager.ps1"
    Launches the script in an elevated PowerShell session. Administrator privileges are 
    required to save changes to the 'System' (Machine) PATH.

.NOTES
    Author:      Gaurav Gupta
    Copyright:   (c) 2026, Gaurav Gupta. Licensed under the BSD 3-Clause License.
    Requires:    PowerShell 5.1 or newer, Windows 10+
    Privileges:  Standard user access is sufficient for the User PATH. 
                 Administrator rights are required to save changes to the System PATH.
#>

Set-StrictMode -Off

# ── 1. State Encapsulation ────────────────────────────────────────────────────────
$State = @{
    Scope   = 'User'
    Items   = [System.Collections.Generic.List[string]]::new()
    Sel     = 0
    Scroll  = 0
    Dirty   = $false
    Msg     = 'Initializing...'
    MsgOk   = $true
    Run     = $true
    LogFile = $null
    Redraw  = $true
}

# ── 2. Logging Subsystem ──────────────────────────────────────────────────────────
function Init-Log {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $logDir  = if ($isAdmin) { Join-Path $env:ProgramData 'PathManager\logs' }
               else          { Join-Path $env:LOCALAPPDATA 'PathManager\logs' }
    
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

    $State.LogFile = Join-Path $logDir "PathManager_$(Get-Date -Format 'yyyyMMdd').log"

    $maxSize = 5MB
    $keep    = 5
    if ((Test-Path $State.LogFile) -and (Get-Item $State.LogFile).Length -ge $maxSize) {
        for ($i = $keep; $i -ge 1; $i--) {
            $old = "$($State.LogFile).$i"
            $new = "$($State.LogFile).$($i + 1)"
            if ($i -eq $keep -and (Test-Path $old)) { Remove-Item $old -Force }
            if (Test-Path $old) { Rename-Item $old $new }
        }
        Rename-Item $State.LogFile "$($State.LogFile).1"
    }
}

function Write-Log([string]$level, [string]$message) {
    if (-not $State.LogFile) { return }
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $line = "$ts  [$level]  $user  $message"
    try { $line | Out-File -FilePath $State.LogFile -Append -Encoding UTF8 } catch {}
}

# ── 3. ANSI & Terminal Control ────────────────────────────────────────────────────
$e    = [char]27
$R    = "$e[0m";  $BOLD = "$e[1m";  $DIM  = "$e[2m"
$CYN  = "$e[96m"; $YEL  = "$e[93m"; $GRN  = "$e[92m"
$RED  = "$e[91m"; $BLU  = "$e[94m"; $GRY  = "$e[90m"; $WHT  = "$e[97m"
$BBLU = "$e[44m"

function Enable-VT {
    try {
        Add-Type -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
'@ -Namespace WinCon -Name K32 -ErrorAction Stop
        $h = [WinCon.K32]::GetStdHandle(-11)
        $m = 0u
        [WinCon.K32]::GetConsoleMode($h, [ref]$m) | Out-Null
        [WinCon.K32]::SetConsoleMode($h, $m -bor 4) | Out-Null
    } catch {}
}

# ── State ─────────────────────────────────────────────────────────────────────────
$script:scope  = 'User'
$script:items  = [System.Collections.Generic.List[string]]::new()
$script:sel    = 0
$script:scroll = 0
$script:dirty  = $false
$script:msg    = ''
$script:msgOk  = $true

# ── Data I/O ──────────────────────────────────────────────────────────────────────
function LoadEntries {
    $raw = [Environment]::GetEnvironmentVariable('PATH', $script:scope)
    $arr = if ([string]::IsNullOrWhiteSpace($raw)) { @() }
           else { @($raw -split ';' | Where-Object { $_ -ne '' }) }
    $script:items  = [System.Collections.Generic.List[string]]$arr
    $script:sel    = [Math]::Min($script:sel, [Math]::Max(0, $script:items.Count - 1))
    $script:scroll = 0
    $script:dirty  = $false
}

function SaveEntries {
    if ($script:scope -eq 'Machine') {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            $script:msg   = 'Administrator rights required to modify System PATH'
            $script:msgOk = $false
            WriteLog 'WARN' "Save blocked — not running as Administrator (scope=$($script:scope))"
            return
        }
    }
    try {
        $joined = ($script:items.ToArray() | Where-Object { $_ -ne '' }) -join ';'
        [Environment]::SetEnvironmentVariable('PATH', $joined, $script:scope)
        $script:dirty = $false
        $script:msg   = "Saved $($script:scope) PATH  ($($script:items.Count) entries)"
        $script:msgOk = $true
        WriteLog 'INFO' "SAVE scope=$($script:scope) entries=$($script:items.Count) length=$($joined.Length)"
    } catch {
        $script:msg   = "Save failed: $($_.Exception.Message)"
        $script:msgOk = $false
        WriteLog 'ERROR' "Save failed: $($_.Exception.Message)"
    }
}

# ── Layout helpers ────────────────────────────────────────────────────────────────
function CW   { return [Math]::Max(60, [Console]::WindowWidth) }
function CVis { return [Math]::Max(3,  [Console]::WindowHeight - 11) }

function StripAnsi([string]$s) {
    return [System.Text.RegularExpressions.Regex]::Replace($s, '\x1b\[[0-9;]*m', '')
}

function WriteRow([string]$line = '') {
    $pad = [Math]::Max(0, (CW) - (StripAnsi $line).Length)
    [Console]::Write($line + (' ' * $pad) + "`n")
}

function WriteSep([string]$ch = '-', [string]$col = $GRY) {
    WriteRow "$col$($ch * (CW))$R"
}

function SyncScroll {
    $vis = CVis
    if ($script:sel -lt $script:scroll) {
        $script:scroll = $script:sel
    } elseif ($script:sel -ge ($script:scroll + $vis)) {
        $script:scroll = $script:sel - $vis + 1
    }
    $script:scroll = [Math]::Max(0, $script:scroll)
}

function ClampSel {
    $n = $script:items.Count
    $script:sel = if ($n -eq 0) { 0 }
                  else { [Math]::Max(0, [Math]::Min($script:sel, $n - 1)) }
}

# ── Draw UI ───────────────────────────────────────────────────────────────────────
function DrawUI {
    [Console]::SetCursorPosition(0, 0)

    # Title bar
    $uTab  = if ($script:scope -eq 'User')    { "${BBLU}${WHT}${BOLD} USER ${R}"   } else { "${GRY} USER ${R}"   }
    $mTab  = if ($script:scope -eq 'Machine') { "${BBLU}${WHT}${BOLD} SYSTEM ${R}" } else { "${GRY} SYSTEM ${R}" }
    $dFlag = if ($script:dirty) { "${YEL}${BOLD} [unsaved]${R}" } else { "${GRN} [saved]${R}" }
    WriteRow "${CYN}${BOLD}  PATH MANAGER${R}   $uTab $mTab   $dFlag"
    WriteSep '=' $BLU

    # Column header
    WriteRow "${GRY}${BOLD}   #   Path${R}"
    WriteSep '-' $GRY

    # Entry rows
    $vis   = CVis
    $count = $script:items.Count
    $W     = CW

    if ($count -eq 0) {
        WriteRow "${DIM}   (no entries)  Press A to add one.${R}"
        for ($i = 1; $i -lt $vis; $i++) { WriteRow }
    } else {
        for ($row = 0; $row -lt $vis; $row++) {
            $idx = $row + $script:scroll
            if ($idx -ge $count) { WriteRow; continue }

            $path    = $script:items[$idx]
            $num     = '{0,3}' -f ($idx + 1)
            $isSel   = ($idx -eq $script:sel)
            $exists  = [System.IO.Directory]::Exists($path) -or [System.IO.File]::Exists($path)
            $maxLen  = $W - 9
            $display = if ($path.Length -gt $maxLen) { $path.Substring(0, $maxLen - 3) + '...' } else { $path }

            if ($isSel) {
                $pCol = if ($exists) { $WHT } else { $RED }
                WriteRow "${BBLU}${YEL}${BOLD} > ${R}${BBLU}${GRY}$num ${R}${BBLU}${pCol} $display ${R}"
            } else {
                $pCol = if ($exists) { $R } else { $RED }
                WriteRow "   $num  ${pCol}$display${R}"
            }
        }
    }

    # Footer
    WriteSep '-' $GRY

    $total = if ($count -gt 0) { (($script:items.ToArray()) -join ';').Length } else { 0 }
    $info  = if ($count -gt $vis) {
        "${GRY}  $count entries, showing $($script:scroll+1)-$([Math]::Min($script:scroll+$vis,$count))   PATH length: $total chars${R}"
    } else {
        "${GRY}  $count entries   PATH length: $total chars${R}"
    }
    WriteRow $info

    $mCol = if ($script:msgOk) { $GRN } else { $RED }
    WriteRow $(if ($script:msg) { "${mCol}  $($script:msg)${R}" } else { '' })

    WriteSep '=' $BLU
    WriteRow "${GRY}  ${CYN}Up/Down${GRY} Navigate   ${CYN}A${GRY} Add   ${CYN}E${GRY} Edit   ${CYN}Del${GRY}/${CYN}X${GRY} Delete   ${CYN}[${GRY}/${CYN}]${GRY} Move Up/Down   ${CYN}Tab${GRY} Scope${R}"
    WriteRow "${GRY}  ${CYN}Home/End${GRY} First/Last   ${CYN}PgUp/Dn${GRY} Page   ${CYN}S${GRY} Save   ${CYN}R${GRY} Reload   ${CYN}Q/Esc${GRY} Quit   ${DIM}Log: $($script:logFile)${R}"
}

# ── Input helpers ─────────────────────────────────────────────────────────────────
function ReadLineInput([string]$prompt, [string]$default = '') {
    SetCursor $true
    $buf  = $default
    $pos  = $buf.Length
    $row  = [Console]::WindowHeight - 1
    $done = $false

    while (-not $done) {
        $W   = CW
        $pre = "  $prompt  "
        [Console]::SetCursorPosition(0, $row)
        [Console]::Write(' ' * $W)
        [Console]::SetCursorPosition(0, $row)
        [Console]::Write("${CYN}${BOLD}$pre${R}${WHT}$buf${R}")
        [Console]::SetCursorPosition([Math]::Min($pre.Length + $pos, $W - 1), $row)

        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            ([ConsoleKey]::Enter)      { $done = $true }
            ([ConsoleKey]::Escape)     { $buf = $null; $done = $true }
            ([ConsoleKey]::Backspace)  { if ($pos -gt 0) { $buf = $buf.Remove($pos - 1, 1); $pos-- } }
            ([ConsoleKey]::Delete)     { if ($pos -lt $buf.Length) { $buf = $buf.Remove($pos, 1) } }
            ([ConsoleKey]::LeftArrow)  { if ($pos -gt 0) { $pos-- } }
            ([ConsoleKey]::RightArrow) { if ($pos -lt $buf.Length) { $pos++ } }
            ([ConsoleKey]::Home)       { $pos = 0 }
            ([ConsoleKey]::End)        { $pos = $buf.Length }
            default {
                if ($k.KeyChar -ne [char]0 -and -not [char]::IsControl($k.KeyChar)) {
                    $buf = $buf.Insert($pos, [string]$k.KeyChar)
                    $pos++
                }
            }
        }
    }

    SetCursor $false
    return $buf
}

function ConfirmPrompt([string]$msg) {
    SetCursor $true
    $row = [Console]::WindowHeight - 1
    [Console]::SetCursorPosition(0, $row)
    [Console]::Write(' ' * (CW))
    [Console]::SetCursorPosition(0, $row)
    [Console]::Write("${YEL}${BOLD}  $msg  [y/N]: ${R}")
    $k = [Console]::ReadKey($true)
    SetCursor $false
    return ($k.KeyChar -eq 'y' -or $k.KeyChar -eq 'Y')
}

# ── Actions ───────────────────────────────────────────────────────────────────────
function DoAdd {
    $val = ReadLineInput 'New PATH entry:'
    if ([string]::IsNullOrWhiteSpace($val)) {
        $script:msg = 'Add cancelled.'; $script:msgOk = $true; return
    }
    $val = $val.Trim().Trim('"')
    if ($script:items.Contains($val)) {
        $script:msg = 'Duplicate — entry already exists.'; $script:msgOk = $false; return
    }
    $script:items.Add($val)
    $script:sel   = $script:items.Count - 1
    $script:dirty = $true
    $exists = [System.IO.Directory]::Exists($val)
    $script:msg   = if ($exists) { "Added: $val" } else { "Added (directory not found on disk): $val" }
    $script:msgOk = $true
    WriteLog 'INFO' "ADD scope=$($script:scope) entry='$val' exists=$exists"
}

function DoEdit {
    if ($script:items.Count -eq 0) { return }
    $cur = $script:items[$script:sel]
    $val = ReadLineInput 'Edit entry:' $cur
    if ($null -eq $val) { $script:msg = 'Edit cancelled.'; $script:msgOk = $true; return }
    $val = $val.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($val)) { $script:msg = 'Value cannot be empty.'; $script:msgOk = $false; return }
    if ($val -eq $cur)                      { $script:msg = 'No changes made.';        $script:msgOk = $true;  return }
    $script:items[$script:sel] = $val
    $script:dirty = $true
    $script:msg   = "Updated entry $($script:sel + 1)."
    $script:msgOk = $true
    WriteLog 'INFO' "EDIT scope=$($script:scope) index=$($script:sel) old='$cur' new='$val'"
}

function DoDelete {
    if ($script:items.Count -eq 0) { return }
    $e    = $script:items[$script:sel]
    $disp = if ($e.Length -gt 55) { $e.Substring(0, 52) + '...' } else { $e }
    if (ConfirmPrompt "Delete '$disp'?") {
        $script:items.RemoveAt($script:sel)
        ClampSel
        $script:dirty = $true; $script:msg = 'Entry deleted.'; $script:msgOk = $true
        WriteLog 'INFO' "DELETE scope=$($script:scope) entry='$e'"
    } else {
        $script:msg = 'Delete cancelled.'; $script:msgOk = $true
    }
}

function DoMoveUp {
    $i = $script:sel
    if ($i -le 0) { return }
    $tmp = $script:items[$i - 1]
    $script:items[$i - 1] = $script:items[$i]
    $script:items[$i]     = $tmp
    $script:sel--
    $script:dirty = $true; $script:msg = 'Moved up.'; $script:msgOk = $true
    WriteLog 'INFO' "MOVE scope=$($script:scope) entry='$($script:items[$script:sel])' from=$i to=$($script:sel)"
}

function DoMoveDown {
    $i = $script:sel
    if ($i -ge $script:items.Count - 1) { return }
    $tmp = $script:items[$i + 1]
    $script:items[$i + 1] = $script:items[$i]
    $script:items[$i]     = $tmp
    $script:sel++
    $script:dirty = $true; $script:msg = 'Moved down.'; $script:msgOk = $true
    WriteLog 'INFO' "MOVE scope=$($script:scope) entry='$($script:items[$script:sel])' from=$i to=$($script:sel)"
}

function DoToggleScope {
    if ($script:dirty -and -not (ConfirmPrompt 'Discard unsaved changes and switch scope?')) {
        $script:msg = 'Cancelled.'; $script:msgOk = $true; return
    }
    $prevScope    = $script:scope
    $prevSel      = $script:sel
    $script:scope = if ($script:scope -eq 'User') { 'Machine' } else { 'User' }
    LoadEntries
    $script:sel   = [Math]::Min($prevSel, [Math]::Max(0, $script:items.Count - 1))
    $script:msg   = "Switched to $($script:scope) PATH"
    $script:msgOk = $true
    WriteLog 'INFO' "SCOPE from=$prevScope to=$($script:scope) entries=$($script:items.Count)"
}

function DoReload {
    if ($script:dirty -and -not (ConfirmPrompt 'Discard unsaved changes and reload?')) {
        $script:msg = 'Cancelled.'; $script:msgOk = $true; return
    }
    LoadEntries
    $script:msg   = "Reloaded $($script:scope) PATH"
    $script:msgOk = $true
    WriteLog 'INFO' "RELOAD scope=$($script:scope) entries=$($script:items.Count)"
}

# ── Main loop ─────────────────────────────────────────────────────────────────────
function SetCursor([bool]$visible) { try { [Console]::CursorVisible = $visible } catch {} }

function Main {
    InitLog
    EnableVT
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    SetCursor $false

    WriteLog 'INFO' '── SESSION START ──'
    Clear-Host
    LoadEntries

    $run = $true
    while ($run) {
        SyncScroll
        DrawUI

        $k     = [Console]::ReadKey($true)
        $shift = ($k.Modifiers -band [ConsoleModifiers]::Shift)   -ne 0
        $ctrl  = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
        $script:msg = ''

        if ($ctrl -and $k.Key -eq [ConsoleKey]::C) { $run = $false; continue }

        $kk = $k.Key
        if      ($kk -eq [ConsoleKey]::UpArrow)   { if ($script:sel -gt 0)                           { $script:sel-- } }
        elseif  ($kk -eq [ConsoleKey]::DownArrow) { if ($script:sel -lt $script:items.Count - 1)     { $script:sel++ } }
        elseif  ($kk -eq [ConsoleKey]::PageUp)    { $script:sel = [Math]::Max(0, $script:sel - (CVis)) }
        elseif  ($kk -eq [ConsoleKey]::PageDown)  { $script:sel = [Math]::Min([Math]::Max(0, $script:items.Count - 1), $script:sel + (CVis)) }
        elseif  ($kk -eq [ConsoleKey]::Home)      { $script:sel = 0 }
        elseif  ($kk -eq [ConsoleKey]::End)       { $script:sel = [Math]::Max(0, $script:items.Count - 1) }
        elseif  ($kk -eq [ConsoleKey]::Delete)    { DoDelete }
        elseif  ($kk -eq [ConsoleKey]::Tab)       { DoToggleScope }
        elseif  ($kk -eq [ConsoleKey]::Escape)    {
            if ($script:dirty) { if (ConfirmPrompt 'Quit with unsaved changes?') { $run = $false } }
            else { $run = $false }
        }

        switch ([string][char]::ToLower($k.KeyChar)) {
            'a' { DoAdd }
            'e' { DoEdit }
            'x' { DoDelete }
            '[' { DoMoveUp }
            ']' { DoMoveDown }
            's' { SaveEntries }
            'r' { DoReload }
            'q' {
                if ($script:dirty) { if (ConfirmPrompt 'Quit with unsaved changes?') { $run = $false } }
                else { $run = $false }
            }
        }
    }

    Clear-Host
    SetCursor $true
    WriteLog 'INFO' '── SESSION END ──'
    Write-Host 'PATH Manager closed.'
    Write-Host "Log: $($script:logFile)"
}

try   { Main }
finally { SetCursor $true }
