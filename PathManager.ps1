#Requires -Version 5.1
<#
.SYNOPSIS
    An interactive terminal user interface (TUI) for managing Windows PATH environment variables.

.DESCRIPTION
    PathManager provides a pure-PowerShell, interactive console application to view, add, edit, 
    reorder, and delete environment variable entries for both the current User and the local System (Machine). 
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

# ── 3. Native Win32 & Terminal Control ────────────────────────────────────────────
$e    = [char]27
$R    = "$e[0m";  $BOLD = "$e[1m";  $DIM  = "$e[2m"
$CYN  = "$e[96m"; $YEL  = "$e[93m"; $GRN  = "$e[92m"
$RED  = "$e[91m"; $BLU  = "$e[94m"; $GRY  = "$e[90m"; $WHT  = "$e[97m"
$BBLU = "$e[44m"

function Init-Win32 {
    try {
        Add-Type -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@ -Namespace WinCon -Name Native -ErrorAction Stop
    } catch {}
}

function Enable-VT {
    try {
        $h = [WinCon.Native]::GetStdHandle(-11)
        $m = 0u
        [WinCon.Native]::GetConsoleMode($h, [ref]$m) | Out-Null
        [WinCon.Native]::SetConsoleMode($h, $m -bor 4) | Out-Null
    } catch {}
}

function Set-Cursor([bool]$visible) { try { [Console]::CursorVisible = $visible } catch {} }

# ── 4. Layout & Render Helpers ────────────────────────────────────────────────────
function Get-Width { return [Math]::Max(60, [Console]::WindowWidth) }
function Get-Vis   { return [Math]::Max(3,  [Console]::WindowHeight - 11) }
function Strip-Ansi([string]$s) { return [System.Text.RegularExpressions.Regex]::Replace($s, '\x1b\[[0-9;]*m', '') }

function Write-Row([string]$line = '') {
    $pad = [Math]::Max(0, (Get-Width) - (Strip-Ansi $line).Length)
    [Console]::Write($line + (' ' * $pad) + "`n")
}
function Write-Sep([string]$ch = '-', [string]$col = $GRY) { Write-Row "$col$($ch * (Get-Width))$R" }

function Sync-Scroll {
    $vis = Get-Vis
    if ($State.Sel -lt $State.Scroll) { $State.Scroll = $State.Sel } 
    elseif ($State.Sel -ge ($State.Scroll + $vis)) { $State.Scroll = $State.Sel - $vis + 1 }
    $State.Scroll = [Math]::Max(0, $State.Scroll)
}

function Clamp-Sel {
    $n = $State.Items.Count
    $State.Sel = if ($n -eq 0) { 0 } else { [Math]::Max(0, [Math]::Min($State.Sel, $n - 1)) }
}

# ── 5. Data I/O (Direct Registry Method) ──────────────────────────────────────────
function Load-Data {
    try {
        $regPath = if ($State.Scope -eq 'User') { 'HKCU:\Environment' } else { 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
        
        # Reads directly from registry to bypass .NET expansion bugs
        $raw = Get-ItemPropertyValue -Path $regPath -Name 'Path' -ErrorAction SilentlyContinue
        
        $State.Items.Clear()
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $raw -split ';' | Where-Object { $_ -ne '' } | ForEach-Object { $State.Items.Add($_) }
        }
        $State.Sel    = [Math]::Min($State.Sel, [Math]::Max(0, $State.Items.Count - 1))
        $State.Scroll = 0
        $State.Dirty  = $false
        $State.Msg    = "Loaded $($State.Scope) PATH successfully."
        $State.MsgOk  = $true
    } catch {
        $State.Items.Clear()
        $State.Msg   = "CRITICAL ERROR reading PATH: $($_.Exception.Message)"
        $State.MsgOk = $false
        Write-Log 'ERROR' "Failed to read PATH: $($_.Exception.Message)"
    }
    $State.Redraw = $true
}

function Save-Data {
    if ($State.Scope -eq 'Machine') {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            $State.Msg   = 'Administrator rights required to modify System PATH'
            $State.MsgOk = $false
            $State.Redraw = $true
            Write-Log 'WARN' "Save blocked — not running as Administrator (scope=$($State.Scope))"
            return
        }
    }
    try {
        $joined = ($State.Items.ToArray() | Where-Object { $_ -ne '' }) -join ';'
        $regPath = if ($State.Scope -eq 'User') { 'HKCU:\Environment' } else { 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
        
        # Preserve dynamic variables by saving as ExpandString (REG_EXPAND_SZ) if % is present
        $type = if ($joined -match '%') { 'ExpandString' } else { 'String' }
        Set-ItemProperty -Path $regPath -Name 'Path' -Value $joined -Type $type -Force
        
        # Broadcast WM_SETTINGCHANGE so Explorer/OS immediately sees the change
        try {
            $HWND_BROADCAST   = [IntPtr]0xffff
            $WM_SETTINGCHANGE = 0x001A
            $result           = [UIntPtr]::Zero
            [WinCon.Native]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$result) | Out-Null
        } catch {}

        $State.Dirty  = $false
        $State.Msg    = "Saved $($State.Scope) PATH  ($($State.Items.Count) entries)"
        $State.MsgOk  = $true
        Write-Log 'INFO' "SAVE scope=$($State.Scope) entries=$($State.Items.Count) length=$($joined.Length)"
    } catch {
        $State.Msg   = "Save failed: $($_.Exception.Message)"
        $State.MsgOk = $false
        Write-Log 'ERROR' "Save failed: $($_.Exception.Message)"
    }
    $State.Redraw = $true
}

# ── 6. UI Prompts ─────────────────────────────────────────────────────────────────
function Read-Prompt([string]$prompt, [string]$default = '') {
    Set-Cursor $true
    $buf  = $default; $pos = $buf.Length; $row = [Console]::WindowHeight - 1; $done = $false
    while (-not $done) {
        $W = Get-Width; $pre = "  $prompt  "
        [Console]::SetCursorPosition(0, $row); [Console]::Write(' ' * $W)
        [Console]::SetCursorPosition(0, $row); [Console]::Write("${CYN}${BOLD}$pre${R}${WHT}$buf${R}")
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
                    $buf = $buf.Insert($pos, [string]$k.KeyChar); $pos++
                }
            }
        }
    }
    Set-Cursor $false
    $State.Redraw = $true
    return $buf
}

function Confirm-Prompt([string]$msg) {
    Set-Cursor $true
    $row = [Console]::WindowHeight - 1
    [Console]::SetCursorPosition(0, $row); [Console]::Write(' ' * (Get-Width))
    [Console]::SetCursorPosition(0, $row); [Console]::Write("${YEL}${BOLD}  $msg  [y/N]: ${R}")
    $k = [Console]::ReadKey($true)
    Set-Cursor $false
    $State.Redraw = $true
    return ($k.KeyChar -eq 'y' -or $k.KeyChar -eq 'Y')
}

# ── 7. Business Logic (Controllers) ───────────────────────────────────────────────
function Invoke-Add {
    $val = Read-Prompt 'New PATH entry:'
    if ([string]::IsNullOrWhiteSpace($val)) { $State.Msg = 'Add cancelled.'; $State.MsgOk = $true; return }
    $val = $val.Trim().Trim('"')
    if ($State.Items.Contains($val)) { $State.Msg = 'Duplicate — entry already exists.'; $State.MsgOk = $false; return }
    
    $State.Items.Add($val)
    $State.Sel    = $State.Items.Count - 1
    $State.Dirty  = $true
    $exists       = [System.IO.Directory]::Exists($val)
    $State.Msg    = if ($exists) { "Added: $val" } else { "Added (directory not found on disk): $val" }
    $State.MsgOk  = $true
    Write-Log 'INFO' "ADD scope=$($State.Scope) entry='$val' exists=$exists"
}

function Invoke-Edit {
    if ($State.Items.Count -eq 0) { return }
    $cur = $State.Items[$State.Sel]
    $val = Read-Prompt 'Edit entry:' $cur
    if ($null -eq $val) { $State.Msg = 'Edit cancelled.'; $State.MsgOk = $true; return }
    $val = $val.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($val)) { $State.Msg = 'Value cannot be empty.'; $State.MsgOk = $false; return }
    if ($val -eq $cur) { $State.Msg = 'No changes made.'; $State.MsgOk = $true; return }
    
    $State.Items[$State.Sel] = $val
    $State.Dirty = $true
    $State.Msg   = "Updated entry $($State.Sel + 1)."
    $State.MsgOk = $true
    Write-Log 'INFO' "EDIT scope=$($State.Scope) index=$($State.Sel) old='$cur' new='$val'"
}

function Invoke-Delete {
    if ($State.Items.Count -eq 0) { return }
    $e    = $State.Items[$State.Sel]
    $disp = if ($e.Length -gt 55) { $e.Substring(0, 52) + '...' } else { $e }
    if (Confirm-Prompt "Delete '$disp'?") {
        $State.Items.RemoveAt($State.Sel)
        Clamp-Sel
        $State.Dirty = $true; $State.Msg = 'Entry deleted.'; $State.MsgOk = $true
        Write-Log 'INFO' "DELETE scope=$($State.Scope) entry='$e'"
    } else {
        $State.Msg = 'Delete cancelled.'; $State.MsgOk = $true
    }
}

function Invoke-MoveUp {
    $i = $State.Sel
    if ($i -le 0) { return }
    $tmp = $State.Items[$i - 1]
    $State.Items[$i - 1] = $State.Items[$i]
    $State.Items[$i]     = $tmp
    $State.Sel--
    $State.Dirty = $true; $State.Msg = 'Moved up.'; $State.MsgOk = $true
    Write-Log 'INFO' "MOVE scope=$($State.Scope) entry='$($State.Items[$State.Sel])' from=$i to=$($State.Sel)"
}

function Invoke-MoveDown {
    $i = $State.Sel
    if ($i -ge $State.Items.Count - 1) { return }
    $tmp = $State.Items[$i + 1]
    $State.Items[$i + 1] = $State.Items[$i]
    $State.Items[$i]     = $tmp
    $State.Sel++
    $State.Dirty = $true; $State.Msg = 'Moved down.'; $State.MsgOk = $true
    Write-Log 'INFO' "MOVE scope=$($State.Scope) entry='$($State.Items[$State.Sel])' from=$i to=$($State.Sel)"
}

function Invoke-ToggleScope {
    if ($State.Dirty -and -not (Confirm-Prompt 'Discard unsaved changes and switch scope?')) {
        $State.Msg = 'Cancelled.'; $State.MsgOk = $true; return
    }
    $prevScope   = $State.Scope
    $State.Scope = if ($State.Scope -eq 'User') { 'Machine' } else { 'User' }
    Load-Data
    $State.Msg   = "Switched to $($State.Scope) PATH"
    $State.MsgOk = $true
    Write-Log 'INFO' "SCOPE from=$prevScope to=$($State.Scope) entries=$($State.Items.Count)"
}

function Invoke-Reload {
    if ($State.Dirty -and -not (Confirm-Prompt 'Discard unsaved changes and reload?')) {
        $State.Msg = 'Cancelled.'; $State.MsgOk = $true; return
    }
    Load-Data
    $State.Msg   = "Reloaded $($State.Scope) PATH"
    $State.MsgOk = $true
    Write-Log 'INFO' "RELOAD scope=$($State.Scope) entries=$($State.Items.Count)"
}

function Invoke-Quit {
    if ($State.Dirty) {
        if (Confirm-Prompt 'Quit with unsaved changes?') { $State.Run = $false }
    } else {
        $State.Run = $false
    }
}

# ── 8. Render Engine ──────────────────────────────────────────────────────────────
function Draw-UI {
    [Console]::SetCursorPosition(0, 0)

    # Title bar
    $uTab  = if ($State.Scope -eq 'User')    { "${BBLU}${WHT}${BOLD} USER ${R}"   } else { "${GRY} USER ${R}"   }
    $mTab  = if ($State.Scope -eq 'Machine') { "${BBLU}${WHT}${BOLD} SYSTEM ${R}" } else { "${GRY} SYSTEM ${R}" }
    $dFlag = if ($State.Dirty) { "${YEL}${BOLD} [unsaved]${R}" } else { "${GRN} [saved]${R}" }
    Write-Row "${CYN}${BOLD}  PATH MANAGER${R}   $uTab $mTab   $dFlag"
    Write-Sep '=' $BLU

    # Column header
    Write-Row "${GRY}${BOLD}   #   Path${R}"
    Write-Sep '-' $GRY

    # Entry rows
    $vis   = Get-Vis
    $count = $State.Items.Count
    $W     = Get-Width

    if ($count -eq 0) {
        Write-Row "${DIM}   (no entries)  Press A to add one.${R}"
        for ($i = 1; $i -lt $vis; $i++) { Write-Row }
    } else {
        for ($row = 0; $row -lt $vis; $row++) {
            $idx = $row + $State.Scroll
            if ($idx -ge $count) { Write-Row; continue }

            $path    = $State.Items[$idx]
            $num     = '{0,3}' -f ($idx + 1)
            $isSel   = ($idx -eq $State.Sel)
            $exists  = [System.IO.Directory]::Exists($path) -or [System.IO.File]::Exists($path)
            $maxLen  = $W - 9
            $display = if ($path.Length -gt $maxLen) { $path.Substring(0, $maxLen - 3) + '...' } else { $path }

            if ($isSel) {
                $pCol = if ($exists) { $WHT } else { $RED }
                Write-Row "${BBLU}${YEL}${BOLD} > ${R}${BBLU}${GRY}$num ${R}${BBLU}${pCol} $display ${R}"
            } else {
                $pCol = if ($exists) { $R } else { $RED }
                Write-Row "   $num  ${pCol}$display${R}"
            }
        }
    }

    # Footer
    Write-Sep '-' $GRY

    $total = if ($count -gt 0) { (($State.Items.ToArray()) -join ';').Length } else { 0 }
    $info  = if ($count -gt $vis) {
        "${GRY}  $count entries, showing $($State.Scroll+1)-$([Math]::Min($State.Scroll+$vis,$count))   PATH length: $total chars${R}"
    } else {
        "${GRY}  $count entries   PATH length: $total chars${R}"
    }
    Write-Row $info

    $mCol = if ($State.MsgOk) { $GRN } else { $RED }
    Write-Row $(if ($State.Msg) { "${mCol}  $($State.Msg)${R}" } else { '' })

    Write-Sep '=' $BLU
    Write-Row "${GRY}  ${CYN}Up/Down${GRY} Navigate   ${CYN}A${GRY} Add   ${CYN}E${GRY} Edit   ${CYN}Del${GRY}/${CYN}X${GRY} Delete   ${CYN}[${GRY}/${CYN}]${GRY} Move Up/Down   ${CYN}Tab${GRY} Scope${R}"
    Write-Row "${GRY}  ${CYN}Home/End${GRY} First/Last   ${CYN}PgUp/Dn${GRY} Page   ${CYN}S${GRY} Save   ${CYN}R${GRY} Reload   ${CYN}Q/Esc${GRY} Quit   ${DIM}Log: $($State.LogFile)${R}"
}

# ── 9. Command Routing ────────────────────────────────────────────────────────────
$KeyBindings = @{
    ([ConsoleKey]::UpArrow)   = { if ($State.Sel -gt 0) { $State.Sel--; $State.Redraw = $true } }
    ([ConsoleKey]::DownArrow) = { if ($State.Sel -lt $State.Items.Count - 1) { $State.Sel++; $State.Redraw = $true } }
    ([ConsoleKey]::PageUp)    = { $State.Sel = [Math]::Max(0, $State.Sel - (Get-Vis)); $State.Redraw = $true }
    ([ConsoleKey]::PageDown)  = { $State.Sel = [Math]::Min([Math]::Max(0, $State.Items.Count - 1), $State.Sel + (Get-Vis)); $State.Redraw = $true }
    ([ConsoleKey]::Home)      = { $State.Sel = 0; $State.Redraw = $true }
    ([ConsoleKey]::End)       = { $State.Sel = [Math]::Max(0, $State.Items.Count - 1); $State.Redraw = $true }
    ([ConsoleKey]::Delete)    = { Invoke-Delete }
    ([ConsoleKey]::Tab)       = { Invoke-ToggleScope }
    ([ConsoleKey]::Escape)    = { Invoke-Quit }
}

$CharBindings = @{
    'a' = { Invoke-Add }
    'e' = { Invoke-Edit }
    'x' = { Invoke-Delete }
    '[' = { Invoke-MoveUp }
    ']' = { Invoke-MoveDown }
    's' = { Save-Data }
    'r' = { Invoke-Reload }
    'q' = { Invoke-Quit }
}

# ── 10. Main Execution Loop ───────────────────────────────────────────────────────
function Main {
    Init-Log
    Init-Win32
    Enable-VT
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    Set-Cursor $false

    Write-Log 'INFO' '── SESSION START ──'
    Clear-Host
    Load-Data

    while ($State.Run) {
        if ($State.Redraw) {
            Sync-Scroll
            Draw-UI
            $State.Redraw = $false
        }

        # Halt and wait for input
        $k    = [Console]::ReadKey($true)
        $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
        
        # Clear previous transient messages on any keypress
        if ($State.Msg) { $State.Msg = ''; $State.Redraw = $true }

        if ($ctrl -and $k.Key -eq [ConsoleKey]::C) { $State.Run = $false; continue }

        if ($KeyBindings.ContainsKey($k.Key)) {
            & $KeyBindings[$k.Key]
        } else {
            $char = [string][char]::ToLower($k.KeyChar)
            if ($CharBindings.ContainsKey($char)) {
                & $CharBindings[$char]
            }
        }
    }

    Clear-Host
    Set-Cursor $true
    Write-Log 'INFO' '── SESSION END ──'
    Write-Host 'PATH Manager closed.'
    Write-Host "Log: $($State.LogFile)"
}

try     { Main }
finally { Set-Cursor $true }