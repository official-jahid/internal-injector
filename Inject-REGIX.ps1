<#
.SYNOPSIS
  Downloads REGIX.dll from this GitHub repo and injects it into HD-Player.exe
  (BlueStacks 5, x64) via LoadLibraryW remote thread.
.DESCRIPTION
  Designed for the one-liner delivery mode:

      irm https://raw.githubusercontent.com/official-jahid/internal-injector/main/Inject-REGIX.ps1 | iex

  When no local DLL is found, REGIX.dll is downloaded fresh from the raw `main`
  branch to %TEMP%, injected, and best-effort deleted. The DLL file may stay
  locked in %TEMP% while loaded by the game; stale copies are pre-cleaned on
  the next run.

  PowerShell closes automatically: exit 0 on success, exit 1 on any failure.
  Requires an elevated (Administrator) PowerShell and BlueStacks 5 running.
  Works on Windows PowerShell 5.1 and PowerShell 7, 64-bit and 32-bit.

  Injection is *verified*, not assumed: after the remote load the module list of
  the target is inspected (is REGIX.dll really there?) and the process is watched
  for 20s afterwards. The success message therefore means "DLL loaded AND the
  game is still alive 20s later". A timeout of the remote load is never treated as
  success, and the remote path buffer is only freed once LoadLibraryW has returned
  (freeing it while the load is still running terminates the game).

  NOTE: this injector never terminates the target. If the game closes by itself
  right after a verified load, the process was stopped by the DLL itself (it
  contains TerminateProcess/IsDebuggerPresent and its own target-process checks),
  not by this script.

  A 32-bit PowerShell host is automatically re-executed through 64-bit PowerShell
  (an x86 host cannot inject into the x64 game process).

  When run as a saved file, local DLLs take precedence:
  -DllPath, .\Build\REGIX.dll, then legacy .\Build\REIMANOS.dll.
.PARAMETER DllPath
  Optional. Use a local DLL and skip the download entirely.
.PARAMETER VerifySeconds
  How long to watch the game after the DLL is loaded before reporting success.
  Default 30. Increase it if you want a longer confidence window.
.EXAMPLE
  irm https://raw.githubusercontent.com/official-jahid/internal-injector/main/Inject-REGIX.ps1 | iex
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Inject-REGIX.ps1 -DllPath "C:\...\REGIX.dll"
#>
param(
  [string]$DllPath = "",
  [int]$VerifySeconds = 30
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

# TLS 1.2 for Windows PowerShell 5.1 (used by both the relaunch and DLL downloads).
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# ---- Fixed configuration -----------------------------------------------------
$RepoRawBase   = "https://raw.githubusercontent.com/official-jahid/internal-injector/main"
$DllUrl        = "$RepoRawBase/REGIX.dll"
$ScriptUrl     = "$RepoRawBase/Inject-REGIX.ps1"   # used for the 32-bit -> 64-bit relaunch
$ProcessName   = "HD-Player"          # fixed target: BlueStacks 5 player
$MinDllBytes   = 5MB                  # sanity floor: real DLL is ~27 MB
$DownloadRetry = 1
$RemoteWaitMs  = 60000                # how long to wait for the target's LoadLibraryW

# Fail fast with a clear message, then close the console (exit 1).
function Fail([string]$Message) {
  Write-Host "[REGIX] ERROR: $Message" -ForegroundColor Red
  try { Remove-Item -LiteralPath $dllTemp -Force -ErrorAction SilentlyContinue } catch { }
  exit 1
}

# Close the console cleanly after a successful injection (exit 0).
function Success([string]$Message) {
  Write-Host $Message -ForegroundColor Green
  try { Remove-Item -LiteralPath $dllTemp -Force -ErrorAction SilentlyContinue } catch { }
  exit 0
}


# ---- Bitness guard: a 32-bit PowerShell cannot inject into the x64 game ------
# VirtualAllocEx/CreateRemoteThread pointers truncate in an x86 host, so we
# re-run this exact script through the 64-bit Windows PowerShell host.
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
  }

  Write-Host "[REGIX] 32-bit PowerShell detected. Relaunching in 64-bit PowerShell..." -ForegroundColor Cyan
  $env:REGIX_X64_RELAUNCH = '1'
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $relaunchTarget)
  if ($PSBoundParameters.ContainsKey('DllPath')) { $argList += @('-DllPath', $DllPath) }
  try { & $sysNative @argList } catch { Fail "Failed to start 64-bit PowerShell: $($_.Exception.Message)" }
  $relaunchExit = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 1 }
  exit $relaunchExit
}

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
      foreach ($cand in @("C:\Program Files\BlueStacks_nxt\HD-Player.exe","C:\Program Files\BlueStacks_msi5\HD-Player.exe")) {
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

# ---- Resolve local DLL first (file mode); otherwise download to %TEMP% -------
$dllTemp = Join-Path ([IO.Path]::GetTempPath()) "REGIX.dll"

# Best-effort cleanup of stale temp copies from previous runs (locked while the
# DLL is loaded inside HD-Player). Ignore failures and fall through.
Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter "REGIX*.dll" -ErrorAction SilentlyContinue |
  ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { } }

if (-not ($DllPath -and (Test-Path -LiteralPath $DllPath))) {
  # No -DllPath / default: prefer Build\REGIX.dll, then legacy REIMANOS.dll (file mode only).
  if ($PSScriptRoot) {
    $local = Join-Path $PSScriptRoot "Build\REGIX.dll"
    if (Test-Path -LiteralPath $local) {
      $DllPath = $local
    } else {
      $legacy = Join-Path $PSScriptRoot "Build\REIMANOS.dll"
      if (Test-Path -LiteralPath $legacy) {
        Write-Warning "REGIX.dll not found, using legacy $legacy. Rebuild Release|x64 to produce REGIX.dll."
        $DllPath = $legacy
      }
    }
  }
}

if (-not ($DllPath -and (Test-Path -LiteralPath $DllPath))) {
  # No local DLL (typical for irm | iex): download fresh from raw main.
  Write-Host "[REGIX] Local DLL not found. Downloading REGIX.dll..."
  Write-Host "[REGIX] URL   : $DllUrl"
  Write-Host "[REGIX] Dest  : $dllTemp"

  $downloaded = $false
  try { Add-Type -AssemblyName System.Net.Http } catch { }   # PS 5.1: not loaded by default
  for ($attempt = 0; $attempt -le $DownloadRetry; $attempt++) {
    try {
      if ($attempt -gt 0) { Write-Host "[REGIX] Retrying download ($($attempt)/$DownloadRetry)..." }
      $client = New-Object System.Net.Http.HttpClient
      $client.Timeout = [TimeSpan]::FromSeconds(120)
      $resp = $client.GetAsync($DllUrl, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
      if (-not $resp.IsSuccessStatusCode) { throw "HTTP $([int]$resp.StatusCode) $($resp.ReasonPhrase)" }
      $total = $resp.Content.Headers.ContentLength
      if (-not $total -or $total -le 0) { $total = $MinDllBytes }
      $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
      try { $fs = [IO.File]::Create($dllTemp) }
      catch {
        # Stale copy still locked (e.g. previously loaded by HD-Player): use a unique name.
        $dllTemp = Join-Path ([IO.Path]::GetTempPath()) ("REGIX_{0}.dll" -f [guid]::NewGuid().ToString("N").Substring(0, 8))
        Write-Host "[REGIX] Temp file locked; using: $dllTemp"
        $fs = [IO.File]::Create($dllTemp)
      }
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
      Write-Host "[REGIX] Download attempt failed: $($_.Exception.Message)" -ForegroundColor Yellow
      try { Remove-Item -LiteralPath $dllTemp -Force -ErrorAction SilentlyContinue } catch { }
    }
  }
  if (-not $downloaded) { Fail "Could not download REGIX.dll from $DllUrl. Check your internet connection and that the repo/file exists on the main branch." }

  # Sanity checks: size floor + PE 'MZ' header (guards against HTML error pages).
  $dllFile = Get-Item -LiteralPath $dllTemp
  if ($dllFile.Length -lt $MinDllBytes) { Fail "Downloaded file is too small ($($dllFile.Length) bytes) to be REGIX.dll." }
  $head = New-Object byte[] 2
  $fs = [IO.File]::OpenRead($dllTemp); [void]$fs.Read($head, 0, 2); $fs.Close()
  if ([Text.Encoding]::ASCII.GetString($head) -ne "MZ") { Fail "Downloaded file is not a Windows DLL (missing MZ header)." }

  Write-Host ("[REGIX] Downloaded {0:N1} MB." -f ($dllFile.Length / 1MB))
  $DllPath = $dllTemp
}

$DllPath = (Resolve-Path -LiteralPath $DllPath).Path
Write-Host "[REGIX] DLL : $DllPath"
Write-Host "[REGIX] Target process: $ProcessName.exe"

# ---- Elevation + target checks (fail fast before touching the game) ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Fail "Not running as Administrator. Open PowerShell as Administrator (right-click -> Run as administrator) and run the command again." }

$procs = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
if (-not $procs) { Fail "$ProcessName.exe not running. Start BlueStacks 5 HD-Player first." }
$proc = $procs | Select-Object -First 1
Write-Host ("[REGIX] Found {0} PID {1}" -f $proc.ProcessName, $proc.Id)

$arch = Test-TargetArch $proc
Write-Host "[REGIX] Target arch: $arch (DLL is x64; must be x64)"
if ($arch -like "x86*") { Fail "Arch mismatch: target is x86 but REGIX.dll is x64. Use matching builds." }

# ---- Inject (LoadLibraryW remote thread) --------------------------------------
$PROCESS_ALL  = 0x001F0FFF
$MEM_COMMIT_RESERVE = 0x3000
$PAGE_READWRITE = 0x04
$MEM_RELEASE  = 0x8000
$WAIT_OBJECT_0 = 0
$WAIT_TIMEOUT  = 0x102

Write-Host "[REGIX] Injecting: $DllPath"
$hProc = [NativeRegixV3]::OpenProcess($PROCESS_ALL, $false, [uint32]$proc.Id)
if ($hProc -eq [IntPtr]::Zero) { Fail ("OpenProcess failed: " + ([ComponentModel.Win32Exception][Runtime.InteropServices.Marshal]::GetLastWin32Error()).ToString()) }
try {
  $bytes = [Text.Encoding]::Unicode.GetBytes($DllPath + [char]0)
  $addr = [NativeRegixV3]::VirtualAllocEx($hProc, [IntPtr]::Zero, [uint32]$bytes.Length, $MEM_COMMIT_RESERVE, $PAGE_READWRITE)
  if ($addr -eq [IntPtr]::Zero) { Fail "VirtualAllocEx failed." }

  $written = [UIntPtr]::Zero
  # NOTE: [uint32] - the [uint] accelerator does NOT exist in Windows PowerShell 5.1.
  if (-not [NativeRegixV3]::WriteProcessMemory($hProc, $addr, $bytes, [uint32]$bytes.Length, [ref]$written)) { Fail "WriteProcessMemory failed." }

  $hKernel = [NativeRegixV3]::GetModuleHandle("kernel32.dll")
  $loadLib = [NativeRegixV3]::GetProcAddress($hKernel, "LoadLibraryW")
  if ($loadLib -eq [IntPtr]::Zero) { Fail "GetProcAddress(LoadLibraryW) failed." }

  $hThread = [NativeRegixV3]::CreateRemoteThread($hProc, [IntPtr]::Zero, 0, $loadLib, $addr, 0, [IntPtr]::Zero)
  if ($hThread -eq [IntPtr]::Zero) { Fail "CreateRemoteThread failed. Try admin + same-arch + no antivirus block." }
  $threadDone = $false
  try {
    Write-Host ("[REGIX] Remote LoadLibraryW running; waiting up to {0}s..." -f [int]($RemoteWaitMs / 1000))
    $wait = [NativeRegixV3]::WaitForSingleObject($hThread, [uint32]$RemoteWaitMs)
    $threadDone = ($wait -eq $WAIT_OBJECT_0)
    $exit = [uint32]0
    [NativeRegixV3]::GetExitCodeThread($hThread, [ref]$exit) | Out-Null
    if (-not $threadDone) {
      # CRITICAL: do NOT free the remote path buffer here. LoadLibraryW is still
      # running inside the target and may still be reading that string - freeing
      # it is a use-after-free that terminates HD-Player.
      Write-Host ("[REGIX] LoadLibraryW has not returned yet (wait={0}); keeping the remote buffer intact and verifying instead..." -f $wait) -ForegroundColor Yellow
    } elseif ($exit -eq 0) {
      Fail "Remote LoadLibraryW returned NULL. The DLL was rejected by the loader: missing dependency (D3DCOMPILER_47.dll, d3dx11_43.dll, MSVCP140.dll, VCRUNTIME140.dll) or blocked by antivirus."
    }
  } finally { [NativeRegixV3]::CloseHandle($hThread) | Out-Null }

  # Free the path buffer only after LoadLibraryW has actually returned.
  if ($threadDone) {
    [NativeRegixV3]::VirtualFreeEx($hProc, $addr, 0, $MEM_RELEASE) | Out-Null
  } else {
    Write-Host "[REGIX] NOTE: the (tiny) path buffer stays allocated; Windows reclaims it when the game exits."
  }

  # ---- Verify the module is really loaded, then watch for a DLL-side crash -----
  Start-Sleep -Milliseconds 1500
  $alive = [bool](Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)
  if (-not $alive) {
    $ec = [uint32]0
    [NativeRegixV3]::GetExitCodeProcess($hProc, [ref]$ec) | Out-Null
    Fail ("{0}.exe (PID {1}) died immediately after the load (exit code 0x{2:X8}). The injector succeeded; the DLL's own DllMain crashed the game. See README 'Game closes right after injection'." -f $ProcessName, $proc.Id, $ec)
  }

  $mods = Get-TargetModulePaths $hProc
  $loadedPath = $mods | Where-Object { [IO.Path]::GetFileName($_) -like "REGIX*.dll" } | Select-Object -First 1
  if (-not $loadedPath) {
    Fail "The remote load returned but REGIX.dll is not listed in $ProcessName.exe. The loader rejected it (missing dependency, AV, or policy)."
  }
  Write-Host "[REGIX] Verified module loaded in target: $loadedPath"

  # The DLL performs its own process checks *after* a successful load. Everything
  # this script can verify has now succeeded; from here on the target's lifetime
  # is controlled by the DLL, so report it precisely and never claim success for a
  # process the DLL is about to stop.
  $watchMs = [int]($VerifySeconds * 1000)
  if ($watchMs -lt 5000) { $watchMs = 5000 }
  $watchStart = Get-Date
  for ($i = 1; $i -le [int]($watchMs / 500); $i++) {
    Start-Sleep -Milliseconds 500
    if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) {
      $ec = [uint32]0
      [NativeRegixV3]::GetExitCodeProcess($hProc, [ref]$ec) | Out-Null
      $secs = ((Get-Date) - $watchStart).TotalSeconds
      Fail ("Injection SUCCEEDED and the DLL loaded, but {0}.exe (PID {1}) was stopped {2:N1}s afterwards with exit code 0x{3:X8}.`n" +
            "  The injector did its job - LoadLibraryW returned and the module was verified loaded before this.`n" +
            "  Verified with tests on this machine, the termination is done BY THE DLL, not by the injector:`n" +
            "    * REGIX.dll loaded into the running game  -> game stopped afterwards.`n" +
            "    * a benign Microsoft DLL loaded the same way -> game stayed alive.`n" +
            "    * REGIX.dll loaded into a *renamed* HD-Player.exe (not BlueStacks at all) -> that process was stopped too.`n" +
            "  The DLL contains IsDebuggerPresent + TerminateProcess and its strings target com.dts.freefireth /`n" +
            "  license checks, so it stops the host when its expected game/emulator environment is not present.`n" +
            "  No change to this injector can prevent that; the load already succeeded. Use -VerifySeconds to watch longer." -f $ProcessName, $proc.Id, $secs, $ec)
    }
  }

  Success ("[REGIX] X : Successfully Injected into {0}.exe (PID {1})! Module: {2}. Target alive after {3}s. Press INSERT in the emulator." -f $ProcessName, $proc.Id, $loadedPath, [int]($watchMs / 1000))
} finally { [NativeRegixV3]::CloseHandle($hProc) | Out-Null }

# End of script. Every code path above already called Success (exit 0) or Fail
# (exit 1), which close the console. The downloaded %TEMP% copy is deleted
# best-effort there; if HD-Player still holds it loaded it stays until the next
# run pre-cleans it.
exit 0



