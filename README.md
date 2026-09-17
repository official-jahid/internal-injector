# internal-injector

One-liner PowerShell injector: downloads **REGIX.dll** from this repo and injects it into
**BlueStacks 5** (`HD-Player.exe`) via `kernel32!LoadLibraryW` remote thread.

## Quick start

1. Start **BlueStacks 5** (make sure `HD-Player.exe` is running).
2. Open **PowerShell as Administrator**.
3. Paste this one-liner:

```powershell
irm https://raw.githubusercontent.com/official-jahid/internal-injector/main/Inject-REGIX.ps1 | iex
```

The script downloads the latest `REGIX.dll` from the `main` branch into `%TEMP%`,
injects it into `HD-Player.exe`, and closes PowerShell automatically.

- Exit code `0` = injected successfully -> press **INSERT** in BlueStacks to open the menu.
- Exit code `1` = failure -> the error is printed in red before the window closes.

## Cloudflare Worker delivery (optional)

`worker.js` lets you serve the injector from your own Cloudflare Worker instead of raw GitHub:

1. Deploy it: Cloudflare Dashboard -> **Workers & Pages** -> **Create Worker** -> "Edit code" -> paste `worker.js` -> **Deploy** (or `npx wrangler deploy`).
2. Hand out this one-liner instead (PowerShell clients automatically get the script; browsers get an honest info page):

```powershell
irm https://<your-worker>.workers.dev | iex
```

The script is still fetched live from `raw.githubusercontent.com/main`, so every push (new `REGIX.dll` or script change) takes effect immediately - no worker redeploy needed.

## Requirements

- Windows 10/11 x64
- BlueStacks 5 running (`HD-Player.exe`, x64)
- PowerShell started **as Administrator** (no UAC prompt is shown automatically; 32-bit
  PowerShell is automatically relaunched as 64-bit)
- Internet access to `raw.githubusercontent.com`

## What the script does

1. Relaunches itself in 64-bit PowerShell when started from a 32-bit host (required to
   inject into the x64 game).
2. Checks that the console is elevated.
3. Finds `HD-Player.exe` and verifies it is x64.
4. Gets the DLL: uses a local file when available (`-DllPath`, `Build\REGIX.dll`, or legacy
   `Build\REIMANOS.dll`); otherwise downloads the latest `REGIX.dll` from `main` into
   `%TEMP%` (progress bar, one retry, size + PE `MZ` header sanity checks).
5. Injects: `OpenProcess` -> `VirtualAllocEx` + `WriteProcessMemory` (DLL path) -> remote
   thread on `kernel32!LoadLibraryW` -> wait for the load to actually return -> cleanup.
6. **Verifies** the injection instead of assuming it: reads the target's module list back
   (`EnumProcessModulesEx`) to confirm `REGIX.dll` is really loaded, then watches the game
   for 30 s (`-VerifySeconds` changes this). Success is only reported when the DLL is
   present **and** the game is still alive; the remote path buffer is freed only after
   `LoadLibraryW` has returned (freeing it while the load is still running terminates the
   game).
7. Best-effort deletes the downloaded copy and closes PowerShell (exit 0 / exit 1).

## Local DLL mode (optional)

When running the script as a saved file you can inject a local build and skip the download:

```powershell
powershell -ExecutionPolicy Bypass -File Inject-REGIX.ps1 -DllPath "C:\builds\REGIX.dll"
```

You can also extend or shorten the post-injection liveness check (seconds, minimum 5):

```powershell
powershell -ExecutionPolicy Bypass -File Inject-REGIX.ps1 -VerifySeconds 60
```

## Troubleshooting

| Message | Fix |
|---------|-----|
| `Not running as Administrator` | Right-click PowerShell -> **Run as administrator**, re-run the one-liner |
| `HD-Player.exe not running` | Start BlueStacks 5 first |
| `Arch mismatch: target is x86` | You are running a 32-bit BlueStacks build; use the x64 build |
| `Remote LoadLibraryW returned NULL` | Missing dependency: install the Visual C++ Redistributable (`MSVCP140`) and `D3DCOMPILER_43`/`d3dx11_43` (DirectX runtime), or antivirus blocked the load — check Event Viewer |
| `Injection SUCCEEDED and the DLL loaded, but HD-Player.exe was stopped N s afterwards` | The DLL stops the host itself — not the injector. See "Game closes right after injection" below |
| `Download failed` / `HTTP ...` | Network/firewall blocking `raw.githubusercontent.com`; retry |

## Game closes right after injection

The injector only does four things to the game: `OpenProcess`, `VirtualAllocEx`,
`WriteProcessMemory`, `CreateRemoteThread(LoadLibraryW)`. It never calls
`TerminateProcess` or `SuspendThread`, and it verifies the DLL is really loaded
before reporting anything.

If `HD-Player.exe` closes shortly after a **verified** load, the process was ended
from inside the loaded DLL. This was confirmed by testing:

| Test | Result |
|------|--------|
| `REGIX.dll` into 64-bit `notepad.exe` | survived 60 s, module loaded |
| `version.dll` (benign, from `%TEMP%`) into `HD-Player.exe` | survived 60 s |
| `REGIX.dll` into a **renamed copy** of `powershell.exe` called `HD-Player.exe` | loaded, then **terminated itself after ~62 s with exit code 0** |

`REGIX.dll` contains `TerminateProcess`, `IsDebuggerPresent`, `CreateProcessA`,
`QueryFullProcessImageNameW` and emulator-target strings (`BlueStacks.exe`,
`HD-Player.exe`, `Gameloop.exe`, `AndroidEmulator.exe`, `AttackProcess`), i.e. it
runs its own process checks after loading. On top of that it still contains an
unknown obfuscated blob and a license gate, and it is a 27 MB ImGui-based
in-game overlay for a specific game.

**Nothing in this repository can prevent that.** The script now reports it
honestly instead of printing a fake "Successfully Injected", and it exits with
code `1` so automation does not treat the run as healthy.

## Notes

- Antivirus may flag injectors (the script uses `CreateRemoteThread`); you may need to
  allow-list the script/DLL.
- `%TEMP%\REGIX.dll` can stay locked while HD-Player has it loaded; the next run detects
  this automatically and cleans up the stale copy.
- The DLL is always pulled from the latest `main` branch — no version pinning.
- **Do not commit or distribute `injector.exe`.** The copy that appeared in this working
  folder is *not* an injector: its version resource claims to be
  `Microsoft Windows Search Protocol Host (SearchProtocolHost.exe)` from Microsoft, its
  Authenticode signature does not match its content (`HashMismatch`, odd signer), and its
  string table contains a whole embedded Python runtime (`setuptools`, `packaging.licenses`).
  It is a disguised payload and is deliberately **not** used by any script here.

## Verified fix history (2026-09-17)

| Problem | Cause | Fix |
|---------|-------|-----|
| Injection failed only under `irm \| iex` | `[uint]` does not exist in Windows PowerShell 5.1, so `WriteProcessMemory` threw | use `[uint32]` |
| Game died on slower PCs | the remote DLL-path buffer was freed in a `finally` block even when `WaitForSingleObject` had timed out — the target's in-flight `LoadLibraryW` read freed memory | only free the buffer after the load returns (60 s timeout instead of 10 s) |
| Fake success | a timed-out wait was reported as "Successfully Injected" | verify via `EnumProcessModulesEx` + 20 s liveness watch |