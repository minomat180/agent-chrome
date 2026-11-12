# pib

Browser access for Pi: one real, logged-in Chrome, driven from the shell.

`pib` replaced `pi-browser` + the `agent_browser` tool on 2026-11-12
([CUTOVER.md](CUTOVER.md) records what was switched and how to go back).

```
pib open https://dash.cloudflare.com     # this session's own tab; lists what is on the page
pib fill e3 mino@example.com
pib click "text=Log in"                  # prints what changed, so no snapshot round trip
pib close
```

Two commands, no dependencies beyond Node >= 22, bash and python3:

| | |
|---|---|
| `pib` | drives pages (CDP client, about 2,000 lines of JS in `bin/pib` + `lib/`) |
| `pib-chrome` | starts / stops / updates the agent's Chrome (`bin/pib-chrome`) |

The agent-facing manual is [skill/SKILL.md](skill/SKILL.md); `pib help` lists the commands.

## Why replace what was there

Measured on this machine on 2026-11-12, not assumed.

**1. The default browser was the wrong browser.** A plain `agent_browser` call
does not use the logged-in Chrome. It launches its own: `HeadlessChrome/151`
user agent, `navigator.webdriver === true`, SwiftShader WebGL. That browser sat
on Cloudflare's "Just a moment..." page at scrapingcourse.com/cloudflare-challenge
for the whole 12 s wait, while the same page passed in a Chrome started like
pi-chrome. Reaching the real browser took `connect 9222` with
`sessionMode: "fresh"`, every session. In the session logs, 14 of 21 tool results
showing a bot wall (Cloudflare interstitial, Turnstile, DataDome) came from
that default browser (rough classification: no `connect` earlier in the session).

**2. A tenth of all calls failed, mostly on the wrapper's own rules.**
2,015 `agent_browser` calls across 45 sessions: 181 failures (9.0%). 50 were
"stale ref" rejections, 33 validation errors, 29 tab-verification errors
("active page became unverified", tab drift), 10 version-pin mismatches between
the wrapper and the CLI it wraps.

**3. It was detectable even when attached to the real browser.** On
bot-detector.rebrowser.net, in the same Chrome:

| driver | red | yellow |
|---|---|---|
| playwright-cli 0.1.24 | 3 (sourceUrl leak, main world, Runtime.enable) | 1 |
| chrome-devtools-mcp CLI 1.13.0 | 3 (same three) | 1 |
| agent-browser 0.42.0 | 2 (main world, Runtime.enable) | 1 |
| browser-harness 0.1.13 | 2 (main world, Runtime.enable) | 1 |
| **pib** | **0** | **0** |

The yellow was the browser, not the driver: a headless `cage` has no input
devices, so Chrome reported `(any-pointer: none)` and `(hover: none)`.

**4. The Chrome itself was stale.** `/opt/google/chrome` was 151.0.7922.71
(stable from 29 July to 4 August 2026); current stable was 157.0.8103.78. Nothing updated it.

**5. Lifecycle sharp edges.** `pi-chrome stop` ran `pgrep -x cage` and killed
any cage on the machine. Every `login` / `background` restarted the one shared
browser under whatever other session was using it (seen three times that day).
Sessions shared tabs with no notion of whose was whose.

Alternatives were tried before building (same table). None removed the
Runtime.enable signal; Playwright and Puppeteer add a second one.
browser-harness, the closest fit, sends each script's source and the tail of
its output to PostHog unless `BH_TELEMETRY=0` is set - not acceptable as a
default next to logged-in accounts. `pi-browser-harness` (npm) is pi-native and
has per-session isolation, but registers 40 tools in every session and also
enables the Runtime domain. So: a small driver of our own, borrowing their good
ideas (AX-tree refs that re-resolve at action time, compositor-level input,
one window per session).

## How it works

- **One browser.** `pib` only ever attaches to `127.0.0.1:$PIB_PORT` (9222). It
  cannot launch a browser, so there is no anonymous fallback to fall into.
- **No daemon.** Each call connects, acts, saves a little state and exits
  (about 0.2 s overhead). Nothing to leak or orphan.
- **A tab (in its own window) per session**, keyed by `PI_SESSION_ID`. State is
  in `$XDG_RUNTIME_DIR/pib/<session>.json`. `pib tabs` shows ownership;
  `pib close` cleans up; `pib gc` closes tabs of sessions idle for 6 h.
- **Never `Runtime.enable`.** `lib/cdp.mjs` refuses to send it. Evaluation and
  snapshots do not need it.
- **Reads run in an isolated world** (`Page.createIsolatedWorld`), invisible to
  page scripts. `pib eval --main` opts into the page's world.
- **Trusted input.** Clicks and keys are `Input.dispatch*` events:
  `event.isTrusted === true`, and they pass through shadow DOM and iframes.
  Out-of-process iframes are reached through auto-attached child sessions.
- **Refs are `backendNodeId`s.** `e12` stays `e12` while the node exists; it is
  refused only when the document was replaced or the node removed.
- **Every action reports its effect**: changed and new elements, new text
  lines, URL changes, answered dialogs. Snapshots are capped (60 lines after a
  navigation, 150 for `snap`).
- **Dialogs are answered inside the call**, because nothing stays around to
  hold them: `alert` accepted, `confirm`/`prompt` dismissed unless `--accept`.
- **Secrets** enter through `pib secret <target>` on stdin, typed key by key,
  and that field is masked in all later output.

`pib-chrome` keeps the old design (dedicated profile, headful Chrome inside a
headless `cage`, minimal flags) and fixes its problems: it signals only the
processes it started (pidfiles, private process name `pib-cage`), refuses to
touch a browser it did not start, holds a virtual pointer device on the
compositor (`libexec/virtual-pointer.py`, Wayland wire protocol, no
dependencies), sets the output to 1920x1080, and `pib-chrome update` installs
current stable Chrome into `~/.local/share/pib/chrome/<version>` after checking
Google's signature on the apt `Release` file and the hash chain down to the
`.deb`. `pib-chrome status` warns when the running Chrome is a major version behind.

## Limits

- Chromium only, and only an already-running browser.
- No console or network log capture: both need long-lived listeners (and
  console capture needs `Runtime.enable`). `pib eval` and `pib cdp` cover the
  occasional need.
- A dialog left open by something other than pib cannot be answered over CDP;
  `pib` detects the frozen tab and says to close it.
- `pib-chrome login` still restarts the browser to show it. The warning now
  says how many tabs that closes.
- Iframes nested inside a cross-site iframe are not listed.
- A trusted, human-looking browser does not make captchas go away, and pib
  does not try to solve them. Stop and ask.

## Tests

```
test/run.sh        # 123 end-to-end checks against test/fixture, in a throwaway Chrome on port 9557
```

Covers forms (text, controlled inputs, date, contenteditable, select, upload),
secrets, shadow DOM (open and closed), same-origin and cross-site iframes,
covers and overlays, dialogs, hover, downloads, navigation, tabs, batches, two
concurrent sessions, and the pointer / webdriver / viewport checks.
