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
   thread on `kernel32!LoadLibraryW` -> wait -> cleanup handles + remote memory.
6. Best-effort deletes the downloaded copy and closes PowerShell (exit 0 / exit 1).

## Local DLL mode (optional)

When running the script as a saved file you can inject a local build and skip the download:

```powershell
powershell -ExecutionPolicy Bypass -File Inject-REGIX.ps1 -DllPath "C:\builds\REGIX.dll"
```

## Troubleshooting

| Message | Fix |
|---------|-----|
| `Not running as Administrator` | Right-click PowerShell -> **Run as administrator**, re-run the one-liner |
| `HD-Player.exe not running` | Start BlueStacks 5 first |
| `Arch mismatch: target is x86` | You are running a 32-bit BlueStacks build; use the x64 build |
| `Remote LoadLibraryW returned NULL` | Missing dependency: install the Visual C++ Redistributable (`MSVCP140`) and `D3DCOMPILER_43`/`d3dx11_43` (DirectX runtime), or antivirus blocked the load — check Event Viewer |
| `Download failed` / `HTTP ...` | Network/firewall blocking `raw.githubusercontent.com`; retry |

## Notes

- Antivirus may flag injectors (the script uses `CreateRemoteThread`); you may need to
  allow-list the script/DLL.
- `%TEMP%\REGIX.dll` can stay locked while HD-Player has it loaded; the next run detects
  this automatically and cleans up the stale copy.
- The DLL is always pulled from the latest `main` branch — no version pinning.