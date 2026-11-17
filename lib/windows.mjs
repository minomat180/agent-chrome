#!/usr/bin/env node
// Put every window of the agent's Chrome away, or bring them back (macOS).
//
//   node windows.mjs <port> minimized|normal [--create]
//
// --create: if the browser has no window (pib-chrome starts it with
// --no-startup-window), make one, in the background. Exits 0 when there is at
// least one window afterwards, 3 when there is none.
//
// Why minimised, of all things. On macOS the browser's windows are on mino's
// own screen (there is no cage to keep them in), and each of the obvious ways
// to keep them out of sight was measured on Chrome 157 and failed:
//   - hiding the app (open -j, Cmd-H): opening a tab shows the window again;
//   - parking the window off screen: Chrome keeps 40px of it on screen.
// A minimised window stays minimised through new tabs, navigation, clicks and
// screenshots, and with focus emulation (page.mjs) its tabs render as if they
// were in front.

import { CDP, sleep } from "./cdp.mjs";

// Returns how many windows there are (all now in that state).
export async function setWindows(cdp, state, { create = false } = {}) {
  let { targetInfos } = await cdp.send("Target.getTargets");
  if (create && !targetInfos.some((t) => t.type === "page")) {
    // windowState is a hint Chrome 157 ignores, but background: true keeps
    // the new window from coming forward until it is minimised below.
    await cdp.send("Target.createTarget", { url: "about:blank", newWindow: true, background: true, windowState: state });
    ({ targetInfos } = await cdp.send("Target.getTargets"));
  }
  const seen = new Set();
  for (const t of targetInfos.filter((t) => t.type === "page")) {
    const w = await cdp.send("Browser.getWindowForTarget", { targetId: t.targetId }).catch(() => null);
    if (!w || seen.has(w.windowId)) continue;
    seen.add(w.windowId);
    await setWindow(cdp, w, state);
  }
  return seen.size;
}

// One window, as Browser.getWindowForTarget gave it. True if it had to change.
// force: set it even if Chrome says it already is (while a window is being
// un-minimised, Chrome still reports it minimised).
export async function setWindow(cdp, w, state, { force = false } = {}) {
  if (w.bounds.windowState === state && !force) return false;
  const set = (windowState) => cdp.send("Browser.setWindowBounds", { windowId: w.windowId, bounds: { windowState } });
  // From maximised or full screen, Chrome only goes to another state by way
  // of normal. On macOS leaving full screen is an animation of about a
  // second, and a state set before it ends is dropped: the window would stay
  // on screen, un-minimised. So wait for normal before going on.
  await set(state).catch(async () => {
    await set("normal");
    if (state === "normal") return;
    for (let i = 0; i < 30; i++) {
      const { bounds } = await cdp.send("Browser.getWindowBounds", { windowId: w.windowId });
      if (bounds.windowState === "normal") break;
      await sleep(100);
    }
    await set(state);
  });
  return true;
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split("/").pop())) {
  const [port, state, flag] = process.argv.slice(2);
  if (!port || !["minimized", "normal"].includes(state)) {
    console.error("usage: windows.mjs <port> minimized|normal");
    process.exit(2);
  }
  try {
    const cdp = await CDP.connect(Number(port));
    process.exit((await setWindows(cdp, state, { create: flag === "--create" })) ? 0 : 3);
  } catch (e) {
    console.error(`windows.mjs: ${e.message}`);
    process.exit(1);
  }
}
