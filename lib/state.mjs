// Per-session state: which tabs this session owns, which one is current, and
// the ref table of the last snapshot per tab.
//
// Lives in $XDG_RUNTIME_DIR (tmpfs, wiped at reboot, same lifetime as the
// browser's own target ids). One JSON file per session key.

import { mkdirSync, readFileSync, writeFileSync, renameSync, readdirSync, statSync, rmSync } from "node:fs";
import { join } from "node:path";

export const stateDir = () => {
  const base = process.env.PIB_STATE_DIR || join(process.env.XDG_RUNTIME_DIR || "/tmp", "pib");
  mkdirSync(base, { recursive: true, mode: 0o700 });
  return base;
};

export const sessionKey = (explicit) =>
  String(explicit || process.env.PIB_SESSION || process.env.PI_SESSION_ID || "default").replace(/[^A-Za-z0-9._-]/g, "_");

const fileFor = (key) => join(stateDir(), `${key}.json`);

export function load(key) {
  try {
    const s = JSON.parse(readFileSync(fileFor(key), "utf8"));
    return { key, current: null, tabs: [], pages: {}, ...s };
  } catch {
    return { key, current: null, tabs: [], pages: {} };
  }
}

export function save(state) {
  const file = fileFor(state.key);
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(state), { mode: 0o600 });
  renameSync(tmp, file);
}

export function remove(key) {
  rmSync(fileFor(key), { force: true });
}

// Every session's state, for `tabs` (ownership column) and `gc`.
export function all() {
  const out = [];
  for (const name of readdirSync(stateDir())) {
    if (!name.endsWith(".json")) continue;
    const key = name.slice(0, -5);
    try {
      out.push({ ...load(key), mtime: statSync(fileFor(key)).mtimeMs });
    } catch {}
  }
  return out;
}

// Drop tab ids that no longer exist in the browser (closed, or browser restarted).
export function prune(state, liveIds) {
  state.tabs = state.tabs.filter((id) => liveIds.has(id));
  for (const id of Object.keys(state.pages)) if (!liveIds.has(id)) delete state.pages[id];
  if (state.current && !liveIds.has(state.current)) state.current = state.tabs.at(-1) || null;
  return state;
}
