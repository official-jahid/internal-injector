/**
 * REGIX Injector - Cloudflare Worker (transparent delivery front)
 *
 * WHAT IT DOES
 *   - CLI clients (irm <worker-url> | iex, curl, wget, Windows PowerShell,
 *     pwsh) get the exact Inject-REGIX.ps1 script text, proxied LIVE from
 *     raw.githubusercontent.com/official-jahid/internal-injector/main.
 *     Every push to main updates the one-liner instantly - no redeploy.
 *   - Browsers get a responsive info page that honestly explains what the
 *     command does (what it downloads, what it injects into, requirements,
 *     exit codes) and links to the repo so people can read the script first.
 *
 * DEPLOY
 *   Option A (no tooling): Cloudflare Dashboard -> Workers & Pages ->
 *     Create Worker -> "Edit code" -> paste this file -> Deploy.
 *   Option B (wrangler):   npx wrangler deploy
 *   Your URL: https://<worker-name>.<account-subdomain>.workers.dev
 *
 * BY DESIGN: this worker never serves or executes anything except the
 * reviewed Inject-REGIX.ps1. No extra binaries. No hidden chains.
 */

const SCRIPT_URL = 'https://raw.githubusercontent.com/official-jahid/internal-injector/main/Inject-REGIX.ps1';
const REPO_URL = 'https://github.com/official-jahid/internal-injector';
const RAW_DLL_URL = 'https://raw.githubusercontent.com/official-jahid/internal-injector/main/REGIX.dll';

// True when the request comes from a browser; false for CLI/API clients.
// CLI user agents first (Windows PowerShell 5.1 / pwsh 7 / curl / wget),
// then modern browser signals (Sec-Fetch-Mode, Accept: text/html).
// Unknown clients default to the SCRIPT so `irm | iex` never breaks.
function isBrowserRequest(request) {
  const ua = request.headers.get('user-agent') || '';
  const accept = request.headers.get('accept') || '';
  const secFetchMode = request.headers.get('sec-fetch-mode') || '';
  if (/WindowsPowerShell|PowerShell\/|pwsh\/|curl\/|Wget\/|libcurl/i.test(ua)) return false;
  if (secFetchMode === 'navigate') return true;
  if (/text\/html/i.test(accept)) return true;
  return false;
}

// Proxy the script from raw GitHub (60s edge cache) as text/plain.
async function scriptResponse() {
  const upstream = await fetch(SCRIPT_URL, { headers: { 'user-agent': 'regix-worker/1.0' }, cf: { cacheTtl: 60 } });
  if (!upstream.ok) {
    return new Response(
      'Could not load Inject-REGIX.ps1 from GitHub (HTTP ' + upstream.status + ').\n' +
        'Use the raw URL directly instead:\n' + SCRIPT_URL + '\n',
      { status: 502, headers: { 'content-type': 'text/plain; charset=utf-8' } }
    );
  }
  return new Response(await upstream.text(), {
    status: 200,
    headers: {
      'content-type': 'text/plain; charset=utf-8',
      'cache-control': 'public, max-age=60',
      'x-regix-source': 'github:official-jahid/internal-injector:main',
    },
  });
}

// Landing page shown to browsers. Honest by design: it explains exactly what
// the command does and links to the repo/script so people can read it first.
// NOTE: no backticks / ${} / stray backslashes inside this template literal.
const PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>REGIX Injector - one-liner for BlueStacks 5</title>
<style>
  :root { --bg:#0a0e13; --panel:#121821; --line:#233042; --text:#e8eef7; --muted:#93a4bb; --accent:#ff3b5c; --accent2:#ff8a3d; --ok:#3ddc84; }
  * { box-sizing: border-box; }
  html, body { margin: 0; }
  body { background: radial-gradient(1100px 520px at 82% -10%, #1a2334 0%, var(--bg) 55%); color: var(--text); font-family: system-ui, -apple-system, "Segoe UI", Roboto, Arial, sans-serif; line-height: 1.55; padding: clamp(16px, 4vw, 48px); }
  .wrap { max-width: 980px; margin: 0 auto; }
  .badge { display: inline-block; font-size: 12px; letter-spacing: .12em; color: var(--muted); border: 1px solid var(--line); border-radius: 999px; padding: 4px 12px; }
  h1 { font-size: clamp(34px, 7vw, 64px); line-height: 1.05; margin: 14px 0 6px; letter-spacing: -0.02em; }
  h1 span { background: linear-gradient(90deg, var(--accent), var(--accent2)); -webkit-background-clip: text; background-clip: text; color: transparent; }
  .tag { color: var(--muted); font-size: clamp(15px, 2.4vw, 18px); margin: 0 0 18px; }
  .warn { border: 1px solid #5a3a12; background: #241a08; color: #ffd9a0; padding: 12px 14px; border-radius: 10px; font-size: 14px; margin-bottom: 18px; }
  .warn a { color: #ffc46b; }
  .cmdbox { display: flex; gap: 10px; align-items: stretch; flex-wrap: wrap; background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 12px; }
  #cmd { flex: 1 1 320px; font-family: ui-monospace, Consolas, "Cascadia Mono", Menlo, monospace; font-size: clamp(13px, 2.2vw, 15px); background: #0b1017; border: 1px solid var(--line); border-radius: 8px; padding: 12px; overflow-x: auto; white-space: nowrap; color: var(--text); }
  #copyBtn { cursor: pointer; border: 0; border-radius: 8px; padding: 0 20px; font-weight: 700; font-size: 15px; color: #160409; background: linear-gradient(90deg, var(--accent), var(--accent2)); }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 14px; margin-top: 18px; }
  article { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 16px 18px; }
  article h2 { font-size: 14px; margin: 0 0 10px; letter-spacing: .08em; text-transform: uppercase; color: var(--accent2); }
  article ul, article ol { margin: 0; padding-left: 20px; }
  li { margin: 6px 0; font-size: 14.5px; }
  code { font-family: ui-monospace, Consolas, Menlo, monospace; font-size: 13px; background: #0b1017; border: 1px solid var(--line); border-radius: 5px; padding: 1px 5px; }
  .muted { color: var(--muted); }
  .exit0 { color: var(--ok); font-weight: 700; }
  .exit1 { color: var(--accent); font-weight: 700; }
  footer { margin-top: 22px; display: flex; gap: 18px; flex-wrap: wrap; align-items: center; }
  footer a { color: var(--muted); font-size: 14px; }
  footer a:hover { color: var(--text); }
  @media (max-width: 480px) { .cmdbox { flex-direction: column; } #copyBtn { padding: 12px 20px; } }
</style>
</head>
<body>
<div class="wrap">
  <span class="badge">BLUESTACKS 5 &middot; X64 &middot; HD-PLAYER.EXE</span>
  <h1>REGIX <span>INJECTOR</span></h1>
  <p class="tag">One-liner PowerShell injector for BlueStacks 5. Downloads <b>REGIX.dll</b>, injects it into <b>HD-Player.exe</b>, open the menu with <b>INSERT</b>.</p>

  <div class="warn"><b>Heads-up:</b> this command downloads and runs code on your PC. <a href="https://raw.githubusercontent.com/official-jahid/internal-injector/main/Inject-REGIX.ps1" target="_blank" rel="noopener">Read the script</a> before running it.</div>

  <div class="cmdbox">
    <code id="cmd">irm https://your-worker.workers.dev | iex</code>
    <button id="copyBtn" onclick="copyCmd()">Copy</button>
  </div>

  <div class="grid">
    <article>
      <h2>What it does</h2>
      <ol>
        <li>Relaunches itself in 64-bit PowerShell if started from 32-bit.</li>
        <li>Checks that PowerShell is running <b>as Administrator</b>.</li>
        <li>Finds <b>HD-Player.exe</b> and verifies it is x64.</li>
        <li>Downloads the latest <b>REGIX.dll</b> (~27&nbsp;MB) from GitHub into <code>%TEMP%</code> - with a progress bar, one retry and PE-header checks.</li>
        <li>Injects it via a <code>LoadLibraryW</code> remote thread, cleans up, then closes PowerShell automatically.</li>
      </ol>
    </article>
    <article>
      <h2>Requirements</h2>
      <ul>
        <li>Windows 10/11 x64</li>
        <li>BlueStacks 5 running (HD-Player.exe)</li>
        <li>PowerShell started <b>as Administrator</b> (32-bit hosts auto-relaunch to 64-bit)</li>
        <li>Internet access to github.com</li>
      </ul>
    </article>
    <article>
      <h2>Exit codes</h2>
      <ul>
        <li><span class="exit0">0</span> - injected and verified: the DLL is reported loaded in the game and it is still alive 20s later. Press <b>INSERT</b> in BlueStacks for the menu. The window closes right away.</li>
        <li><span class="exit1">1</span> - anything else, including "the DLL loaded but the game was stopped right after". The error prints in red, then the window closes.</li>
      </ul>
    </article>
    <article>
      <h2>If the game closes right after injecting</h2>
      <p class="muted">The injector only opens the target, writes the DLL path and starts a remote <code>LoadLibraryW</code>; it never terminates anything. If the game closes after a <b>verified</b> load, the loaded DLL ended it: tests here show a harmless DLL leaves HD-Player alive, while REGIX.dll stops a host process itself (it carries its own process checks). The command reports that honestly instead of faking a success.</p>
    </article>
    <article>
      <h2>Good to know</h2>
      <ul>
        <li>The DLL always comes from the repo's <b>main</b> branch - latest push wins.</li>
        <li><code>%TEMP%\\REGIX.dll</code> can stay locked while the game has it loaded; the next run cleans it up.</li>
        <li>Antivirus may flag injectors (the script uses <code>CreateRemoteThread</code>).</li>
        <li class="muted">This page is served by a Cloudflare Worker; PowerShell clients get the script text instead.</li>
      </ul>
    </article>
  </div>

  <footer>
    <a href="https://github.com/official-jahid/internal-injector" target="_blank" rel="noopener">GitHub repo</a>
    <a href="https://raw.githubusercontent.com/official-jahid/internal-injector/main/Inject-REGIX.ps1" target="_blank" rel="noopener">Raw script</a>
    <a href="https://raw.githubusercontent.com/official-jahid/internal-injector/main/REGIX.dll" target="_blank" rel="noopener">REGIX.dll (raw)</a>
  </footer>
</div>
<script>
function copyCmd() {
  var t = document.getElementById('cmd').textContent;
  var b = document.getElementById('copyBtn');
  function fallback() {
    var r = document.createRange();
    r.selectNode(document.getElementById('cmd'));
    var s = window.getSelection();
    s.removeAllRanges();
    s.addRange(r);
  }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(t).then(function () {
      b.textContent = 'Copied!';
      setTimeout(function () { b.textContent = 'Copy'; }, 1500);
    }, fallback);
  } else {
    fallback();
  }
}
document.getElementById('cmd').textContent = 'irm ' + location.origin + ' | iex';
</script>
</body>
</html>
`;
function pageResponse() {
  return new Response(PAGE, {
    status: 200,
    headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'public, max-age=300' },
  });
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, '') || '/';
    // Explicit script paths: always serve the script, whatever the client.
    if (path === '/Inject-REGIX.ps1' || path === '/script' || path === '/raw') {
      return scriptResponse();
    }
    if (path === '/' || path === '') {
      return isBrowserRequest(request) ? pageResponse() : scriptResponse();
    }
    // Anything else: show the info page.
    return pageResponse();
  },
};

