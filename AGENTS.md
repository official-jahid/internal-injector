# AGENTS.md

Guidance for AI coding agents working in this repository.

## Collaboration rules (mandatory)

- **Ask clarification questions ONE at a time.** Each answer can change what the next
  question should be, so never batch multiple questions. Ask, wait for the answer,
  then decide the next question. Continue until there are no loose ends left.
- Record every agreed decision in the decisions log below so future agents inherit
  the context.

## Project context

- Purpose: one-liner DLL injector. `Inject-REGIX.ps1` downloads `REGIX.dll` (x64,
  shipped at the repo root) and injects it into BlueStacks 5 (`HD-Player.exe`)
  via a `kernel32!LoadLibraryW` remote thread.
- Primary delivery mode — user runs this in an **elevated** PowerShell:

  ```powershell
  irm https://raw.githubusercontent.com/official-jahid/internal-injector/main/Inject-REGIX.ps1 | iex
  ```

- The DLL is fetched at runtime from
  `https://raw.githubusercontent.com/official-jahid/internal-injector/main/REGIX.dll`
  (raw `main` branch — always the latest push; no GitHub Releases).

## Behavior contract

- Requires elevation; no UAC auto-relaunch — print a clear error and exit.
- Target process is fixed: `HD-Player` (not parameterizable in `irm|iex` mode).
- Downloads fresh to `%TEMP%\REGIX.dll` every run; if the previous copy is still
  locked (DLL loaded in HD-Player), fall back to a unique temp name; best-effort
  delete after injection (stale copies are pre-cleaned on the next run).
- Local DLLs take precedence when running as a file: `-DllPath`, `Build\REGIX.dll`,
  legacy `Build\REIMANOS.dll`.
- PowerShell must close automatically after the run: `exit 0` on success,
  `exit 1` on any failure. No pause/delay before exit.
- UX: download progress (MB counter via Write-Progress), `[REGIX]`-prefixed status
  lines, success line mentions the INSERT menu.

## Decisions log

| Date       | Decision |
|------------|----------|
| 2026-09-17 | Ask clarification questions one at a time; each answer affects the next question |
| 2026-09-17 | DLL source: raw file from `main` branch (auto-updates with pushes), not GitHub Releases |
| 2026-09-17 | Always download fresh to `%TEMP%`, inject, then delete (best-effort; locked files cleaned on next run) |
| 2026-09-17 | Auto-close: `exit 0` on success, `exit 1` on any failure; no delay before exit |
| 2026-09-17 | No auto-elevation; print clear "run as Administrator" error and exit |
| 2026-09-17 | Target process fixed to `HD-Player`; no override in one-liner mode |
| 2026-09-17 | Keep `-DllPath` local-file behavior (skip download), incl. legacy `REIMANOS.dll` fallback |
| 2026-09-17 | Show download progress (MB counter) plus `[REGIX]` status lines |
| 2026-09-17 | Update README.md with the one-liner, prerequisites, and notes |
| 2026-09-17 | Documented one-liner: `irm https://raw.githubusercontent.com/official-jahid/internal-injector/main/Inject-REGIX.ps1 \| iex` |
| 2026-09-17 | Cloudflare Worker (`worker.js`) added: CLI clients get `Inject-REGIX.ps1` proxied live from raw `main`; browsers get an honest, responsive info page (requirements, what it does, exit codes, repo link) |
| 2026-09-17 | Injection chain must stay script-only: no auto-download/auto-run of extra binaries (e.g. injector.exe) was requested and rejected; the landing page must always disclose what the command does |
