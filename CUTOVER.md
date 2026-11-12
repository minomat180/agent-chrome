# Cutover: pi-browser -> pib

Nothing below has been done. Until it is, `pi-chrome` owns the browser on 9222
and `agent_browser` is the default tool. `pib` already works against that
browser as it is (same port, same profile), so it can be tried first:

```
pib open https://example.com && pib close
```

Do the steps in order when no other session is using the browser.

1. **Stop the old browser, start the new one** (same profile, so every login carries over):

   ```
   pi-chrome stop
   pib-chrome start
   pib-chrome status        # expect: UP, background mode, chrome 157.x
   ```

   One-way step: the profile gets opened by Chrome 157. Chrome normally refuses
   to open a profile with an older version afterwards (expected behaviour, not
   tested here), so going back to pi-chrome means
   pointing it at the new binary too:
   `PI_CHROME_BIN=~/.local/share/pib/chrome/current/chrome pi-chrome start`.
   To keep a way back to 151, copy the profile first:
   `cp -a ~/.local/share/pi-browser/chrome-profile ~/.local/share/pi-browser/chrome-profile.bak-151`

2. **Autostart**: in `~/.config/mango/autostart.sh` replace the `pi-chrome start` line with `pib-chrome start`.

3. **Make the skill visible to every session**:

   ```
   ln -s ~/Projects/pib/skill ~/.pi/agent/skills/pib
   ```

4. **Remove the old tool** so sessions stop reaching for it:

   ```
   pi remove npm:pi-agent-browser-native
   ```

   and drop `export PI_AGENT_BROWSER_INLINE_IMAGE_MAX_BYTES=20480` from `~/.bashrc`.
   The `agent-browser` binary in `~/.local` can stay or go (`npm rm -g agent-browser`); nothing needs it.

5. **`~/.pi/agent/AGENTS.md`**: replace the `pi-browser` registry entry and the
   "agent_browser usage lessons" section with a pointer to the pib skill; keep
   "HARD RULES FOR BROWSER USE" and "USE THE BROWSER AND THE VAULT" as they are,
   with `browser-login` replaced by `pib secret`. Update the subagent leak check
   (no more `agent-browser-linux-x64` orphans or `/tmp/agent-browser-chrome-*`).

6. **Other users of the old pieces** - check before deleting anything:
   - `~/Projects/pi-browser/bin/browser-login` and `grab-secret-to-file` (superseded by `pib secret` / `pib eval`)
   - `~/vault/pi-browser-memory/agent-browser-manual.md` (obsolete after cutover)
   - T3 Code driving via `connect 9333` used `agent_browser`; with pib it is `PIB_PORT=9333 pib ...`

7. **Archive, don't delete**: leave `~/Projects/pi-browser` in place for a week or two.

Rollback before step 4 is just: `pib-chrome stop`, restore the autostart line,
`pi-chrome start` (with the `PI_CHROME_BIN` note from step 1).
