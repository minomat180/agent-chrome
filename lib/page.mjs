// One attached tab: evaluation, node resolution, trusted input, waiting.
//
// Design rules (each one is there because of a measured problem):
//   - No Runtime.enable (see cdp.mjs).
//   - Reads run in an isolated world, so page scripts cannot observe them.
//   - Clicks and keys go through Input.dispatch*: compositor-level, trusted
//     (event.isTrusted === true), and they pass through shadow DOM and iframes.
//   - Elements are addressed by backendNodeId, which stays valid across
//     re-renders for as long as the node itself exists.

import { AgentChromeError, sleep } from "./cdp.mjs";

const jitter = (min, max) => min + Math.random() * (max - min);

const KEYS = {
  Enter: { code: "Enter", vk: 13, text: "\r" },
  Tab: { code: "Tab", vk: 9 },
  Escape: { code: "Escape", vk: 27 },
  Backspace: { code: "Backspace", vk: 8 },
  Delete: { code: "Delete", vk: 46 },
  ArrowLeft: { code: "ArrowLeft", vk: 37 },
  ArrowUp: { code: "ArrowUp", vk: 38 },
  ArrowRight: { code: "ArrowRight", vk: 39 },
  ArrowDown: { code: "ArrowDown", vk: 40 },
  Home: { code: "Home", vk: 36 },
  End: { code: "End", vk: 35 },
  PageUp: { code: "PageUp", vk: 33 },
  PageDown: { code: "PageDown", vk: 34 },
  Space: { key: " ", code: "Space", vk: 32, text: " " },
};
for (let i = 1; i <= 12; i++) KEYS[`F${i}`] = { code: `F${i}`, vk: 111 + i };
const KEY_ALIASES = { esc: "Escape", return: "Enter", del: "Delete", up: "ArrowUp", down: "ArrowDown", left: "ArrowLeft", right: "ArrowRight", pgup: "PageUp", pgdn: "PageDown", pagedown: "PageDown", pageup: "PageUp" };
const MODS = { alt: 1, ctrl: 2, control: 2, meta: 4, cmd: 4, super: 4, shift: 8 };

export class Page {
  constructor(cdp, targetId, sessionId) {
    this.cdp = cdp;
    this.targetId = targetId;
    this.sessionId = sessionId;
    this.kids = new Map(); // out-of-process iframes: frame target id -> { sessionId, url }
    this.dialogs = []; // JS dialogs answered during this invocation, for the report
    this.policy = { accept: false, promptText: undefined }; // shared with the CLI
    this.loading = false;
    this.navigated = false; // main frame committed a new document during this invocation
    this.inflight = new Map(); // requestId -> start time
    this.lastNetActivity = Date.now();
    this.downloads = new Map();
    this.newTabs = []; // targets opened by this tab during this invocation
    this.mainFrameId = null;
    this.#worlds = new Map();
  }

  #worlds;

  static async attach(cdp, targetId) {
    let sessionId;
    try {
      ({ sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true }));
    } catch {
      throw new AgentChromeError(`tab ${targetId.slice(0, 8)} no longer exists`, "agent-chrome tabs  /  agent-chrome open <url>");
    }
    const page = new Page(cdp, targetId, sessionId);
    cdp.on((msg) => page.#onEvent(msg));
    // A JS dialog left open by someone else blocks the renderer: every call
    // would hang, and CDP can only answer a dialog it saw open. Detect that
    // up front instead of timing out 20s later.
    const alive = await cdp.send("Runtime.evaluate", { expression: "1" }, sessionId, 1500).then(() => true, () => false);
    if (!alive) {
      throw new AgentChromeError(`tab ${targetId.slice(0, 8)} is not responding (most likely a JavaScript dialog was left open in it)`, "agent-chrome tab close, then agent-chrome open <url> again");
    }
    await page.send("Page.enable");
    const tree = await page.send("Page.getFrameTree");
    page.mainFrameId = tree.frameTree.frame.id;
    page.loaderId = tree.frameTree.frame.loaderId;
    await Promise.all([
      page.send("Network.enable"),
      // A tab in a window that is not on top still has to behave as focused,
      // or key events and focus-gated pages misbehave.
      page.send("Emulation.setFocusEmulationEnabled", { enabled: true }),
      page.send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }),
      cdp.send("Target.setDiscoverTargets", { discover: true }).catch(() => {}),
    ]);
    return page;
  }

  send(method, params = {}, timeout) {
    return this.cdp.send(method, params, this.sessionId, timeout);
  }

  #onEvent(msg) {
    const p = msg.params || {};
    if (msg.sessionId === this.sessionId) {
      switch (msg.method) {
        case "Page.javascriptDialogOpening": {
          // There is no daemon to hold a dialog open between calls, so it is
          // answered right here. alert/beforeunload can only be accepted;
          // confirm/prompt are dismissed unless the caller passed --accept,
          // which makes "cancel" the default for anything destructive.
          const accept = p.type === "alert" || p.type === "beforeunload" || this.policy.accept;
          const params = { accept };
          if (accept && p.type === "prompt") params.promptText = this.policy.promptText ?? p.defaultPrompt ?? "";
          this.dialogs.push({ type: p.type, message: p.message, accepted: accept });
          this.send("Page.handleJavaScriptDialog", params).catch(() => {});
          break;
        }
        case "Page.frameStartedLoading":
          if (p.frameId === this.mainFrameId) this.loading = true;
          break;
        case "Page.frameStoppedLoading":
          if (p.frameId === this.mainFrameId) this.loading = false;
          break;
        case "Page.frameNavigated":
          if (!p.frame.parentId) {
            this.navigated = true;
            this.loaderId = p.frame.loaderId;
            this.mainFrameId = p.frame.id;
            this.#worlds.clear();
          }
          break;
        case "Network.requestWillBeSent":
          // An iframe's document request can finish in another process (site
          // isolation), so its end is never reported here: do not wait on it.
          if (p.type !== "WebSocket" && p.type !== "EventSource" && !(p.type === "Document" && p.frameId !== this.mainFrameId)) this.inflight.set(p.requestId, Date.now());
          this.lastNetActivity = Date.now();
          break;
        case "Network.loadingFinished":
        case "Network.loadingFailed":
          this.inflight.delete(p.requestId);
          this.lastNetActivity = Date.now();
          break;
        case "Page.downloadWillBegin":
          this.downloads.set(p.guid, { name: p.suggestedFilename, url: p.url, state: "inProgress" });
          break;
        case "Page.downloadProgress": {
          const d = this.downloads.get(p.guid);
          if (d) Object.assign(d, { state: p.state, received: p.receivedBytes });
          break;
        }
        case "Target.attachedToTarget":
          if (p.targetInfo.type === "iframe") this.kids.set(p.targetInfo.targetId, { sessionId: p.sessionId, url: p.targetInfo.url });
          break;
        case "Target.detachedFromTarget":
          for (const [id, k] of this.kids) if (k.sessionId === p.sessionId) this.kids.delete(id);
          break;
      }
    } else if (!msg.sessionId && msg.method === "Target.targetCreated") {
      const t = p.targetInfo;
      if (t.type === "page" && t.openerId === this.targetId) this.newTabs.push(t.targetId);
    }
  }

  // ---- evaluation -------------------------------------------------------

  async #world(sessionId, frameId) {
    const key = `${sessionId}:${frameId || ""}`;
    if (!this.#worlds.has(key)) {
      let fid = frameId;
      if (!fid) {
        const tree = await this.cdp.send("Page.getFrameTree", {}, sessionId);
        fid = tree.frameTree.frame.id;
      }
      const { executionContextId } = await this.cdp.send("Page.createIsolatedWorld", { frameId: fid, worldName: "agent-chrome" }, sessionId);
      this.#worlds.set(key, executionContextId);
    }
    return this.#worlds.get(key);
  }

  // Evaluate an expression. Isolated world by default: shares the DOM with the
  // page but not its JS globals, and is invisible to page scripts.
  async eval(expression, { main = false, timeout = 20000, sessionId = this.sessionId } = {}) {
    const run = async () => {
      const params = { expression, returnByValue: true, awaitPromise: true, userGesture: true };
      if (!main) params.contextId = await this.#world(sessionId);
      return this.cdp.send("Runtime.evaluate", params, sessionId, timeout);
    };
    let r;
    try {
      r = await run();
    } catch (err) {
      if (!/Cannot find context|context with specified id/i.test(err.message)) throw err;
      this.#worlds.clear(); // the document changed under us; one retry in a fresh world
      r = await run();
    }
    if (r.exceptionDetails) {
      const d = r.exceptionDetails;
      const text = d.exception?.description?.split("\n")[0] || d.text;
      const hint = !main && /ReferenceError|is not defined|undefined \(reading/.test(text) ? "page JS globals are only visible with --main" : undefined;
      throw new AgentChromeError(`js: ${text}`, hint);
    }
    return r.result?.value;
  }

  // Call `fn` (source of a function) with `this` bound to the node.
  async callOn(node, fn, args = [], { main = false } = {}) {
    const sessionId = this.#sessionFor(node);
    const params = { backendNodeId: node.b };
    if (!main) params.executionContextId = await this.#world(sessionId);
    let objectId;
    try {
      ({ object: { objectId } } = await this.cdp.send("DOM.resolveNode", params, sessionId));
    } catch (err) {
      if (/context/i.test(err.message)) {
        this.#worlds.clear();
        params.executionContextId = await this.#world(sessionId);
        ({ object: { objectId } } = await this.cdp.send("DOM.resolveNode", params, sessionId));
      } else throw gone(node);
    }
    const r = await this.cdp.send(
      "Runtime.callFunctionOn",
      { objectId, functionDeclaration: fn, arguments: args.map((value) => ({ value })), returnByValue: true, awaitPromise: true, userGesture: true },
      sessionId,
    );
    this.cdp.send("Runtime.releaseObject", { objectId }, sessionId).catch(() => {});
    if (r.exceptionDetails) throw new AgentChromeError(`js: ${r.exceptionDetails.exception?.description?.split("\n")[0] || r.exceptionDetails.text}`);
    return r.result?.value;
  }

  #sessionFor(node) {
    if (!node.f) return this.sessionId;
    const kid = this.kids.get(node.f);
    if (!kid) throw new AgentChromeError("that element's iframe is gone", "agent-chrome snap");
    return kid.sessionId;
  }

  // ---- resolving targets --------------------------------------------------

  // CSS selector -> node, searched in the main document and same-process frames.
  async query(selector) {
    const expr = `(() => { const all = document.querySelectorAll(${JSON.stringify(selector)}); return all.length; })()`;
    let count;
    try {
      count = await this.eval(expr);
    } catch (err) {
      throw new AgentChromeError(`invalid selector ${JSON.stringify(selector)}: ${err.message.replace(/^js: /, "")}`);
    }
    if (!count) return { node: null, count: 0 };
    const contextId = await this.#world(this.sessionId);
    const { result } = await this.send("Runtime.evaluate", { expression: `document.querySelector(${JSON.stringify(selector)})`, contextId });
    const { node } = await this.send("DOM.describeNode", { objectId: result.objectId });
    this.send("Runtime.releaseObject", { objectId: result.objectId }).catch(() => {});
    return { node: { b: node.backendNodeId }, count };
  }

  // Centre of the element in main-viewport CSS pixels, scrolled into view.
  async locate(node) {
    const sessionId = this.#sessionFor(node);
    try {
      await this.cdp.send("DOM.scrollIntoViewIfNeeded", { backendNodeId: node.b }, sessionId);
    } catch (err) {
      if (/No node|not find|does not belong/i.test(err.message)) throw gone(node);
      // Detached or non-rendered nodes: fall through, getContentQuads reports it.
    }
    // Scrolling is not instantaneous (smooth scrolling, sticky headers, late
    // layout), so read the position until two reads agree instead of trusting
    // the first one. A stale position is how clicks land on the wrong element.
    let quads;
    let last = "";
    for (let i = 0; i < 12; i++) {
      try {
        ({ quads } = await this.cdp.send("DOM.getContentQuads", { backendNodeId: node.b }, sessionId));
      } catch {
        throw gone(node);
      }
      const now = JSON.stringify(quads);
      if (now === last) break;
      last = now;
      await sleep(50);
    }
    const quad = quads.find((q) => Math.abs((q[2] - q[0]) * (q[7] - q[1])) >= 1);
    if (!quad) throw new AgentChromeError(`${node.ref || "element"} is not visible (no layout box)`, "it may be hidden or collapsed; agent-chrome snap to see what is on screen");
    let x = (quad[0] + quad[2] + quad[4] + quad[6]) / 4;
    let y = (quad[1] + quad[3] + quad[5] + quad[7]) / 4;
    if (node.f) {
      // Quads from an out-of-process iframe are relative to that frame.
      const off = await this.#frameOffset(node.f);
      x += off.x;
      y += off.y;
    }
    return { x: Math.round(x * 10) / 10, y: Math.round(y * 10) / 10 };
  }

  async #frameOffset(frameId) {
    const { backendNodeId } = await this.send("DOM.getFrameOwner", { frameId });
    const { model } = await this.send("DOM.getBoxModel", { backendNodeId });
    return { x: model.content[0], y: model.content[1] };
  }

  // What would a click at `pt` actually hit? Uses the page's own hit test
  // (elementFromPoint), stepping into shadow roots and same-origin iframes.
  // Returns:
  //   null              the node itself, something inside it, or an interactive
  //                     ancestor it belongs to (an icon inside its button)
  //   { label: {x,y} }  the node is an invisible form control; click its label
  //                     there instead (how styled checkboxes and radios work)
  //   "<div#x.cls>"     something else is in the way
  async coveredBy(node, pt) {
    if (node.f) return null; // hit-testing across process boundaries is not meaningful from here
    try {
      return await this.callOn(
        node,
        `function (x, y) {
          const inside = (outer, inner) => { for (let n = inner; n; n = n.parentNode || n.host) if (n === outer) return true; return false; };
          const ACTIVE = "a[href],button,summary,[role=button],[role=link],[role=menuitem],[role=tab],[role=option],[onclick]";
          let doc = document, hit = null, ox = 0, oy = 0;
          for (let depth = 0; depth < 8; depth++) {
            hit = doc.elementFromPoint(x, y);
            while (hit && hit.shadowRoot) {
              const inner = hit.shadowRoot.elementFromPoint(x, y);
              if (!inner || inner === hit) break;
              hit = inner;
            }
            if (!hit || !/^I?FRAME$/.test(hit.tagName) || hit === this) break;
            let sub = null;
            try { sub = hit.contentDocument; } catch (e) {}
            if (!sub) break;
            const r = hit.getBoundingClientRect();
            const dx = r.left + hit.clientLeft, dy = r.top + hit.clientTop;
            x -= dx; y -= dy; ox += dx; oy += dy;
            doc = sub;
          }
          if (!hit) return null;
          if (inside(this, hit)) return null;
          const label = hit.closest ? hit.closest("label") : null;
          if (label && (label.control === this || inside(label, this))) return null;
          // A closed shadow root cannot be hit-tested from outside: the answer
          // stops at its host. If the node lives in there, that is as good as it gets.
          for (let r = this.getRootNode(); r && r.host; r = r.host.getRootNode()) if (r.host === hit && !hit.shadowRoot) return null;
          if (inside(hit, this)) {
            // The click lands on an ancestor. Fine if that ancestor is the real
            // control (target is a decoration inside a button or link).
            const active = this.closest ? this.closest(ACTIVE) : null;
            if (active && inside(active, hit)) return null;
          }
          // An invisible checkbox / radio / file input is operated through its label.
          const own = this.labels && this.labels[0];
          if (own && this.ownerDocument === doc) {
            const r = own.getClientRects()[0];
            if (r && r.width > 0 && r.height > 0) {
              for (const px of [r.left + Math.min(6, r.width / 2), r.left + r.width / 2, r.right - Math.min(6, r.width / 2)]) {
                const py = r.top + r.height / 2;
                const at = doc.elementFromPoint(px, py);
                // Not on a link or button inside the label: that would do something else.
                if (at && inside(own, at) && !(at.closest("a,button") && inside(own, at.closest("a,button")))) return { label: { x: px + ox, y: py + oy } };
              }
            }
          }
          const cls = typeof hit.className === "string" && hit.className.trim() ? "." + hit.className.trim().split(/\\s+/).slice(0, 2).join(".") : "";
          return "<" + hit.tagName.toLowerCase() + (hit.id ? "#" + hit.id : "") + cls + ">";
        }`,
        [pt.x, pt.y],
      );
    } catch {
      return null; // could not ask (navigating, node gone): let the click itself decide
    }
  }

  // ---- input --------------------------------------------------------------

  #input(method, params, sessionId = this.sessionId) {
    return this.cdp.send(method, params, sessionId);
  }

  async mouse(type, pt, extra = {}) {
    await this.#input("Input.dispatchMouseEvent", { type, x: pt.x, y: pt.y, button: "none", pointerType: "mouse", ...extra });
  }

  async clickAt(pt, { button = "left", count = 1 } = {}) {
    await this.mouse("mouseMoved", pt);
    await sleep(jitter(20, 60));
    for (let i = 1; i <= count; i++) {
      await this.mouse("mousePressed", pt, { button, buttons: 1, clickCount: i });
      await sleep(jitter(30, 80));
      await this.mouse("mouseReleased", pt, { button, buttons: 0, clickCount: i });
    }
  }

  // Click an element. Waits briefly for a transient cover (spinners, fading
  // overlays) to clear instead of failing on the first look.
  async click(node, { force = false, button, count, wait = 2000 } = {}) {
    let pt = await this.locate(node);
    if (!force) {
      const deadline = Date.now() + wait;
      let cover;
      while ((cover = await this.coveredBy(node, pt))) {
        if (cover.label) {
          pt = cover.label;
          break;
        }
        if (Date.now() > deadline) {
          throw new AgentChromeError(`${node.ref || "element"} is covered by ${cover}`, "close whatever is on top, or repeat with --force to click the point anyway");
        }
        await sleep(150);
        pt = await this.locate(node);
      }
    }
    await this.clickAt(pt, { button, count });
    return pt;
  }

  async hover(node) {
    const pt = await this.locate(node);
    await this.mouse("mouseMoved", pt);
    return pt;
  }

  // Wheel-scroll at a point (default: middle of the viewport).
  async wheel(dy, pt, dx = 0) {
    const m = await this.metrics();
    const at = pt || { x: m.w / 2, y: m.h / 2 };
    await this.#input("Input.dispatchMouseEvent", { type: "mouseWheel", x: at.x, y: at.y, deltaX: dx, deltaY: dy, pointerType: "mouse" });
    await sleep(250);
  }

  async metrics() {
    return this.eval(`({ w: innerWidth, h: innerHeight, y: Math.round(scrollY), max: Math.round(Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0) - innerHeight) })`);
  }

  async insertText(text, node) {
    await this.#input("Input.insertText", { text }, node ? this.#sessionFor(node) : this.sessionId);
  }

  // Per-character key events with human-ish pacing. For secrets and for the
  // rare field that ignores insertText.
  async typeKeys(text, node, { min = 40, max = 130 } = {}) {
    const sid = node ? this.#sessionFor(node) : this.sessionId;
    for (const ch of text) {
      await this.#input("Input.dispatchKeyEvent", { type: "keyDown", text: ch, key: ch, unmodifiedText: ch }, sid);
      await this.#input("Input.dispatchKeyEvent", { type: "keyUp", key: ch }, sid);
      await sleep(jitter(min, max));
    }
  }

  async press(combo, node) {
    const parts = combo.split("+");
    let name = parts.pop();
    if (name === "" && combo.endsWith("+")) name = "+";
    let modifiers = 0;
    for (const m of parts) {
      const bit = MODS[m.toLowerCase()];
      if (!bit) throw new AgentChromeError(`unknown modifier "${m}" in ${combo}`, "modifiers: ctrl, shift, alt, meta");
      modifiers |= bit;
    }
    name = KEY_ALIASES[name.toLowerCase()] || name;
    let spec = KEYS[name] || KEYS[name[0]?.toUpperCase() + name.slice(1)];
    let key = name;
    if (spec) key = spec.key || Object.keys(KEYS).find((k) => KEYS[k] === spec);
    else if ([...name].length === 1) {
      const upper = name.toUpperCase();
      spec = { code: /[a-z]/i.test(name) ? `Key${upper}` : /\d/.test(name) ? `Digit${name}` : "", vk: upper.charCodeAt(0), text: modifiers & ~8 ? undefined : name };
    } else throw new AgentChromeError(`unknown key "${name}"`, "e.g. Enter, Tab, Escape, Backspace, ArrowDown, PageDown, F5, a, ctrl+a, shift+Tab");
    const sid = node ? this.#sessionFor(node) : this.sessionId;
    const base = { key, code: spec.code, windowsVirtualKeyCode: spec.vk, nativeVirtualKeyCode: spec.vk, modifiers };
    const text = modifiers & ~8 ? undefined : spec.text;
    await this.#input("Input.dispatchKeyEvent", { type: text ? "keyDown" : "rawKeyDown", ...base, ...(text ? { text, unmodifiedText: text } : {}) }, sid);
    await sleep(jitter(25, 60));
    await this.#input("Input.dispatchKeyEvent", { type: "keyUp", ...base }, sid);
  }

  // ---- waiting ------------------------------------------------------------

  // After an action: let a started navigation finish, then let the network go quiet.
  async settle({ navTimeout = 15000, idleMax = 3500, quiet = 350 } = {}) {
    await sleep(120);
    const t0 = Date.now();
    const busy = () => {
      const now = Date.now();
      for (const [id, started] of this.inflight) if (now - started > 4000) this.inflight.delete(id); // long polls, streams
      return this.loading || this.inflight.size > 0 || now - this.lastNetActivity < quiet;
    };
    for (;;) {
      const elapsed = Date.now() - t0;
      if (this.loading ? elapsed > navTimeout : elapsed > idleMax) break;
      if (!busy()) break;
      await sleep(60);
    }
    return { timedOut: this.loading };
  }

  async waitFor(check, { timeout = 15000, interval = 200, what = "condition" } = {}) {
    const deadline = Date.now() + timeout;
    for (;;) {
      let ok = false;
      try {
        ok = await check();
      } catch {}
      if (ok) return true;
      if (Date.now() > deadline) throw new AgentChromeError(`timed out after ${timeout}ms waiting for ${what}`);
      await sleep(interval);
    }
  }

  async navigate(url, { timeout = 30000 } = {}) {
    this.navigated = false;
    const loaded = this.cdp.once((m) => m.sessionId === this.sessionId && m.method === "Page.loadEventFired", timeout);
    const r = await this.send("Page.navigate", { url }, timeout);
    if (r.errorText && r.errorText !== "net::ERR_ABORTED") throw new AgentChromeError(`navigation failed: ${r.errorText}`);
    if (r.errorText === "net::ERR_ABORTED" || r.isDownload) return { download: true }; // the URL was a download
    if (!r.loaderId) {
      await this.settle({ idleMax: 1500 }); // same-document navigation (#hash): no load event will come
      return {};
    }
    const ev = await loaded;
    await this.settle({ idleMax: 3000 });
    return { slow: !ev };
  }

  async info() {
    const { targetInfo } = await this.cdp.send("Target.getTargetInfo", { targetId: this.targetId });
    return { url: targetInfo.url, title: targetInfo.title };
  }
}

function gone(node) {
  return new AgentChromeError(`${node.ref || "element"} is gone (removed from the page)`, "agent-chrome snap for the current refs");
}
