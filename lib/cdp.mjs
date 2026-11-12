// Minimal Chrome DevTools Protocol client over the browser-level WebSocket.
//
// Dependency-free: Node's built-in global WebSocket and fetch (node >= 22).
// One connection to the *browser* endpoint, with flattened sessions for pages
// and out-of-process iframes, so a single socket can manage tabs and drive them.
//
// Deliberately never sends Runtime.enable. That one call is what makes CDP
// automation observable from inside a page (console arguments get serialized
// eagerly, which a page can detect with a getter). Runtime.evaluate and
// Runtime.callFunctionOn work fine without it.

import { get } from "node:http";

export class PibError extends Error {
  constructor(message, hint) {
    super(message);
    this.hint = hint;
  }
}

const FORBIDDEN = new Set(["Runtime.enable", "Console.enable"]);

export class CDP {
  #ws;
  #id = 0;
  #pending = new Map();
  #listeners = new Set();

  constructor(ws, info, port) {
    this.#ws = ws;
    this.info = info;
    this.port = port;
    ws.onmessage = (e) => {
      const msg = JSON.parse(e.data);
      if (msg.id !== undefined) {
        const p = this.#pending.get(msg.id);
        if (!p) return;
        this.#pending.delete(msg.id);
        clearTimeout(p.timer);
        if (msg.error) p.reject(new PibError(`${p.method}: ${msg.error.message}`));
        else p.resolve(msg.result);
        return;
      }
      for (const fn of [...this.#listeners]) fn(msg);
    };
    ws.onclose = () => {
      for (const p of this.#pending.values()) {
        clearTimeout(p.timer);
        p.reject(new PibError(`${p.method}: connection to the browser closed`));
      }
      this.#pending.clear();
    };
  }

  static async connect(port = 9222) {
    let info;
    try {
      // node:http rather than fetch(): fetch costs ~70ms of one-time setup per process.
      info = await new Promise((resolve, reject) => {
        const req = get({ host: "127.0.0.1", port, path: "/json/version", timeout: 3000 }, (res) => {
          let body = "";
          res.setEncoding("utf8");
          res.on("data", (d) => (body += d));
          res.on("end", () => {
            try {
              resolve(JSON.parse(body));
            } catch (err) {
              reject(err);
            }
          });
        });
        req.on("timeout", () => req.destroy(new Error("timeout")));
        req.on("error", reject);
      });
    } catch {
      throw new PibError(`no browser on 127.0.0.1:${port}`, "start it with: pib-chrome start");
    }
    const ws = new WebSocket(info.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      ws.onopen = resolve;
      ws.onerror = () => reject(new PibError("could not open the browser websocket"));
    });
    return new CDP(ws, info, port);
  }

  send(method, params = {}, sessionId, timeout = 20000) {
    if (FORBIDDEN.has(method)) {
      return Promise.reject(new PibError(`${method} is refused: it makes automation detectable by the page`));
    }
    const id = ++this.#id;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new PibError(`${method}: no answer after ${timeout}ms`));
      }, timeout);
      this.#pending.set(id, { resolve, reject, timer, method });
      const msg = { id, method, params };
      if (sessionId) msg.sessionId = sessionId;
      this.#ws.send(JSON.stringify(msg));
    });
  }

  // Subscribe to every event. Returns an unsubscribe function.
  on(fn) {
    this.#listeners.add(fn);
    return () => this.#listeners.delete(fn);
  }

  // Resolve with the first event matching `pred`, or null after `timeout` ms.
  once(pred, timeout = 5000) {
    return new Promise((resolve) => {
      const off = this.on((msg) => {
        if (!pred(msg)) return;
        clearTimeout(timer);
        off();
        resolve(msg);
      });
      const timer = setTimeout(() => {
        off();
        resolve(null);
      }, timeout);
    });
  }

  close() {
    try {
      this.#ws.close();
    } catch {}
  }
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
