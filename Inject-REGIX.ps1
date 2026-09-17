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
  Works from 32-bit or 64-bit PowerShell: a 32-bit host is automatically
  re-executed through 64-bit PowerShell (a 32-bit host cannot inject into the
  x64 game process).

  When run as a saved file, local DLLs take precedence:
  -DllPath, .\Build\REGIX.dll, then legacy .\Build\REIMANOS.dll.
.PARAMETER DllPath
  Optional. Use a local DLL and skip the download entirely.
.EXAMPLE
  irm https://raw.githubusercontent.com/official-jahid/internal-injector/main/Inject-REGIX.ps1 | iex
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Inject-REGIX.ps1 -DllPath "C:\...\REGIX.dll"
#>
param(
  [string]$DllPath = ""
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
if (-not ([System.Management.Automation.PSTypeName]"NativeRegixV2").Type) {
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeRegixV2 {
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
}
"@
}

function Test-TargetArch($proc) {
  # Try handle-based check first (needs rights), fall back to on-disk PE header.
  try {
    $wow = $false
    [NativeRegixV2]::IsWow64Process($proc.Handle, [ref]$wow) | Out-Null
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
$PROCESS_ALL = 0x001F0FFF
$MEM_COMMIT_RESERVE = 0x3000
$PAGE_READWRITE = 0x04
$MEM_RELEASE = 0x8000
$INFINITE = 0xFFFFFFFF

$hProc = [NativeRegixV2]::OpenProcess($PROCESS_ALL, $false, [uint32]$proc.Id)
if ($hProc -eq [IntPtr]::Zero) { Fail ("OpenProcess failed: " + ([ComponentModel.Win32Exception][Runtime.InteropServices.Marshal]::GetLastWin32Error()).ToString()) }
try {
  $bytes = [Text.Encoding]::Unicode.GetBytes($DllPath + [char]0)
  $addr = [NativeRegixV2]::VirtualAllocEx($hProc, [IntPtr]::Zero, [uint32]$bytes.Length, $MEM_COMMIT_RESERVE, $PAGE_READWRITE)
  if ($addr -eq [IntPtr]::Zero) { Fail "VirtualAllocEx failed." }
  try {
    $written = [UIntPtr]::Zero
    if (-not [NativeRegixV2]::WriteProcessMemory($hProc, $addr, $bytes, [uint]$bytes.Length, [ref]$written)) { Fail "WriteProcessMemory failed." }
    $hKernel = [NativeRegixV2]::GetModuleHandle("kernel32.dll")
    $loadLib = [NativeRegixV2]::GetProcAddress($hKernel, "LoadLibraryW")
    if ($loadLib -eq [IntPtr]::Zero) { Fail "GetProcAddress(LoadLibraryW) failed." }
    $hThread = [NativeRegixV2]::CreateRemoteThread($hProc, [IntPtr]::Zero, 0, $loadLib, $addr, 0, [IntPtr]::Zero)
    if ($hThread -eq [IntPtr]::Zero) { Fail "CreateRemoteThread failed. Try admin + same-arch + no antivirus block." }
    try {
      $wait = [NativeRegixV2]::WaitForSingleObject($hThread, 10000)
      $exit = [uint32]0
      [NativeRegixV2]::GetExitCodeThread($hThread, [ref]$exit) | Out-Null
      if ($exit -eq 0) { Fail "Remote LoadLibraryW returned NULL (exit=0). Missing dependency or blocked load. Check D3DCOMPILER_43/d3dx11_43/MSVCP140 discussed in README, AV logs, Event Viewer." }
      if ($wait -eq $INFINITE -or $wait -eq 0x102) {
        Success ("[REGIX] Injected (wait={0} base=0x{1:X}, wait timed out). Press INSERT in emulator." -f $wait, $exit)
      }
      else { Success ("[REGIX] X : Successfully Injected! (wait={0} base=0x{1:X}) Press INSERT in emulator." -f $wait, $exit) }
    } finally { [NativeRegixV2]::CloseHandle($hThread) | Out-Null }
  } finally { [NativeRegixV2]::VirtualFreeEx($hProc, $addr, 0, $MEM_RELEASE) | Out-Null }
} finally { [NativeRegixV2]::CloseHandle($hProc) | Out-Null }

# End of script. Every code path above already called Success (exit 0) or Fail
# (exit 1), which close the console. The downloaded %TEMP% copy is deleted
# best-effort there; if HD-Player still holds it loaded it stays until the next
# run pre-cleans it.
exit 0



