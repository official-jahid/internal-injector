<#
.SYNOPSIS
  One-liner REGIX injector: downloads REGIX.dll, prepares BlueStacks (HD-Player +
  ADB + Free Fire) and injects the DLL into HD-Player.exe via LoadLibraryW.
.DESCRIPTION
  Primary (one-liner) mode - run in an ELEVATED PowerShell:

      irm https://raw.githubusercontent.com/official-jahid/internal-injector/main/Inject-REGIX.ps1 | iex

  What it does, in this order (every step prints a [REGIX] line to the console):

    1. A 32-bit PowerShell host is relaunched through the 64-bit host (an x86 host
       cannot inject into the x64 game).
    2. Elevation is required and checked. There is no UAC auto-relaunch.
    3. Gets the DLL: local -DllPath / Build\REGIX.dll / Build\REIMANOS.dll first,
       otherwise a fresh download from the raw `main` branch into %TEMP%.
    4. Finds the BlueStacks installation through the HKLM\SOFTWARE\BlueStacks_msi5
       (MSI App Player) and HKLM\SOFTWARE\BlueStacks_nxt (BlueStacks 5) registry
       keys, then reads bluestacks.conf for the instance name and the ADB ports.
    5. Picks the running HD-Player.exe of the preferred install (MSI App Player
       first, then BlueStacks 5); with several instances it takes the newest one,
       -Instance / -ProcessId override that. If no player runs at all it starts
       "HD-Player.exe --instance <image>" itself and waits for the Android boot.
    6. Connects HD-Adb.exe from the install folder (device list first, then a
       TCP-verified "connect 127.0.0.1:<adb port>" scan) and starts Free Fire
       (com.dts.freefireth - Free Fire Max is never launched or touched).
    7. Injects the DLL into HD-Player.exe with a remote LoadLibraryW thread and
       VERIFIES it: the target's module list must really contain REGIX.dll, and the
       game is watched for -VerifySeconds afterwards.
    8. Deletes everything this run created (temp DLL, temp relaunch script, and the
       ADB server if this run started it) and closes PowerShell: exit 0 on success,
       exit 1 on failure. No log file is written anywhere - the console is the only
       record, and on failure the window stays open for 10 seconds so the red error
       can be read.

  The injector itself never terminates the game. If HD-Player stops right after a
  VERIFIED load, the loaded DLL ended it: REGIX.dll runs its own environment checks
  (it shells out "cat /proc/$(pidof com.dts.freefireth)/maps | grep libil2cpp.so",
  talks to HD-Adb and contains TerminateProcess/IsDebuggerPresent), so a missing or
  outdated Free Fire build makes the DLL stop its own host process. Nothing in this
  script can prevent that - the steps above make sure the environment the DLL checks
  is actually prepared *before* injecting.

.PARAMETER DllPath
  Optional. Use a local DLL and skip the download entirely.
.PARAMETER VerifySeconds
  How long to watch the game after the DLL is loaded before reporting success.
  Default 30, minimum 5.
.PARAMETER Instance
  Optional. BlueStacks instance name (for example Pie64) to use or to start.
.PARAMETER ProcessId
  Optional. Inject into this specific HD-Player.exe PID instead of auto-selecting.
.PARAMETER DryRun
  Rehearse the whole chain (discovery, player start, ADB, Free Fire, DLL download)
  and report what would happen, but do not inject. A dry run also works in a
  non-elevated console.
.EXAMPLE
  irm https://raw.githubusercontent.com/official-jahid/internal-injector/main/Inject-REGIX.ps1 | iex
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Inject-REGIX.ps1 -DryRun
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Inject-REGIX.ps1 -DllPath "C:\builds\REGIX.dll" -VerifySeconds 60
#>
param(
  [string]$DllPath = "",
  [int]$VerifySeconds = 30,
  [string]$Instance = "",
  [int]$ProcessId = 0,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

# TLS 1.2 for Windows PowerShell 5.1 (used by both the relaunch and DLL downloads).
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# ---- Fixed configuration -----------------------------------------------------
$RepoRawBase      = "https://raw.githubusercontent.com/official-jahid/internal-injector/main"
$DllUrl           = "$RepoRawBase/REGIX.dll"
$ScriptUrl        = "$RepoRawBase/Inject-REGIX.ps1"   # used for the 32-bit -> 64-bit relaunch
$ProcessName      = "HD-Player"                       # fixed target: BlueStacks 5 / MSI App Player
$GamePackage      = "com.dts.freefireth"              # Free Fire - the package REGIX.dll looks for
$GamePackageMax   = "com.dts.freefiremax"             # Free Fire Max - never launched, never touched
$GameMainActivity = "com.dts.freefireth.FFMainActivity"
$MinDllBytes      = 5MB                               # sanity floor: the real DLL is ~27 MB
$DownloadRetry    = 1
$RemoteWaitMs     = 60000                             # how long to wait for the target's LoadLibraryW
$FailWaitSec      = 10                                # keep the console open this long on failure
$PlayerStartSec   = 120                               # wait for a freshly started HD-Player
$BootTimeoutSec   = 180                               # wait for ADB + "sys.boot_completed"
$GameLaunchSec    = 90                                # wait for Free Fire after launching it
$AdbLocalPort     = 5037                              # local ADB server port (only cleaned if we started it)
$AdbScanPorts     = @(5555, 5556, 5557, 5558, 5562, 5565, 5572, 5575, 5582, 5585, 5592, 5595, 6767, 6969, 5554)

$script:TempArtifacts       = New-Object System.Collections.Generic.List[string]
$script:AdbPath             = ""
$script:AdbWorkDir          = ""
$script:AdbSerial           = ""
$script:AdbUsedServer       = $false
$script:AdbServerWasRunning = $false
$script:InstallExes         = @()
$script:StepNo              = 0

# ---- Console helpers ---------------------------------------------------------
function Write-Step([string]$Text) {
  $script:StepNo++
  Write-Host ("[REGIX] Step {0}: {1}" -f $script:StepNo, $Text) -ForegroundColor Cyan
}
function Write-Info([string]$Text) { Write-Host ("[REGIX]   {0}" -f $Text) -ForegroundColor Gray }
function Write-Warn([string]$Text) { Write-Host ("[REGIX] ! {0}" -f $Text) -ForegroundColor Yellow }

# Delete everything this run created (best effort). Stale %TEMP% copies from earlier
# runs are deleted too - a copy that is still loaded inside HD-Player stays locked
# and is cleaned up by the next run.
function Remove-TempArtifacts {
  foreach ($f in $script:TempArtifacts) {
    try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch { }
  }
  $script:TempArtifacts.Clear()
  try {
    Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter "REGIX*.dll" -ErrorAction SilentlyContinue |
      ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { } }
  } catch { }
}

# Leave no background process behind: stop the local ADB server only if this run
# started it (a server that BlueStacks started is left untouched).
function Stop-AdbServerIfWeStartedIt {
  if ($script:AdbUsedServer -and -not $script:AdbServerWasRunning -and $script:AdbPath) {
    try { [void](Invoke-Adb @('kill-server')) } catch { }
  }
}

function Fail([string]$Message) {
  Write-Host ""
  Write-Host "[REGIX] ERROR: $Message" -ForegroundColor Red
  Stop-AdbServerIfWeStartedIt
  Remove-TempArtifacts
  if (-not $DryRun) {
    Write-Host ""
    Write-Host ("[REGIX] This window stays open {0} seconds so the error can be read, then PowerShell closes (exit 1)." -f $FailWaitSec) -ForegroundColor DarkGray
    Start-Sleep -Seconds $FailWaitSec
  }
  exit 1
}

function Success([string]$Message) {
  Write-Host ""
  Write-Host $Message -ForegroundColor Green
  Stop-AdbServerIfWeStartedIt
  Remove-TempArtifacts
  exit 0
}

# ---- Bitness guard: a 32-bit PowerShell cannot inject into the x64 game ------
if (-not [Environment]::Is64BitProcess) {
  if (-not [Environment]::Is64BitOperatingSystem) { Fail "32-bit Windows detected. REGIX requires 64-bit Windows (HD-Player.exe is x64)." }
  if ($env:REGIX_X64_RELAUNCH -eq '1') { Fail "Still running 32-bit PowerShell after relaunch. Open 'Windows PowerShell' (64-bit) manually and run the command again." }

  $sysNative = Join-Path $env:SystemRoot 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $sysNative)) { Fail "64-bit PowerShell host not found: $sysNative" }

  if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
    # File mode: re-run the same script file in 64-bit PowerShell.
    $relaunchTarget = $PSCommandPath
  } else {
    # irm | iex mode: fetch this same script from the repo and run it as a file.
    $relaunchTarget = Join-Path ([IO.Path]::GetTempPath()) 'REGIX-Inject-x64.ps1'
    try { Invoke-WebRequest -Uri $ScriptUrl -OutFile $relaunchTarget -UseBasicParsing -TimeoutSec 30 } catch { Fail "Could not fetch the script for the 64-bit relaunch: $($_.Exception.Message)" }
    $script:TempArtifacts.Add($relaunchTarget) | Out-Null
  }

  Write-Host "[REGIX] 32-bit PowerShell detected. Relaunching in 64-bit PowerShell..." -ForegroundColor Cyan
  $env:REGIX_X64_RELAUNCH = '1'
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $relaunchTarget)
  if ($PSBoundParameters.ContainsKey('DllPath'))       { $argList += @('-DllPath', $DllPath) }
  if ($PSBoundParameters.ContainsKey('VerifySeconds')) { $argList += @('-VerifySeconds', [string]$VerifySeconds) }
  if ($PSBoundParameters.ContainsKey('Instance'))      { $argList += @('-Instance', $Instance) }
  if ($PSBoundParameters.ContainsKey('ProcessId'))     { $argList += @('-ProcessId', [string]$ProcessId) }
  if ($DryRun) { $argList += '-DryRun' }
  try { & $sysNative @argList } catch { Fail "Failed to start 64-bit PowerShell: $($_.Exception.Message)" }
  $relaunchExit = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 1 }
  Remove-TempArtifacts          # the 64-bit child is done with the fetched copy
  exit $relaunchExit
}

# ---- Elevation ---------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
  Fail ("Not running as Administrator.`n" +
        "  Opening the x64 game process with full access needs an elevated host.`n" +
        "  Fix: close this window, right-click 'Windows PowerShell' (or 'Terminal') -> 'Run as administrator',`n" +
        "  and run the same one-liner again. Elevation is never requested automatically.")
}

$hostBits = 32
if ([Environment]::Is64BitProcess) { $hostBits = 64 }
$osBits = 32
if ([Environment]::Is64BitOperatingSystem) { $osBits = 64 }

Write-Host ""
Write-Host "==========================================================" -ForegroundColor DarkCyan
Write-Host " REGIX INJECTOR - BlueStacks 5 / MSI App Player (x64)" -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor DarkCyan
Write-Info ("PowerShell {0}, {1}-bit process on {2}-bit Windows {3}" -f $PSVersionTable.PSVersion.ToString(), $hostBits, $osBits, [Environment]::OSVersion.Version.ToString())
Write-Info ("Administrator: {0}" -f $isAdmin)
if ($DryRun) { Write-Warn "DRY RUN: the full chain is rehearsed, but the DLL is NOT injected." }

# ---- Native access -----------------------------------------------------------
if (-not ([System.Management.Automation.PSTypeName]"NativeRegixV3").Type) {
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeRegixV3 {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint a, bool b, uint c);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr a, uint s, uint t, uint p);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteProcessMemory(IntPtr h, IntPtr b, byte[] buf, uint s, out UIntPtr w);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetProcAddress(IntPtr m, string n);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetModuleHandle(string n);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr CreateRemoteThread(IntPtr h, IntPtr a, uint s, IntPtr e, IntPtr p, uint f, IntPtr g);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool VirtualFreeEx(IntPtr h, IntPtr a, uint s, uint t);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool IsWow64Process(IntPtr h, out bool w);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeThread(IntPtr h, out uint code);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("psapi.dll", SetLastError=true)] public static extern bool EnumProcessModulesEx(IntPtr h, IntPtr[] mods, uint cb, out uint needed, uint filter);
  [DllImport("psapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern uint GetModuleFileNameExW(IntPtr h, IntPtr mod, System.Text.StringBuilder name, uint size);
}
"@
}

function Test-TargetArch($proc) {
  # Try handle-based check first (needs rights), fall back to on-disk PE header.
  try {
    $wow = $false
    [NativeRegixV3]::IsWow64Process($proc.Handle, [ref]$wow) | Out-Null
    if ([IntPtr]::Size -eq 8 -and $wow) { return "x86" }
    return "x64"
  } catch { }
  try {
    $p = $proc.Path
    if (-not $p) {
      foreach ($cand in $script:InstallExes) {
        if (Test-Path -LiteralPath $cand) { $p = $cand; break }
      }
    }
    if ($p -and (Test-Path -LiteralPath $p)) {
      $fs = [System.IO.File]::OpenRead($p); $br = New-Object System.IO.BinaryReader($fs)
      $fs.Seek(60,0) | Out-Null; $pe = $br.ReadInt32(); $fs.Seek($pe+24,0) | Out-Null
      $magic = $br.ReadUInt16(); $fs.Close()
      if ($magic -eq 0x20B) { return "x64-disk" }
      if ($magic -eq 0x10B) { return "x86-disk" }
    }
  } catch { }
  return "unknown"
}

function Get-TargetModulePaths($hProc) {
  # Enumerate the target's loaded modules so success can be *verified* instead of
  # assumed from the remote thread's exit code. LIST_MODULES_ALL = 0x03.
  $cap = 4096
  $arr = New-Object IntPtr[] $cap
  $needed = [uint32]0
  $ok = [NativeRegixV3]::EnumProcessModulesEx($hProc, $arr, [uint32]($cap * [IntPtr]::Size), [ref]$needed, 0x03)
  if (-not $ok) { return @() }
  $count = [int]($needed / [IntPtr]::Size)
  if ($count -gt $cap) { $count = $cap }
  $list = New-Object System.Collections.Generic.List[string]
  $sb = New-Object System.Text.StringBuilder 1024
  for ($i = 0; $i -lt $count; $i++) {
    [void]$sb.Clear()
    $len = [NativeRegixV3]::GetModuleFileNameExW($hProc, $arr[$i], $sb, 1024)
    if ($len -gt 0) { $list.Add($sb.ToString()) }
  }
  return $list
}

# ---- ADB helpers ------------------------------------------------------------
# HD-Adb.exe is BlueStacks' own ADB client and needs its install folder as the
# working directory (it loads AdbWinApi.dll from there).
function Invoke-Adb {
  param([string[]]$AdbArgs)
  if (-not $script:AdbPath) { return "" }
  $full = @()
  if ($script:AdbSerial) { $full += @('-s', $script:AdbSerial) }
  $full += $AdbArgs
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    Push-Location -LiteralPath $script:AdbWorkDir
    try {
      $out = & $script:AdbPath @full 2>&1 | ForEach-Object { [string]$_ }
    } finally { Pop-Location }
    $script:AdbUsedServer = $true      # invoking adb spawned/reused the local server
    return ($out -join "`n")
  } catch {
    return ""
  } finally {
    $ErrorActionPreference = $prevEap
  }
}

# Fast raw-TCP probe: filters the (long) candidate ADB port list down to the ports
# that actually accept a connection, so "adb connect" is never left hanging.
function Test-TcpPort {
  param([string]$ComputerName, [int]$Port, [int]$TimeoutMs = 500)
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
    $client.EndConnect($iar)
    return $true
  } catch {
    return $false
  } finally {
    try { $client.Close() } catch { }
  }
}

# "adb devices" lists "<serial>\tdevice"; prefer a local emulator serial.
function Get-AdbDeviceSerial([string]$AdbOutput) {
  $fallback = ""
  if (-not $AdbOutput) { return "" }
  foreach ($line in ($AdbOutput -split "`r?`n")) {
    if ($line -match '^\s*(\S+)\s+device\b') {
      $cand = $Matches[1]
      if ($cand -match '^(127\.0\.0\.1|localhost|emulator-)') { return $cand }
      if (-not $fallback) { $fallback = $cand }
    }
  }
  return $fallback
}

# ---- BlueStacks discovery ---------------------------------------------------
# bluestacks.conf is a KEY="value" text file; read it into a hashtable.
function Get-ConfMap([string]$ConfPath) {
  $map = @{}
  if (-not $ConfPath) { return $map }
  if (-not (Test-Path -LiteralPath $ConfPath)) { return $map }
  foreach ($line in (Get-Content -LiteralPath $ConfPath -ErrorAction SilentlyContinue)) {
    if ($line -match '^\s*([A-Za-z0-9_.]+)\s*=\s*(.*?)\s*$') {
      $k = $Matches[1]
      $v = $Matches[2]
      if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2) }
      $map[$k] = $v
    }
  }
  return $map
}

# Instance (image) names: bst.installed_images plus every bst.instance.<name>.* key.
function Get-ConfInstances($ConfMap) {
  $names = New-Object System.Collections.Generic.List[string]
  if ($ConfMap.ContainsKey('bst.installed_images')) {
    foreach ($n in ($ConfMap['bst.installed_images'] -split ',')) {
      $t = $n.Trim()
      if ($t -and -not $names.Contains($t)) { $names.Add($t) }
    }
  }
  foreach ($k in $ConfMap.Keys) {
    if ($k -match '^bst\.instance\.([^.]+)\.') {
      $t = $Matches[1]
      if ($t -and -not $names.Contains($t)) { $names.Add($t) }
    }
  }
  return $names
}

# The emulator's ADB port for an instance: status.adb_port first (the actually
# bound one), then adb_port (the configured one).
function Get-InstancePort($ConfMap, [string]$Name) {
  if (-not $Name) { return 0 }
  foreach ($suffix in @('status.adb_port', 'adb_port')) {
    $k = "bst.instance.$Name.$suffix"
    if ($ConfMap.ContainsKey($k)) {
      $v = 0
      if ([int]::TryParse($ConfMap[$k], [ref]$v) -and $v -gt 0) { return $v }
    }
  }
  return 0
}

# Installations, MSI App Player (BlueStacks_msi5) first, then BlueStacks 5 (nxt).
# The HKLM\SOFTWARE\BlueStacks_* keys are authoritative and also cover custom
# install folders; the default Program Files paths are the fallback.
function Get-BlueStacksInstalls {
  $cands = New-Object System.Collections.Generic.List[object]
  foreach ($set in @(@('HKLM:\SOFTWARE\BlueStacks_msi5', 'msi5'), @('HKLM:\SOFTWARE\WOW6432Node\BlueStacks_msi5', 'msi5'),
                     @('HKLM:\SOFTWARE\BlueStacks_nxt', 'BlueStacks5'), @('HKLM:\SOFTWARE\WOW6432Node\BlueStacks_nxt', 'BlueStacks5'))) {
    try {
      $v = Get-ItemProperty -Path $set[0] -ErrorAction SilentlyContinue
      if ($v -and $v.InstallDir) {
        $dd = $null
        if ($v.UserDefinedDir) { $dd = $v.UserDefinedDir }
        elseif ($v.DataDir) { $dd = $v.DataDir }
        $cands.Add([pscustomobject]@{ Dir = $v.InstallDir; DataDir = $dd; Kind = $set[1] })
      }
    } catch { }
  }
  foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $pf) { continue }
    $cands.Add([pscustomobject]@{ Dir = (Join-Path $pf 'BlueStacks_msi5'); DataDir = $null; Kind = 'msi5' })
    $cands.Add([pscustomobject]@{ Dir = (Join-Path $pf 'BlueStacks_nxt'); DataDir = $null; Kind = 'BlueStacks5' })
  }

  $programData = $env:ProgramData
  if (-not $programData) { $programData = $env:ALLUSERSPROFILE }

  $found = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  foreach ($c in $cands) {
    if (-not $c.Dir) { continue }
    $dir = $c.Dir.TrimEnd('\')
    $exe = Join-Path $dir 'HD-Player.exe'
    if (-not (Test-Path -LiteralPath $exe)) { continue }
    $key = $dir.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true

    $kind = $c.Kind
    if ($dir -match 'msi5') { $kind = 'msi5' }
    elseif ($dir -match 'BlueStacks_nxt') { $kind = 'BlueStacks5' }

    $adb = Join-Path $dir 'HD-Adb.exe'
    if (-not (Test-Path -LiteralPath $adb)) { $adb = Join-Path $dir 'adb.exe' }
    if (-not (Test-Path -LiteralPath $adb)) { $adb = "" }

    $confDirs = New-Object System.Collections.Generic.List[string]
    if ($c.DataDir) { $confDirs.Add($c.DataDir) }
    if ($programData) {
      $confDirs.Add((Join-Path $programData 'BlueStacks_msi5'))
      $confDirs.Add((Join-Path $programData 'BlueStacks_nxt'))
    }
    $dataDir = $c.DataDir
    $conf = ""
    foreach ($d in $confDirs) {
      $ce = Join-Path $d 'bluestacks.conf'
      if (Test-Path -LiteralPath $ce) {
        $conf = $ce
        if (-not $dataDir) { $dataDir = $d }
        break
      }
    }
    if (-not $dataDir) { $dataDir = "" }
    $found.Add([pscustomobject]@{ Kind = $kind; Dir = $dir; Exe = $exe; Adb = $adb; DataDir = $dataDir; Conf = $conf })
  }

  $ordered = @()
  $ordered += @($found | Where-Object { $_.Kind -eq 'msi5' })
  $ordered += @($found | Where-Object { $_.Kind -ne 'msi5' })
  return $ordered
}

# ---- HD-Player instance helpers ---------------------------------------------
# Running HD-Player processes with their --instance argument (the command line
# needs CIM; Get-Process alone cannot show it).
function Get-PlayerProcesses {
  $list = New-Object System.Collections.Generic.List[object]
  $cis = $null
  try { $cis = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'HD-Player.exe'" -ErrorAction SilentlyContinue } catch { $cis = $null }
  if (-not $cis) {
    foreach ($p in (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
      $started = $null
      $path = $null
      try { $started = $p.StartTime } catch { }
      try { $path = $p.Path } catch { }
      $list.Add([pscustomobject]@{ Id = $p.Id; Path = $path; Instance = $null; Started = $started })
    }
    return $list
  }
  foreach ($c in $cis) {
    $inst = $null
    try {
      if ($c.CommandLine -and $c.CommandLine -match '--instance\s+([^\s"]+)') { $inst = $Matches[1] }
    } catch { }
    $list.Add([pscustomobject]@{ Id = [int]$c.ProcessId; Path = $c.ExecutablePath; Instance = $inst; Started = $c.CreationDate })
  }
  return @($list | Sort-Object -Property Started -Descending)
}

function Format-PlayerList($Players) {
  if (-not $Players) { return "none" }
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($p in @($Players)) {
    $inst = ""
    if ($p.Instance) { $inst = " instance=$($p.Instance)" }
    $path = ""
    if ($p.Path) { $path = " $($p.Path)" }
    $parts.Add(("PID {0}{1}{2}" -f $p.Id, $inst, $path))
  }
  if ($parts.Count -eq 0) { return "none" }
  return ($parts -join "; ")
}

# Choose the injection target: -ProcessId wins, otherwise the newest HD-Player of
# the preferred install (MSI App Player -> BlueStacks 5). Returns both the process
# and the install it belongs to (ADB must come from that same install).
function Select-PlayerTarget {
  param($Installs, $Players, [string]$WantInstance, [int]$WantPid)
  $sel = [pscustomobject]@{ Player = $null; Install = $null }

  $findInstall = {
    param($path)
    if (-not $path) { return $null }
    $dir = ([IO.Path]::GetDirectoryName($path)).TrimEnd('\')
    foreach ($i in $Installs) { if ($i.Dir.TrimEnd('\') -ieq $dir) { return $i } }
    return $null
  }

  if ($WantPid -gt 0) {
    $p = @($Players | Where-Object { $_.Id -eq $WantPid }) | Select-Object -First 1
    if (-not $p) { Fail ("-ProcessId {0} is not a running {1}.exe. Running: {2}" -f $WantPid, $ProcessName, (Format-PlayerList $Players)) }
    $sel.Player = $p
    $sel.Install = & $findInstall $p.Path
    return $sel
  }

  $pool = @($Players)
  if ($WantInstance) { $pool = @($pool | Where-Object { $_.Instance -and ($_.Instance -ieq $WantInstance) }) }

  foreach ($inst in $Installs) {
    $m = @($pool | Where-Object { $_.Path -and ([IO.Path]::GetDirectoryName($_.Path)).TrimEnd('\') -ieq $inst.Dir.TrimEnd('\') }) | Select-Object -First 1
    if ($m) {
      $sel.Player = $m
      $sel.Install = $inst
      return $sel
    }
  }
  if ($pool.Count -gt 0) {
    $sel.Player = $pool | Select-Object -First 1
    $sel.Install = & $findInstall $sel.Player.Path
  }
  return $sel
}

# ---- ADB session + Android boot ---------------------------------------------
# Returns $true when a device is connected. First the already-known device list is
# used, then the candidate ports (instance ADB port from bluestacks.conf, the other
# instances' ports, and finally the port list HD-Adb itself probes) are TCP-checked
# before "adb connect" is attempted on them.
function Initialize-AdbSession {
  param([int]$InstancePort, [int[]]$ExtraPorts, [int]$WaitSeconds)
  if (-not $script:AdbPath) {
    Write-Warn "HD-Adb.exe was not found in the BlueStacks install folder - ADB steps are skipped."
    return $false
  }
  Write-Info ("ADB client: {0}" -f $script:AdbPath)

  # Only a server that BlueStacks already started is left running at the end.
  if (Test-TcpPort '127.0.0.1' $AdbLocalPort 300) { $script:AdbServerWasRunning = $true }

  $serial = Get-AdbDeviceSerial (Invoke-Adb @('devices'))
  if ($serial) {
    $script:AdbSerial = $serial
    Write-Info ("ADB device already available: {0}" -f $serial)
    return $true
  }

  $ports = New-Object System.Collections.Generic.List[int]
  if ($InstancePort -gt 0) { $ports.Add($InstancePort) }
  foreach ($p in @($ExtraPorts)) { if ($p -gt 0 -and -not $ports.Contains($p)) { $ports.Add($p) } }
  foreach ($p in $AdbScanPorts) { if (-not $ports.Contains($p)) { $ports.Add($p) } }
  Write-Info ("Waiting for an emulator ADB port ({0} candidates checked on 127.0.0.1)..." -f $ports.Count)

  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  while ((Get-Date) -lt $deadline) {
    foreach ($p in $ports) {
      if (-not (Test-TcpPort '127.0.0.1' $p 400)) { continue }
      [void](Invoke-Adb @('connect', ("127.0.0.1:{0}" -f $p)))
      $serial = Get-AdbDeviceSerial (Invoke-Adb @('devices'))
      if ($serial) {
        $script:AdbSerial = $serial
        Write-Info ("ADB connected on emulator port {0}: {1}" -f $p, $serial)
        return $true
      }
    }
    Start-Sleep -Seconds 3
  }
  return $false
}

# Wait for Android to finish booting inside the emulator.
function Wait-ForBoot {
  param([int]$WaitSeconds)
  if (-not $script:AdbSerial) { return $false }
  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  while ((Get-Date) -lt $deadline) {
    if ((Invoke-Adb @('shell', 'getprop', 'sys.boot_completed')) -match '1') {
      Write-Info "Android boot completed (sys.boot_completed=1)."
      return $true
    }
    Start-Sleep -Seconds 3
  }
  Write-Warn ("Android boot did not report sys.boot_completed=1 within {0} s." -f $WaitSeconds)
  return $false
}

# ---- Free Fire ---------------------------------------------------------------
# Launch Free Fire (com.dts.freefireth) - the package REGIX.dll looks for. Free
# Fire Max is never launched and never touched.
function Start-FreeFireAndWait {
  if (-not $script:AdbSerial) {
    Write-Warn "No ADB device, so Free Fire cannot be started automatically."
    return $false
  }

  if ((Invoke-Adb @('shell', 'pm', 'list', 'packages')) -match [regex]::Escape($GamePackageMax)) {
    Write-Info ("Note: Free Fire Max ({0}) is installed too - it is never launched or touched." -f $GamePackageMax)
  }
  $packages = Invoke-Adb @('shell', 'pm', 'list', 'packages')
  if ($packages -notmatch [regex]::Escape($GamePackage)) {
    Write-Warn ("Free Fire ({0}) is not installed in this BlueStacks instance - install Free Fire (not Free Fire Max) in the running instance." -f $GamePackage)
    return $false
  }

  $pidOf = Invoke-Adb @('shell', 'pidof', $GamePackage)
  if ($pidOf -match '\d') {
    Write-Info ("Free Fire is already running (pid {0})." -f $pidOf.Trim())
    return $true
  }

  Write-Info "Starting Free Fire..."
  [void](Invoke-Adb @('shell', 'monkey', '-p', $GamePackage, '-c', 'android.intent.category.LAUNCHER', '1'))
  $deadline = (Get-Date).AddSeconds($GameLaunchSec)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $pidOf = Invoke-Adb @('shell', 'pidof', $GamePackage)
    if ($pidOf -match '\d') {
      Write-Info ("Free Fire is running (pid {0})." -f $pidOf.Trim())
      return $true
    }
  }

  Write-Info "monkey did not start it, trying the explicit launcher activity..."
  [void](Invoke-Adb @('shell', 'am', 'start', '-n', ("{0}/{1}" -f $GamePackage, $GameMainActivity)))
  Start-Sleep -Seconds 8
  $pidOf = Invoke-Adb @('shell', 'pidof', $GamePackage)
  if ($pidOf -match '\d') {
    Write-Info ("Free Fire is running (pid {0})." -f $pidOf.Trim())
    return $true
  }
  return $false
}

# ---- Resolve a local DLL first (file mode); otherwise download to %TEMP% ------
if (-not ($DllPath -and (Test-Path -LiteralPath $DllPath))) {
  # No -DllPath / default: prefer Build\REGIX.dll, then legacy REIMANOS.dll (file mode only).
  if ($PSScriptRoot) {
    $local = Join-Path $PSScriptRoot "Build\REGIX.dll"
    if (Test-Path -LiteralPath $local) {
      $DllPath = $local
    } else {
      $legacy = Join-Path $PSScriptRoot "Build\REIMANOS.dll"
      if (Test-Path -LiteralPath $legacy) {
        Write-Warn "REGIX.dll not found next to the script, using the legacy $legacy."
        $DllPath = $legacy
      }
    }
  }
}

$dllTemp = Join-Path ([IO.Path]::GetTempPath()) "REGIX.dll"
if (-not ($DllPath -and (Test-Path -LiteralPath $DllPath))) {
  Write-Step "Downloading REGIX.dll"
  Write-Info ("URL  : {0}" -f $DllUrl)
  Write-Info ("Dest : {0}" -f $dllTemp)

  $downloaded = $false
  try { Add-Type -AssemblyName System.Net.Http } catch { }   # PS 5.1: not loaded by default
  for ($attempt = 0; $attempt -le $DownloadRetry; $attempt++) {
    try {
      if ($attempt -gt 0) { Write-Info ("Retrying the download ({0}/{1})..." -f $attempt, $DownloadRetry) }
      $client = New-Object System.Net.Http.HttpClient
      $client.Timeout = [TimeSpan]::FromSeconds(180)
      $resp = $client.GetAsync($DllUrl, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
      if (-not $resp.IsSuccessStatusCode) { throw "HTTP $([int]$resp.StatusCode) $($resp.ReasonPhrase)" }
      $total = $resp.Content.Headers.ContentLength
      if (-not $total -or $total -le 0) { $total = $MinDllBytes }
      $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
      try { $fs = [IO.File]::Create($dllTemp) }
      catch {
        # Stale copy still locked (e.g. previously loaded by HD-Player): use a unique name.
        $dllTemp = Join-Path ([IO.Path]::GetTempPath()) ("REGIX_{0}.dll" -f [guid]::NewGuid().ToString("N").Substring(0, 8))
        Write-Warn ("The temp file is locked; using {0}" -f $dllTemp)
        $fs = [IO.File]::Create($dllTemp)
      }
      $script:TempArtifacts.Add($dllTemp) | Out-Null
      try {
        $buf = New-Object byte[] (1MB)
        $read = 0; $done = [long]0
        while (($read = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
          $fs.Write($buf, 0, $read)
          $done += $read
          $pct = [Math]::Min(100, [int](100 * $done / $total))
          Write-Progress -Activity "Downloading REGIX.dll" -Status ("{0:N1} / {1:N1} MB ({2}%)" -f ($done/1MB), ($total/1MB), $pct) -PercentComplete $pct
        }
        Write-Progress -Activity "Downloading REGIX.dll" -Completed
      } finally { $fs.Close(); $stream.Close() }
      $downloaded = $true
      break
    } catch {
      Write-Warn ("Download attempt failed: {0}" -f $_.Exception.Message)
      try { Remove-Item -LiteralPath $dllTemp -Force -ErrorAction SilentlyContinue } catch { }
    }
  }
  if (-not $downloaded) { Fail ("Could not download REGIX.dll from $DllUrl.`n" +
                                "  Check the internet connection, a firewall/proxy that blocks raw.githubusercontent.com,`n" +
                                "  or that the file still exists on the main branch.") }

  # Sanity checks: size floor + PE 'MZ' header (guards against HTML error pages).
  $dllFile = Get-Item -LiteralPath $dllTemp
  if ($dllFile.Length -lt $MinDllBytes) { Fail ("The downloaded file is only {0} bytes - that is not REGIX.dll.`n  Something (antivirus, proxy, captive portal) replaced or truncated the download." -f $dllFile.Length) }
  $head = New-Object byte[] 2
  $fs = [IO.File]::OpenRead($dllTemp); [void]$fs.Read($head, 0, 2); $fs.Close()
  if ([Text.Encoding]::ASCII.GetString($head) -ne "MZ") { Fail "The downloaded file is not a Windows DLL (no MZ header)." }
  Write-Info ("Downloaded {0:N1} MB." -f ($dllFile.Length / 1MB))
  $DllPath = $dllTemp
}

if (-not (Test-Path -LiteralPath $DllPath)) { Fail "The DLL path does not exist: $DllPath" }
$DllPath = (Resolve-Path -LiteralPath $DllPath).Path
Write-Info ("DLL: {0}" -f $DllPath)

# ---- 1) BlueStacks installation ---------------------------------------------
Write-Step "Looking for the BlueStacks installation"
$installs = @(Get-BlueStacksInstalls)
if ($installs.Count -eq 0) {
  Fail ("No BlueStacks installation found.`n" +
        "  Looked at HKLM\SOFTWARE\BlueStacks_msi5 / BlueStacks_nxt and the default Program Files folders.`n" +
        "  Install MSI App Player or BlueStacks 5 first, start it once, then run this command again.")
}
foreach ($i in $installs) {
  $adbName = "none"
  if ($i.Adb) { $adbName = $i.Adb }
  Write-Info ("{0}: {1} (ADB: {2})" -f $i.Kind, $i.Exe, $adbName)
}
$script:InstallExes = @($installs | ForEach-Object { $_.Exe })
$chosen = $installs[0]
Write-Info ("Preferred install: {0}" -f $chosen.Dir)

$confMap = Get-ConfMap $chosen.Conf
if ($chosen.Conf) { Write-Info ("Config: {0}" -f $chosen.Conf) } else { Write-Warn "bluestacks.conf not found - instance/ADB port are guessed." }
$images = @(Get-ConfInstances $confMap)

$wantInstance = $Instance
if (-not $wantInstance -and $images.Count -gt 0) { $wantInstance = $images[0] }
if (-not $wantInstance) { $wantInstance = "Pie64" }
if ($Instance) { Write-Info ("Requested instance: {0}" -f $Instance) }
Write-Info ("Instance: {0}" -f $wantInstance)

# The script never edits BlueStacks settings. If ADB was switched off there, the
# game cannot be started/verified from here, so stop and explain instead.
if ($confMap.ContainsKey('bst.enable_adb_access') -and $confMap['bst.enable_adb_access'] -ne '1') {
  Fail ("ADB access is switched off for this BlueStacks installation (bst.enable_adb_access=""0"" in`n" +
        "  {0}).`n" +
        "  Fix: open BlueStacks -> Settings -> Advanced -> enable 'Android Debug Bridge', restart the player,`n" +
        "  and run this command again. This script never changes BlueStacks settings for you." -f $chosen.Conf)
}

# ---- 2) The HD-Player.exe to inject into ------------------------------------
Write-Step "Finding the running HD-Player.exe"
$players = @(Get-PlayerProcesses)
if ($players.Count -gt 0) { Write-Info ("Running: {0}" -f (Format-PlayerList $players)) } else { Write-Info "No HD-Player.exe is running." }

$target = Select-PlayerTarget -Installs $installs -Players $players -WantInstance $Instance -WantPid $ProcessId
$player = $target.Player
if ($target.Install) {
  if ($target.Install.Dir -ine $chosen.Dir) {
    Write-Info ("The running player belongs to {0}; using that installation." -f $target.Install.Dir)
    $chosen = $target.Install
    $confMap = Get-ConfMap $chosen.Conf
    $images = @(Get-ConfInstances $confMap)
    if ($player.Instance) { $wantInstance = $player.Instance }
  }
}

$startedByUs = $false
if (-not $player) {
  Write-Step ("Starting HD-Player.exe (instance {0})" -f $wantInstance)
  if (-not (Test-Path -LiteralPath $chosen.Exe)) { Fail ("{0} not found. Start BlueStacks manually and run this command again." -f $chosen.Exe) }
  try {
    $sp = Start-Process -FilePath $chosen.Exe -ArgumentList @('--instance', $wantInstance) -WorkingDirectory $chosen.Dir -PassThru
    Write-Info ("Started PID {0}: {1} --instance {2}" -f $sp.Id, $chosen.Exe, $wantInstance)
  } catch {
    Fail ("Could not start {0}: {1}`n  Start BlueStacks manually (BlueStacks 5 / MSI App Player shortcut), wait for the home screen and run this command again." -f $chosen.Exe, $_.Exception.Message)
  }
  $startedByUs = $true

  $deadline = (Get-Date).AddSeconds($PlayerStartSec)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $players = @(Get-PlayerProcesses)
    $target = Select-PlayerTarget -Installs $installs -Players $players -WantInstance $Instance -WantPid $ProcessId
    if ($target.Player) { $player = $target.Player; break }
  }
  if (-not $player) {
    Fail ("HD-Player.exe did not come up within {0} s.`n  Start BlueStacks manually, wait until the Android home screen is there, then run this command again." -f $PlayerStartSec)
  }
  if ($target.Install) { $chosen = $target.Install }
  Write-Info ("HD-Player.exe is up: PID {0} (instance {1})" -f $player.Id, $player.Instance)
} else {
  Write-Info ("Selected: PID {0} of {1}" -f $player.Id, (Format-PlayerList @($player)))
}

# ---- 3) ADB: connect to the emulator ----------------------------------------
Write-Step "Connecting ADB"
$script:AdbPath = $chosen.Adb
$script:AdbWorkDir = $chosen.Dir
$instancePort = Get-InstancePort $confMap $wantInstance
if ($instancePort -gt 0) { Write-Info ("ADB port of instance {0}: {1}" -f $wantInstance, $instancePort) }
$otherPorts = New-Object System.Collections.Generic.List[int]
foreach ($name in $images) {
  $pp = Get-InstancePort $confMap $name
  if ($pp -gt 0 -and $pp -ne $instancePort) { $otherPorts.Add($pp) }
}
$adbWaitSec = 15
if ($startedByUs) { $adbWaitSec = $BootTimeoutSec }
$adbOk = Initialize-AdbSession -InstancePort $instancePort -ExtraPorts $otherPorts -WaitSeconds $adbWaitSec

if ($adbOk -and $startedByUs) {
  [void](Wait-ForBoot -WaitSeconds $BootTimeoutSec)
} elseif (-not $adbOk) {
  Write-Warn "ADB is not reachable, so Free Fire cannot be started or verified from here."
  if ($startedByUs) {
    Write-Info "Waiting 45 s so the freshly started emulator can settle..."
    Start-Sleep -Seconds 45
  }
}

# ---- 4) Free Fire in the emulator -------------------------------------------
Write-Step ("Free Fire ({0})" -f $GamePackage)
$gameOk = Start-FreeFireAndWait
if (-not $gameOk) {
  Write-Warn "Free Fire was not confirmed running. Injecting anyway, as requested - if the game closes right after the injection, this is the reason."
}

# ---- 5) Architecture check --------------------------------------------------
Write-Step "Checking the target architecture"
$proc = Get-Process -Id $player.Id -ErrorAction SilentlyContinue
if (-not $proc) { Fail ("{0}.exe (PID {1}) disappeared before the injection." -f $ProcessName, $player.Id) }
$arch = Test-TargetArch $proc
Write-Info ("Target {0}.exe PID {1}: {2} (the DLL is x64, so the target must be x64)" -f $ProcessName, $proc.Id, $arch)
if ($arch -like "x86*") {
  Fail ("Architecture mismatch: {0}.exe is a 32-bit process, but REGIX.dll is x64.`n  Use the 64-bit BlueStacks 5 / MSI App Player player (or a matching x86 build of the DLL)." -f $ProcessName)
}

if ($DryRun) {
  Write-Host ""
  Write-Host "[REGIX] DRY RUN finished - every preparation step worked, nothing was injected." -ForegroundColor Green
  Write-Info ("DLL ready      : {0}" -f $DllPath)
  Write-Info ("Target         : {0}.exe PID {1} ({2})" -f $ProcessName, $proc.Id, $arch)
  Write-Info ("Install        : {0}" -f $chosen.Dir)
  Write-Info ("Instance       : {0}" -f $wantInstance)
  $adbText = "no device"
  if ($script:AdbSerial) { $adbText = $script:AdbSerial }
  Write-Info ("ADB            : {0}" -f $adbText)
  Write-Info ("Free Fire      : {0}" -f $(if ($gameOk) { "confirmed running" } else { "not confirmed" }))
  Write-Info "Run the same command without -DryRun (as Administrator) to inject."
  Stop-AdbServerIfWeStartedIt
  Remove-TempArtifacts
  exit 0
}

# @@APPEND@@