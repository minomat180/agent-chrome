// Page snapshot: the accessibility tree, flattened to the things an agent acts
// on, each with a short ref (e12).
//
// Sources, all read-only and invisible to the page:
//   Accessibility.getFullAXTree  roles, names, states (pierces shadow DOM)
//   DOMSnapshot.captureSnapshot  cursor:pointer / click listeners, to catch
//                                clickable <div>s the AX tree calls "generic"
// Same-process iframes are read by frameId, out-of-process ones through their
// own auto-attached session.
//
// Refs are keyed by backendNodeId and kept across snapshots, so e12 stays e12
// while that node exists. A ref only dies when its element does.

const INTERACTIVE = new Set([
  "button", "link", "textbox", "searchbox", "combobox", "checkbox", "radio", "switch", "slider", "spinbutton",
  "menuitem", "menuitemcheckbox", "menuitemradio", "tab", "treeitem", "option", "DisclosureTriangle", "ColorWell",
  "Date", "DateTime", "InputTime", "Week", "Month", "PopUpButton", "ToggleButton",
]);
const COMPOSITE = new Set(["Date", "DateTime", "InputTime", "Week", "Month"]); // one field, many inner spinbuttons
const VALUED = new Set(["textbox", "searchbox", "combobox", "slider", "spinbutton", "Date", "DateTime", "InputTime", "Week", "Month", "ColorWell"]);
const SKIP_TEXT = new Set(["InlineTextBox", "LineBreak", "ListMarker"]);
const TYPE_WORTH_SHOWING = new Set(["password", "email", "number", "tel", "url", "file", "search", "range", "color", "time", "datetime-local", "month", "week"]);

const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);
const squash = (s) => String(s ?? "").replace(/\s+/g, " ").trim();
const q = (s) => JSON.stringify(s);

async function domFacts(cdp, sessionId) {
  // backendNodeId -> { tag, attrs, clickable }
  const facts = new Map();
  let snap;
  try {
    snap = await cdp.send("DOMSnapshot.captureSnapshot", { computedStyles: ["cursor"] }, sessionId);
  } catch {
    return facts;
  }
  const str = (i) => (i >= 0 ? snap.strings[i] : "");
  for (const doc of snap.documents) {
    const n = doc.nodes;
    const cursor = new Map();
    doc.layout.nodeIndex.forEach((idx, k) => cursor.set(idx, str(doc.layout.styles[k][0])));
    const listeners = new Set(n.isClickable?.index || []);
    for (let i = 0; i < n.backendNodeId.length; i++) {
      if (n.nodeType[i] !== 1) continue;
      const tag = str(n.nodeName[i]).toLowerCase();
      const attrs = {};
      const raw = n.attributes[i] || [];
      for (let a = 0; a < raw.length; a += 2) attrs[str(raw[a])] = str(raw[a + 1]);
      const pointer = cursor.get(i) === "pointer" && cursor.get(n.parentIndex[i]) !== "pointer";
      // <label> forwards clicks to its control, which is listed on its own.
      const clickable = tag !== "html" && tag !== "body" && tag !== "label" && cursor.has(i) && (pointer || listeners.has(i));
      facts.set(n.backendNodeId[i], { tag, attrs, clickable });
    }
  }
  return facts;
}

async function axTree(cdp, sessionId, frameId) {
  const { nodes } = await cdp.send("Accessibility.getFullAXTree", frameId ? { frameId } : {}, sessionId);
  const byId = new Map(nodes.map((n) => [n.nodeId, n]));
  return { root: nodes.find((n) => !n.parentId) || nodes[0], byId };
}

// Returns { items, refs }.  items: [{ depth, text, ref? }]
export async function snapshot(page, saved, { all = false } = {}) {
  const { cdp } = page;
  const [main, mainFacts, frameTree] = await Promise.all([
    axTree(cdp, page.sessionId),
    domFacts(cdp, page.sessionId),
    page.send("Page.getFrameTree"),
  ]);
  const localFrames = new Set();
  (function walkFrames(t) {
    for (const c of t.childFrames || []) {
      localFrames.add(c.frame.id);
      walkFrames(c);
    }
  })(frameTree.frameTree);

  // Stable ref numbering, reset when the document changes.
  const prior = saved && saved.loader === page.loaderId ? saved : { next: 1, ids: {} };
  const ids = {};
  let next = prior.next || 1;
  const refs = {};
  const lines = {};
  const items = [];

  const refFor = (b, f) => {
    const key = `${f || ""}:${b}`;
    const n = (ids[key] = prior.ids[key] ?? next++);
    refs[n] = f ? [b, f] : [b];
    return n;
  };

  function walker(tree, facts, ctx) {
    const props = (n) => Object.fromEntries((n.properties || []).map((p) => [p.name, p.value?.value]));
    const textOf = (n, limit = 200) => {
      let out = "";
      (function rec(x, top) {
        if (out.length > limit) return;
        // What a user typed into a field is not a label, and may be a secret.
        if (!top && VALUED.has(x.role?.value)) return;
        if (x.role?.value === "StaticText") out += " " + (x.name?.value || "");
        for (const id of x.childIds || []) {
          const c = tree.byId.get(id);
          if (c) rec(c, false);
        }
      })(n, true);
      return squash(out);
    };

    // Text of the nearest enclosing block that says more than the element's
    // own label: what tells two identical "Delete" buttons apart.
    const around = (n, own) => {
      let cur = n;
      for (let hops = 0; hops < 6 && cur.parentId; hops++) {
        cur = tree.byId.get(cur.parentId);
        if (!cur) break;
        const t = textOf(cur, 240);
        if (t.length > 220) break; // already a whole section: not a useful label
        const rest = squash(t.replace(own, " "));
        if (rest) return clip(rest, 60);
      }
      return "";
    };

    async function visit(n, depth, inSelect, parentName) {
      const role = n.role?.value || "";
      const name = squash(n.name?.value);
      const b = n.backendDOMNodeId;
      const fact = b ? facts.get(b) : undefined;
      let childDepth = depth;
      let skipChildren = false;
      let myName = parentName;

      if (!n.ignored && (role === "Iframe" || role === "IframePresentational") && b) {
        let frameId;
        try {
          frameId = (await cdp.send("DOM.describeNode", { backendNodeId: b }, ctx.sessionId)).node.frameId;
        } catch {}
        const label = name || fact?.attrs.title || fact?.attrs.name || "";
        const kid = frameId && page.kids.get(frameId);
        if (frameId && localFrames.has(frameId) && !ctx.f) {
          items.push({ depth, text: `[iframe${label ? " " + q(clip(label, 60)) : ""}]` });
          try {
            const sub = await axTree(cdp, page.sessionId, frameId);
            await walker(sub, facts, ctx)(sub.root, depth + 1);
          } catch {}
        } else if (kid && !ctx.f) {
          items.push({ depth, text: `[iframe${label ? " " + q(clip(label, 60)) : ""} cross-site]` });
          try {
            const [sub, subFacts] = await Promise.all([axTree(cdp, kid.sessionId), domFacts(cdp, kid.sessionId)]);
            await walker(sub, subFacts, { sessionId: kid.sessionId, f: frameId })(sub.root, depth + 1);
          } catch {}
        } else {
          items.push({ depth, text: `[iframe${label ? " " + q(clip(label, 60)) : ""} not readable]` });
        }
        return;
      }

      const interactive = !n.ignored && INTERACTIVE.has(role) && !(role === "option" && inSelect);
      const clickable = !interactive && fact?.clickable && role !== "RootWebArea" && role !== "LabelText";

      if (interactive) {
        const p = props(n);
        const a = fact?.attrs || {};
        let shown = role;
        if (fact?.tag === "select") shown = "select";
        else if (role === "textbox" && p.multiline) shown = "textarea";
        else if (COMPOSITE.has(role)) shown = role.toLowerCase();
        let label = name || (VALUED.has(role) ? "" : textOf(n, 80)); // a field's content is not its label
        let text = `${shown} ${q(clip(label, 90))}`;
        if (!label) {
          const hint = a.id ? `#${a.id}` : a.name ? `[name=${a.name}]` : a.class ? `.${a.class.split(/\s+/)[0]}` : "";
          text = `${shown} ${hint || '""'}`;
        }
        if (a.type && TYPE_WORTH_SHOWING.has(a.type)) text += ` type=${a.type}`;
        const value = n.value?.value;
        if (VALUED.has(role) && value !== undefined && String(value) !== "" && a.type !== "password") text += ` value=${q(clip(squash(value), 60))}`;
        else if (a.type === "password" && value) text += " value=(hidden)";
        if (fact?.tag === "select") {
          const opts = [];
          (function rec(x) {
            for (const id of x.childIds || []) {
              const c = tree.byId.get(id);
              if (!c) continue;
              if (c.role?.value === "option" || c.role?.value === "MenuListOption") opts.push(squash(c.name?.value));
              else rec(c);
            }
          })(n);
          if (opts.length) text += ` options=${opts.length > 12 ? `${opts.slice(0, 12).map((o) => clip(o, 24)).join("|")}|…(${opts.length})` : opts.map((o) => clip(o, 24)).join("|")}`;
        }
        if (p.checked === "true" || p.checked === true) text += " checked";
        else if (p.checked === "mixed") text += " mixed";
        if (p.pressed === "true" || p.pressed === true) text += " pressed";
        if (p.selected === true) text += " selected";
        if (p.expanded === true) text += " expanded";
        else if (p.expanded === false) text += " collapsed";
        if (p.disabled) text += " disabled";
        if (p.required) text += " required";
        if (p.readonly) text += " readonly";
        if (p.invalid && p.invalid !== "false") text += " invalid";
        if (all && role === "link" && a.href) text += ` -> ${clip(a.href, 100)}`;
        const ref = refFor(b, ctx.f);
        lines[ref] = text; // focus is shown but not diffed: it moves on every click and is noise
        items.push({ depth, ref, text, base: `${shown} ${label}`, focused: !!p.focused, around: () => around(n, label) });
        myName = label;
        childDepth = depth + 1;
        if (fact?.tag === "select" || COMPOSITE.has(role)) skipChildren = true;
      } else if (clickable) {
        const label = name || textOf(n, 200);
        if (label.length <= 160) {
          const a = fact.attrs;
          const hint = `${fact.tag}${a.id ? "#" + a.id : a.class ? "." + a.class.split(/\s+/)[0] : ""}`;
          const text = label ? `clickable ${q(clip(label, 90))}` : `clickable <${hint}>${a.title ? " " + q(clip(a.title, 40)) : ""}`;
          const ref = refFor(b, ctx.f);
          lines[ref] = text;
          items.push({ depth, ref, text, base: `clickable ${label}`, around: () => around(n, label) });
          myName = label;
          childDepth = depth + 1;
        }
      } else if (!n.ignored) {
        if (role === "heading") {
          const level = props(n).level || 2;
          items.push({ depth, text: `${"#".repeat(Math.min(level, 6))} ${clip(name || textOf(n, 120), 120)}` });
          myName = name;
        } else if (role === "dialog" || role === "alertdialog") {
          items.push({ depth, text: `[${role}${name ? " " + q(clip(name, 80)) : ""}]` });
          childDepth = depth + 1;
        } else if (role === "alert" || role === "status") {
          const t = name || textOf(n, 200);
          if (t) items.push({ depth, text: `[${role}] ${clip(t, 200)}` });
          myName = t;
        } else if (all) {
          if (role === "StaticText") {
            if (name && name !== parentName && !(parentName && parentName.includes(name))) {
              // "4" "items" "left" are three text nodes of one sentence: print one line.
              const prev = items.at(-1);
              if (prev?.raw !== undefined && prev.parent === n.parentId && prev.raw.length + name.length < 300) {
                prev.raw += " " + name;
                prev.text = `text ${q(prev.raw)}`;
              } else items.push({ depth, text: `text ${q(clip(name, 300))}`, raw: clip(name, 300), parent: n.parentId, quiet: true });
            }
          } else if (!SKIP_TEXT.has(role) && name && !["generic", "none", "RootWebArea", "paragraph", "LabelText", "listitem", "cell", "row", "gridcell"].includes(role)) {
            items.push({ depth, text: `${role} ${q(clip(name, 120))}`, quiet: true });
            myName = name;
            childDepth = depth + 1;
          }
        }
      }

      if (skipChildren) return;
      const nowInSelect = inSelect || role === "MenuListPopup" || fact?.tag === "select";
      for (const id of n.childIds || []) {
        const c = tree.byId.get(id);
        if (c && !SKIP_TEXT.has(c.role?.value)) await visit(c, childDepth, nowInSelect, myName);
      }
    }
    return (root, depth) => visit(root, depth, false, "");
  }

  await walker(main, mainFacts, { sessionId: page.sessionId })(main.root, 0);

  // Elements that would print identically get their surroundings appended.
  const twins = new Map();
  for (const it of items) if (it.ref) twins.set(it.base, [...(twins.get(it.base) || []), it]);
  for (const group of twins.values()) {
    if (group.length < 2) continue;
    const ctxs = group.map((it) => it.around());
    if (new Set(ctxs).size < 2) continue;
    group.forEach((it, i) => {
      if (!ctxs[i]) return;
      it.text += ` (in: ${ctxs[i]})`;
      lines[it.ref] = it.text;
    });
  }
  for (const it of items) {
    if (it.focused) it.text += " focused";
    delete it.around;
    delete it.base;
  }
  return { items, refs, lines, store: { loader: page.loaderId, next, ids, refs, lines } };
}

// Render items as text. `find` keeps matching lines (plus enclosing frame /
// dialog markers); `max` caps the output.
export function render(items, { find, max = 150 } = {}) {
  let rows = items;
  if (find) {
    const needle = find.toLowerCase();
    rows = items.filter((it) => it.text.toLowerCase().includes(needle) || (it.ref && `e${it.ref}` === needle));
  }
  const out = rows.slice(0, max).map((it) => `${"  ".repeat(Math.min(it.depth, 6))}${it.ref ? `e${it.ref} ` : ""}${it.text}`);
  if (rows.length > max) out.push(`… +${rows.length - max} more lines (narrow with: pib snap --find TEXT, or raise --max)`);
  if (!rows.length) out.push(find ? `(nothing matches ${q(find)})` : "(no interactive elements)");
  return out.join("\n");
}

// What changed between two snapshots of the same document.
export function diff(before, after, { max = 25 } = {}) {
  const added = [];
  const changed = [];
  let removed = 0;
  for (const [ref, text] of Object.entries(after)) {
    if (!(ref in before)) added.push(`+ e${ref} ${text}`);
    else if (before[ref] !== text) changed.push(`~ e${ref} ${text}`);
  }
  for (const ref of Object.keys(before)) if (!(ref in after)) removed++;
  const rows = [...changed, ...added];
  const out = rows.slice(0, max);
  if (rows.length > max) out.push(`… +${rows.length - max} more changes (pib snap)`);
  if (removed) out.push(`- ${removed} element${removed === 1 ? "" : "s"} removed`);
  return out;
}
