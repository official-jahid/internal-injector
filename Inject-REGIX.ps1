#
<#
.SYNOPSIS
  Injects REGIX.dll into HD-Player.exe (BlueStacks 5, x64) via LoadLibraryW remote thread.
.DESCRIPTION
  PS1-only injector for REGIX v1.0. Finds HD-Player.exe, verifies x64, allocates +
  writes DLL path, starts remote thread on kernel32!LoadLibraryW, waits, cleans up.
  Run from examples/example_win32_directx11 or pass -DllPath explicitly.
.PARAMETER DllPath
  Full path to REGIX.dll. Defaults to .\Build\REGIX.dll next to this script.
.PARAMETER ProcessName
  Target process without .exe. Default HD-Player.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Inject-REGIX.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Inject-REGIX.ps1 -DllPath "C:\...\REGIX.dll" -ProcessName "HD-Player"
#>
param(
  [string]$DllPath = (Join-Path $PSScriptRoot "Build\REGIX.dll"),
  [string]$ProcessName = "HD-Player"
)

$ErrorActionPreference = "Stop"

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

if (-not (Test-Path -LiteralPath $DllPath)) {
  # fallback: old name from previous build
  $legacy = Join-Path $PSScriptRoot "Build\REIMANOS.dll"
  if (Test-Path -LiteralPath $legacy) {
    Write-Warning "REGIX.dll not found, using legacy $legacy. Rebuild Release|x64 to produce REGIX.dll."
    $DllPath = $legacy
  } else {
    throw "DLL not found: $DllPath. Build Release|x64 first (msbuild REGIX.sln /p:Configuration=Release /p:Platform=x64)."
  }
}
$DllPath = (Resolve-Path -LiteralPath $DllPath).Path
Write-Host "[REGIX] DLL : $DllPath"
Write-Host "[REGIX] Target process: $ProcessName.exe"

$procs = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
if (-not $procs) { throw "$ProcessName.exe not running. Start BlueStacks 5 HD-Player first." }
$proc = $procs | Select-Object -First 1
Write-Host ("[REGIX] Found {0} PID {1}" -f $proc.ProcessName, $proc.Id)

$arch = Test-TargetArch $proc
Write-Host "[REGIX] Target arch: $arch (DLL is x64; must be x64)"
if ($arch -like "x86*") { throw "Arch mismatch: target is x86 but REGIX.dll is x64. Use matching builds." }

$PROCESS_ALL = 0x001F0FFF
$MEM_COMMIT_RESERVE = 0x3000
$PAGE_READWRITE = 0x04
$MEM_RELEASE = 0x8000
$INFINITE = 0xFFFFFFFF

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Warning "Not running as Administrator. OpenProcess may fail with Access Denied; right-click PowerShell -> Run as administrator and retry." }

$hProc = [NativeRegixV2]::OpenProcess($PROCESS_ALL, $false, [uint32]$proc.Id)
if ($hProc -eq [IntPtr]::Zero) { throw ("OpenProcess failed: " + [ComponentModel.Win32Exception][Runtime.InteropServices.Marshal]::GetLastWin32Error()).ToString() }
try {
  $bytes = [Text.Encoding]::Unicode.GetBytes($DllPath + [char]0)
  $addr = [NativeRegixV2]::VirtualAllocEx($hProc, [IntPtr]::Zero, [uint32]$bytes.Length, $MEM_COMMIT_RESERVE, $PAGE_READWRITE)
  if ($addr -eq [IntPtr]::Zero) { throw "VirtualAllocEx failed." }
  try {
    $written = [UIntPtr]::Zero
    if (-not [NativeRegixV2]::WriteProcessMemory($hProc, $addr, $bytes, [uint]$bytes.Length, [ref]$written)) { throw "WriteProcessMemory failed." }
    $hKernel = [NativeRegixV2]::GetModuleHandle("kernel32.dll")
    $loadLib = [NativeRegixV2]::GetProcAddress($hKernel, "LoadLibraryW")
    if ($loadLib -eq [IntPtr]::Zero) { throw "GetProcAddress(LoadLibraryW) failed." }
    $hThread = [NativeRegixV2]::CreateRemoteThread($hProc, [IntPtr]::Zero, 0, $loadLib, $addr, 0, [IntPtr]::Zero)
    if ($hThread -eq [IntPtr]::Zero) { throw "CreateRemoteThread failed. Try admin + same-arch + no antivirus block." }
    try {
      $wait = [NativeRegixV2]::WaitForSingleObject($hThread, 10000)
      $exit = [uint32]0
      [NativeRegixV2]::GetExitCodeThread($hThread, [ref]$exit) | Out-Null
      if ($exit -eq 0) { throw "Remote LoadLibraryW returned NULL (exit=0). Missing dependency or blocked load. Check D3DCOMPILER_43/d3dx11_43/MSVCP140 discoursed in README, AV logs, Event Viewer." }
      if ($wait -eq $INFINITE -or $wait -eq 0x102) { Write-Warning "Wait timed out/failed ($wait) but module base=0x$($exit.ToString('X')). Check menu with INSERT." }
      else { Write-Host ("[REGIX] X : Successfully Injected! (wait={0} base=0x{1:X}) Press INSERT in emulator." -f $wait, $exit) }
    } finally { [NativeRegixV2]::CloseHandle($hThread) | Out-Null }
  } finally { [NativeRegixV2]::VirtualFreeEx($hProc, $addr, 0, $MEM_RELEASE) | Out-Null }
} finally { [NativeRegixV2]::CloseHandle($hProc) | Out-Null }
