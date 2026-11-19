# Cutover: pi-browser -> agent-chrome (done 2026-11-12)

On 2026-11-19 `pib` was renamed `agent-chrome` (`pib` -> `agent-chrome`,
`pib-chrome` -> `agent-chrome-ctl`, repo `mino-shared/pib` ->
`mino-shared/agent-chrome`) and mino stopped using the pi harness. This file
uses the new command names; backup file names keep their original spelling.
The `pi-chrome` shim (step 7) was removed in that rename.

What was switched, in order, and how to undo it.

| Step | What | Undo |
|---|---|---|
| 1 | `pi-chrome stop`; profile copied to `~/.local/share/pi-browser/chrome-profile.bak-151-20261112` (1.2 GB); `agent-chrome-ctl start` on the same profile and port with the private Chrome 157 | see "Going back" |
| 2 | `~/.config/mango/autostart.sh`: `pi-chrome start` -> `agent-chrome-ctl start` | `autostart.sh.bak-20261112-pre-pib` |
| 3 | Skill linked: `~/.pi/agent/skills/pib -> ~/Projects/pib/skill` (pi harness, gone; now `~/.claude/skills/agent-chrome`) | remove the link |
| 4 | `pi remove npm:pi-agent-browser-native` (the `agent_browser` tool) | `pi install npm:pi-agent-browser-native`; `settings.json.bak-20261112-pre-pib` |
| 5 | `~/.bashrc`: dropped the `PI_AGENT_BROWSER_INLINE_IMAGE_MAX_BYTES` block | `.bashrc.bak-20261112-pre-pib` |
| 6 | `~/.pi/agent/AGENTS.md`: registry entry, hard-rule wording, subagent cleanup, browser notes rewritten for agent-chrome | `AGENTS.md.bak-20261112-pre-pib` |
| 7 | `~/.local/bin/pi-chrome` now points at `bin/pi-chrome-shim`, which forwards to `agent-chrome-ctl` | relink to `~/Projects/pi-browser/bin/pi-chrome` |
| 8 | `~/Projects/pi-browser/README.md` and `~/vault/pi-browser-memory/agent-browser-manual.md` marked archived / obsolete | - |

Left in place on purpose:

- `~/Projects/pi-browser` (archived, rollback material) and `~/.local/bin/browser-login` (still works against the new browser; superseded by `agent-chrome secret`).
- The `agent-browser` binary in `~/.local` (`npm rm -g agent-browser` removes it). Pi sessions that were already running during the cutover still have the old tool loaded; restart them, or tell them to use `agent-chrome`.
- `/opt/google/chrome` (151): used by `google-chrome` for pptx-maker and hallmark. Updating it needs root and is a separate decision.

## Going back

The profile has been opened by Chrome 157. Chrome normally refuses to open a
profile with an older version (expected behaviour, not tested here), so there
are two ways back:

- Old launcher, new Chrome: `agent-chrome-ctl stop`, relink step 7, then
  `PI_CHROME_BIN=~/.local/share/agent-chrome/chrome/current/chrome pi-chrome start`.
- Everything as it was, including Chrome 151: `agent-chrome-ctl stop`, move the
  current profile aside, rename the `.bak-151-20261112` copy back to
  `chrome-profile`, undo steps 2 to 7. Logins made after the cutover are lost.

Delete the profile backup once agent-chrome has proven itself; it holds live session cookies.

## After the cutover

- Keep Chrome current: `agent-chrome-ctl status` warns when it is a major version
  behind; `agent-chrome-ctl update && agent-chrome-ctl restart` fixes it (the restart
  closes every session's tabs).
- Any browser restart signs out sites whose login is a session-only cookie.
  Tick "Remember me" when signing in.
