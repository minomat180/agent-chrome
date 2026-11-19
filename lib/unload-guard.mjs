#!/usr/bin/env node
// Keep "Leave site?" from holding up logout, restart and shut down (macOS).
//
//   node unload-guard.mjs <port>
//
// When macOS logs out it asks every app to quit, and Chrome first runs each
// tab's beforeunload handler. An agent tab left on a half-filled form answers
// with a "Leave site?" dialog, inside a window that is minimised, so nobody
// sees it, and macOS gives up: "Google Chrome interrupted logout". agent-chrome accepts
// these dialogs itself, but only while one of its commands is attached to the
// tab, and at logout none is.
//
// So agent-chrome-ctl runs this next to the browser for as long as the browser
// lives: it stays attached to every tab and accepts beforeunload dialogs the
// moment they open, which is what agent-chrome does during a command anyway. Every
// other dialog (alert, confirm, prompt) is left alone. Nothing is injected
// into the pages: Page.enable only, never Runtime.enable (cdp.mjs refuses it).
// Exits when the browser goes away.

import { CDP } from "./cdp.mjs";

const port = Number(process.argv[2]);
if (!port) {
  console.error("usage: unload-guard.mjs <port>");
  process.exit(2);
}

// The browser may still be coming up (login), so keep trying for a while.
let cdp;
for (let i = 0; ; i++) {
  try {
    cdp = await CDP.connect(port);
    break;
  } catch (e) {
    if (i >= 30) {
      console.error(`unload-guard: ${e.message}`);
      process.exit(1);
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
}

const attached = new Set(); // targetIds

async function guard(targetId) {
  if (attached.has(targetId)) return;
  attached.add(targetId);
  try {
    const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    await cdp.send("Page.enable", {}, sessionId);
  } catch {
    attached.delete(targetId); // closed before we got to it
  }
}

cdp.on((msg) => {
  const p = msg.params || {};
  switch (msg.method) {
    case "Target.targetCreated":
      if (p.targetInfo.type === "page") guard(p.targetInfo.targetId);
      break;
    case "Target.targetDestroyed":
      attached.delete(p.targetId);
      break;
    case "Target.detachedFromTarget":
      if (p.targetId) attached.delete(p.targetId);
      break;
    case "Page.javascriptDialogOpening":
      // A agent-chrome command attached to the same tab may answer first; then this fails, harmlessly.
      if (p.type === "beforeunload") cdp.send("Page.handleJavaScriptDialog", { accept: true }, msg.sessionId).catch(() => {});
      break;
  }
});

// Reports every existing tab as created, then each new one as it opens.
await cdp.send("Target.setDiscoverTargets", { discover: true });
await cdp.closed;
process.exit(0);
