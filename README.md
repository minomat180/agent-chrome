# agent-chrome

A shell command that lets a coding agent such as Claude Code drive one real,
signed-in Chrome over the DevTools protocol, and tells it after every action
what changed on the page.

![agent-chrome filling and submitting the httpbin.org order form from a terminal](docs/demo/demo.gif)

That is the whole loop: `open` lists what can be acted on, each element gets a
ref (`e1`, `e10`), and every `fill` or `click` answers with the lines that
changed, so the agent rarely needs another snapshot or a screenshot. Recorded
with [docs/demo/play.sh](docs/demo/play.sh) against a throwaway browser;
httpbin.org echoes the submitted form back.

I use it every day: my Claude Code sessions on a NixOS server and on a Mac use
it to read dashboards, create tokens and check CI in accounts I am signed in to.

## Why I wrote it

Before this, my agents used a browser tool for the pi coding harness that wraps
[agent-browser](https://github.com/vercel-labs/agent-browser). I went through
the session logs on 2026-11-12 before replacing it:

- **2,015 calls across 45 sessions, 181 failures (9.0%).** 50 were "stale ref"
  rejections, 33 validation errors, 29 tab-verification errors, 10 version
  mismatches between the wrapper and the CLI it wrapped.
- **By default it launched its own headless Chrome** (`HeadlessChrome/151`,
  `navigator.webdriver === true`), which sat on Cloudflare's "Just a moment..."
  page while the same URL passed in a normal Chrome. By a rough classification, 14
  of the 21 bot walls in the logs came from that browser.
- **Even attached to the real browser it was detectable.** On
  [bot-detector.rebrowser.net](https://bot-detector.rebrowser.net/), in the
  same Chrome:

| driver | red | yellow |
|---|---|---|
| playwright-cli 0.1.24 | 3 (sourceUrl leak, main world, Runtime.enable) | 1 |
| chrome-devtools-mcp CLI 1.13.0 | 3 (same three) | 1 |
| agent-browser 0.42.0 | 2 (main world, Runtime.enable) | 1 |
| browser-harness 0.1.13 | 2 (main world, Runtime.enable) | 1 |
| **agent-chrome** | **0** | **0** |

The yellow came from the browser, not the driver: Chrome inside a headless
compositor has no pointer device and reports `(hover: none)`. `agent-chrome-ctl`
now adds a virtual one. How to reproduce the table:
[test/compare/README.md](test/compare/README.md).

None of the existing drivers avoided `Runtime.enable`, the most common CDP
automation signal. browser-harness came closest, but it sends each script's
source and the tail of its output to PostHog unless `BH_TELEMETRY=0` is set,
which I did not want next to signed-in accounts. So I wrote a small driver and
kept their good ideas: accessibility-tree refs that re-resolve when used, and
input dispatched at the compositor level.

## Running it

Needs Node 22 or newer, bash, python3 and curl. On Linux also
[cage](https://github.com/cage-kiosk/cage) and `wlr-randr`, plus gpg and `ar`
for `agent-chrome-ctl update`; on macOS nothing else. There are no npm dependencies and no build step.

```sh
git clone https://github.com/minomat180/agent-chrome && cd agent-chrome
export PATH="$PWD/bin:$PATH"

agent-chrome-ctl start            # Chrome with its own profile, CDP on 127.0.0.1:9222
agent-chrome open example.com     # this session's tab; prints the elements with refs
agent-chrome click "text=Learn more"
agent-chrome close                # closes this session's tabs
```

If no Chrome is installed yet, run `agent-chrome-ctl update` first.
`agent-chrome help` lists every command. To sign the browser in to something,
`agent-chrome-ctl login <url>` shows it on screen and `agent-chrome-ctl background`
hides it again.

For Claude Code, link the agent manual as a skill:
`ln -s "$PWD/skill" ~/.claude/skills/agent-chrome`. [skill/SKILL.md](skill/SKILL.md)
is the copy my own agents load, so it refers to my setup (a `vault` skill for
passwords, my standing rules for the browser).

Environment: `AGENT_CHROME_PORT` (9222), `AGENT_CHROME_HOME`
(`~/.local/share/agent-chrome`), `AGENT_CHROME_PROFILE`, `AGENT_CHROME_SIZE`
(1920x1080), `AGENT_CHROME_BIN`, `AGENT_CHROME_SESSION`.

### Linux

Chrome runs headful inside a headless `cage` compositor: a real GPU and a real
user agent, but no window on anyone's screen. `agent-chrome-ctl update` installs
the current stable Chrome into `~/.local/share/agent-chrome/chrome/<version>`
after checking Google's signature on the apt `Release` file and the hash chain
down to the `.deb`; `status` warns when the running Chrome is a major version
behind.

On NixOS, Google's prebuilt binary does not run unpatched, so `agent-chrome-ctl`
uses `google-chrome-stable` from nixpkgs and `update` defers to
`nixos-rebuild`. What my server runs:

```nix
environment.systemPackages = with pkgs; [ google-chrome cage wlr-randr ];  # google-chrome is unfree
hardware.graphics.enable = true;   # without it Chrome has no GL at all
systemd.user.services.agent-chrome = {
  wantedBy = [ "default.target" ];
  path = [ "/run/current-system/sw" "/run/wrappers" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    ExecStart = "%h/.local/bin/agent-chrome-ctl start";
    ExecStop = "%h/.local/bin/agent-chrome-ctl stop";
  };
};
```

With lingering enabled for the user, it starts at boot. A headless server has
no screen for `login`; sign in through an SSH tunnel to port 9222 and
`chrome://inspect` in a local Chrome instead.

### macOS

`agent-chrome-ctl` hands over to `bin/agent-chrome-ctl-macos`, with the same
commands. `update` installs Google's universal Chrome privately after checking
its code signature (Team ID `EQHXZ8M8AV`) and Gatekeeper. There is no cage, so
"background" means minimised: Chrome is launched hidden, given one window over
CDP and kept minimised, and focus emulation keeps its tabs rendering. `login`
and `background` un-minimise and minimise it without a restart, so tabs and
session cookies survive. `lib/unload-guard.mjs` accepts "Leave site?" dialogs,
which otherwise blocked logout and shutdown behind a window nobody could see.
I start it at login with a LaunchAgent that runs `agent-chrome-ctl start`.

## How it works

- **One browser, attached, never launched.** `agent-chrome` only connects to
  `127.0.0.1:$AGENT_CHROME_PORT`. If nothing is there it fails and says to run
  `agent-chrome-ctl start`, so an agent can never fall back to an anonymous
  headless browser.
- **No daemon.** Each call connects, acts, saves a little state and exits. A
  read such as `agent-chrome get title` takes about 0.1 s end to end.
- **A tab per agent session**, keyed by `AGENT_CHROME_SESSION` or Claude Code's
  `CLAUDE_CODE_SESSION_ID`, all in one shared window. A background tab does not
  render, so each call brings its own tab to the front first. `agent-chrome tabs`
  shows who owns what; `agent-chrome gc` closes tabs of sessions idle for 6 h.
- **`Runtime.enable` is never sent.** [lib/cdp.mjs](lib/cdp.mjs) refuses it.
  Reads run in an isolated world (`Page.createIsolatedWorld`) that page scripts
  cannot see; `eval --main` opts into the page's own world.
- **Trusted input.** Clicks and keys are `Input.dispatch*` events
  (`event.isTrusted === true`) aimed at hit-tested coordinates, so they work
  through open and closed shadow DOM and cross-site iframes. A click on an
  element covered by a modal reports what covers it.
- **Refs are `backendNodeId`s.** `e12` stays valid while that node exists and is
  refused once the document is replaced.
- **Every action reports its effect:** changed and new elements, new text, URL
  changes, answered dialogs. `alert` is accepted; `confirm` and `prompt` are
  dismissed unless the command repeats with `--accept`.
- **Secrets** go in through `agent-chrome secret <target>` on stdin, are typed key
  by key, and that field is masked in every later report, so a password piped
  from a password manager never appears in the agent's context.

`agent-chrome-ctl` signals only processes it started (pidfiles, checked against
the live process, and a private process name), and never adds
`--enable-automation`, `--headless` or `--no-sandbox`.

## Tests

```sh
test/run.sh      # 123 end-to-end checks in a throwaway Chrome on port 9557
```

The suite starts its own browser and a fixture server on `localhost:8765` and
never touches 9222. It covers forms (controlled inputs, date, contenteditable,
select, upload), secrets and masking, shadow DOM, same-origin and cross-site
iframes, covers and overlays, dialogs, hover, downloads, tabs, batches, two
concurrent sessions, and the pointer, `webdriver` and viewport checks. It passes
123/123 on NixOS (Chrome 157) and on macOS 26 (arm64).

## Limits

- Chromium only, and only a browser that is already running.
- No console or network log capture: both need long-lived listeners, and
  console capture needs `Runtime.enable`. `agent-chrome eval` and
  `agent-chrome cdp <Method> [json]` cover the occasional need.
- A dialog opened by something other than agent-chrome cannot be answered over
  CDP; the tab is reported as frozen.
- On Linux, `login`, `background` and `restart` restart the shared browser,
  closing every session's tabs and dropping session-only cookies.
- Iframes nested inside a cross-site iframe are not listed.
- It does not solve captchas. A human-looking browser sees fewer of them; when
  one appears, the agent is told to stop and ask.

This is a personal tool for my own two machines. It works for me every day,
but it is not packaged and I am not trying to grow it into a general project.

## License

MIT, see [LICENSE](LICENSE).
