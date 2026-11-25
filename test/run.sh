#!/usr/bin/env bash
# End-to-end tests: a throwaway Chrome (own profile, own port, headless cage)
# driven through the real CLI against test/fixture.
#
#   test/run.sh            run everything
#   KEEP=1 test/run.sh     leave the browser up afterwards (port 9557)
#
# Never touches the real agent browser on 9222.

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
WORK="$(mktemp -d /tmp/agent-chrome-test.XXXXXX)"
export AGENT_CHROME_PORT=9557 AGENT_CHROME_HOME="$WORK/home" AGENT_CHROME_PROFILE="$WORK/profile" AGENT_CHROME_STATE_DIR="$WORK/state" AGENT_CHROME_SESSION=test
PATH="$ROOT/bin:$PATH"
F=http://localhost:8765

pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); printf 'FAIL  %s\n      %s\n' "$1" "$2"; }
# has <name> <needle> <command...>   output must contain needle
has()  { local name="$1" needle="$2"; shift 2; local out; out="$("$@" 2>&1)"; if [[ "$out" == *"$needle"* ]]; then ok; else bad "$name" "wanted: $needle | got: $(echo "$out" | head -c 300 | tr '\n' '~')"; fi; }
# hasnt <name> <needle> <command...> output must NOT contain needle
hasnt(){ local name="$1" needle="$2"; shift 2; local out; out="$("$@" 2>&1)"; if [[ "$out" != *"$needle"* ]]; then ok; else bad "$name" "must not contain: $needle"; fi; }
ref()  { agent-chrome snap --find "$1" | sed -n 's/^ *\(e[0-9]*\) .*/\1/p' | head -1; }

cleanup() {
  [ -n "${KEEP:-}" ] || agent-chrome-ctl stop >/dev/null 2>&1
  test/serve-fixture.sh stop
  [ -n "${KEEP:-}" ] || rm -rf "$WORK"
}
trap cleanup EXIT

test/serve-fixture.sh >/dev/null
agent-chrome-ctl start >/dev/null || { echo "could not start the test browser"; exit 1; }

# --- lifecycle ---------------------------------------------------------------
has  "status: no tab"            "none yet"                  agent-chrome status
has  "snap without tab explains" "agent-chrome open"                  agent-chrome snap
has  "open lists the page"       'button "Save form"'        agent-chrome open $F/index.html
has  "bare host gets a scheme"   "agent-chrome fixture"               agent-chrome open localhost:8765/index.html

# --- snapshot ----------------------------------------------------------------
S="$(agent-chrome snap)"
for want in 'textbox "Email" type=email required' 'type=password' 'select "Country"' 'options=--|Switzerland|Germany|France' \
            'checkbox "I agree"' 'clickable "Clickable card (div)"' 'button "Shadow open button"' 'button "Shadow closed button"' \
            '[iframe "same-origin frame"]' '[iframe "cross-site frame" cross-site]' 'type=file' '## Form'; do
  if [[ "$S" == *"$want"* ]]; then ok; else bad "snap contains" "$want"; fi
done
[ "$(echo "$S" | grep -c 'Frame button')" = 2 ] && ok || bad "snap" "both iframes' buttons listed"
hasnt "hidden things are not listed" "Hidden menu item"       agent-chrome snap
has   "snap --find narrows"       'button "Confirm"'          agent-chrome snap --find confirm
has   "snap -a adds text"         'text "'                    agent-chrome snap -a

# --- forms -------------------------------------------------------------------
has "fill"                 "filled"                      agent-chrome fill "#email" mino@example.com
has "fill reports rewrite" 'changed it to "HELLO"'       agent-chrome fill "#ctl" hello
has "fill textarea"        'value="two words"'           agent-chrome fill "#notes" two words
has "fill date"            'value="2026-12-24"'          agent-chrome fill "#date" 2026-12-24
has "fill contenteditable" "rich text"                   agent-chrome fill "#editor" rich text
has "fill empties"         "filled"                      agent-chrome fill "#notes" ""
has "fill empties (check)" '""'                          agent-chrome eval 'JSON.stringify(document.querySelector("#notes").value)'
has "select by label"      'selected "Germany"'          agent-chrome select "#country" Germany
has "select bad option"    "options:"                    agent-chrome select "#country" Narnia
has "check"                "checked"                     agent-chrome check "#agree"
has "check is idempotent"  "already checked"             agent-chrome check "#agree"
has "uncheck"              "unchecked"                   agent-chrome uncheck "#agree"
has "fill on checkbox"     "agent-chrome check"                   agent-chrome fill "#agree" x
has "styled checkbox (invisible input under its label)" "checked" agent-chrome check "#cc"
has "styled checkbox took" "true"                        agent-chrome eval 'document.querySelector("#cc").checked'
has "upload"               "attached 1 file"             agent-chrome upload "#file" "$ROOT/test/fixture/data.csv"
has "upload missing file"  "no such file"                agent-chrome upload "#file" /nonexistent/file
has "submit"               'submitted:{"email":"mino@example.com"' agent-chrome click "text=Save form"

# --- secrets -----------------------------------------------------------------
PW="$(ref Password)"
OUT="$(printf 'hunter2-S3cret' | agent-chrome secret "$PW" 2>&1)"
[[ "$OUT" == *"secret typed"* ]] && ok || bad "secret" "$OUT"
[[ "$OUT" != *"hunter2"* ]] && ok || bad "secret" "value leaked into output"
has   "secret reached the field" "14"                    agent-chrome eval 'document.querySelector("#pw").value.length'
hasnt "get value masks it"       "hunter2"               agent-chrome get value "$PW"
hasnt "snap masks it"            "hunter2"               agent-chrome snap
hasnt "text masks it"            "hunter2"               agent-chrome text "#pw"

# --- clicking ----------------------------------------------------------------
has "trusted events"        "trusted=true"       agent-chrome click "text=Trusted check"
has "clickable div"         "card-clicked"       agent-chrome click "text=Clickable card"
has "open shadow DOM"       "shadow-open"        agent-chrome click "text=Shadow open button"
has "closed shadow DOM"     "shadow-closed"      agent-chrome click "text=Shadow closed button"
has "offscreen is scrolled" "bottom-clicked"     agent-chrome click "text=Bottom button"
has "unknown ref"           "unknown ref"        agent-chrome click e9999
has "bad selector"          "invalid selector"   agent-chrome click "###"
has "no match"              "no element matches" agent-chrome click "#nope"
has "ambiguous text"        "elements match"     agent-chrome click "text=Frame button"
has "coordinates"           "clicked 5,5"        agent-chrome click 5,5

# same-process and cross-site iframes
FB="$(agent-chrome snap --find 'Frame button' | sed -n 's/^ *\(e[0-9]*\) .*/\1/p')"
has "iframe click (same origin)"  "msg:frame-button" agent-chrome click "$(echo "$FB" | sed -n 1p)"
has "iframe click (cross-site)"   "clicked"          agent-chrome click "$(echo "$FB" | sed -n 2p)"
FI="$(agent-chrome snap --find 'Frame input' | sed -n 's/^ *\(e[0-9]*\) .*/\1/p')"
has "iframe fill (same origin)"   'value="in frame"'   agent-chrome fill "$(echo "$FI" | sed -n 1p)" in frame
has "iframe fill (cross-site)"    'value="cross site"' agent-chrome fill "$(echo "$FI" | sed -n 2p)" cross site

# appearing content, covers, hover
agent-chrome -q click "text=Reveal later" >/dev/null
has "wait text"              "Late button"     agent-chrome wait text "Late button"
has "late element clickable" "late-clicked"    agent-chrome click "text=Late button"
agent-chrome -q click "text=Show overlay briefly" >/dev/null
has "waits out a brief cover" "covered-clicked" agent-chrome click "text=Covered button"
agent-chrome -q click "text=Show overlay forever" >/dev/null
has "reports a lasting cover" "covered by <div#overlay>" agent-chrome click "text=Covered button"
has "--force clicks anyway"   "clicked"                  agent-chrome click "text=Covered button" --force
agent-chrome eval 'document.getElementById("overlay").style.display="none"; 1' >/dev/null
has "hover reveals"           'button "Hidden menu item"' agent-chrome hover ".hovermenu"

# --- dialogs -----------------------------------------------------------------
has "alert accepted"        '(accepted)'        agent-chrome click "text=Alert"
has "alert did not block"   "alert-done"        agent-chrome eval 'document.getElementById("log").textContent'
has "confirm dismissed"     "DISMISSED"         agent-chrome click "text=Confirm"
has "confirm=false"         "confirm=false"     agent-chrome eval 'document.getElementById("log").textContent'
has "confirm --accept"      "-> accepted"       agent-chrome click "text=Confirm" --accept
has "confirm=true"          "confirm=true"      agent-chrome eval 'document.getElementById("log").textContent'

# --- reading -----------------------------------------------------------------
has "eval isolated"         "undefined"          agent-chrome eval 'typeof window.pageGlobal'
has "eval --main"           "42"                 agent-chrome eval --main 'window.pageGlobal.answer'
has "eval hint"             "--main"             agent-chrome eval 'pageGlobal.answer'
has "eval statements"       "3"                  agent-chrome eval 'const a = 1; return a + 2'
has "eval object"           '"b": 2'             agent-chrome eval '({a: 1, b: 2})'
has "text of element"       "Fixture"            agent-chrome text h1
has "get title"             "ctl:"               agent-chrome get title
has "get attr"              "email"              agent-chrome get attr "#email" type
has "get count"             "2"                  agent-chrome get count iframe
has "html"                  "<h1>Fixture</h1>"   agent-chrome html h1
has "read"                  "# Fixture"          agent-chrome read
has "read --filter"         "## Shadow DOM"      agent-chrome read --filter shadow
has "read --outline"        "## Frames"          agent-chrome read --outline
hasnt "read --outline"      "Go to page two"     agent-chrome read --outline
has "read <url>"            "You made it to page two" agent-chrome read $F/page2.html
has "read <url> drops refs" "no snapshot yet"    agent-chrome click e3
agent-chrome -q open $F/index.html >/dev/null

# --- keys, scrolling, screenshots, downloads ----------------------------------
agent-chrome -q click "#notes" >/dev/null
has "type"                  'value="typed text"' agent-chrome type typed text
has "press combo"           "pressed ctrl+a"     agent-chrome press ctrl+a
has "press Backspace"       "pressed Backspace"  agent-chrome press Backspace
has "field emptied by keys" '""'                 agent-chrome eval 'JSON.stringify(document.querySelector("#notes").value)'
has "bad key"               "unknown key"        agent-chrome press Flurb
has "scroll bottom"         "(bottom)"           agent-chrome scroll bottom
has "scroll top"            "(top)"              agent-chrome scroll top
has "shot"                  "saved $WORK/a.png"  agent-chrome shot "$WORK/a.png"
[ "$(head -c 4 "$WORK/a.png" | tail -c 3)" = PNG ] && ok || bad "shot" "not a PNG"
has "shot --el"             "saved"              agent-chrome shot "$WORK/b.png" --el "text=Save form"
has "shot --full"           "saved"              agent-chrome shot "$WORK/c.png" --full
has "download"              "downloaded $WORK/dl/data.csv" agent-chrome download "text=Download CSV" --to "$WORK/dl"
[ "$(cat "$WORK/dl/data.csv" 2>/dev/null | head -1)" = "a,b" ] && ok || bad "download" "file content"

# --- navigation, tabs, sessions ----------------------------------------------
has "link navigates"        "page: Page two"     agent-chrome click "text=Go to page two"
agent-chrome -q open $F/index.html >/dev/null      # -q: no report, so no fresh refs
has "stale ref after nav"   "page changed"       agent-chrome click e1
agent-chrome -q open $F/page2.html >/dev/null
has "list is capped"        "more lines"         agent-chrome snap
has "back"                  "page: agent-chrome fixture"  agent-chrome back
has "forward"               "page: Page two"     agent-chrome forward
has "reload"                "page: Page two"     agent-chrome reload
has "wait url"              "ok after"           agent-chrome wait url page2
has "wait timeout"          "timed out"          agent-chrome wait text "never appears" --timeout 600
agent-chrome -q open $F/index.html >/dev/null
has "new tab is followed"   "switched to it"     agent-chrome click "text=Open page two in new tab"
has "tabs shows both"       "+ "                 agent-chrome tabs
has "tab close"             "now on"             agent-chrome tab close
has "batch"                 "[3] get title"      agent-chrome run <<EOF
open $F/page2.html
click "text=Item number 3"
get title
EOF
has "batch stops on error"  "1 later command not run" agent-chrome run <<EOF
click "#nope"
get title
EOF
# a second session gets its own tab and cannot see the first one's refs
has "other session: own tab"   "page: agent-chrome fixture" env AGENT_CHROME_SESSION=other agent-chrome open $F/index.html
has "other session: isolated"  "Page two"          agent-chrome get title
has "tabs marks other session" "o "                agent-chrome tabs
has "close"                    "closed 1 tab"      env AGENT_CHROME_SESSION=other agent-chrome close
has "cdp escape hatch"         "cssContentSize"    agent-chrome cdp Page.getLayoutMetrics
has "Runtime.enable refused"   "refused"           agent-chrome cdp Runtime.enable
has "close"                    "closed"            agent-chrome close
has "browser down is explained" "agent-chrome-ctl start" env AGENT_CHROME_PORT=9 agent-chrome status

# --- not detectable ----------------------------------------------------------
agent-chrome -q open $F/index.html >/dev/null
has "has a mouse (hover: hover)"  "true"  agent-chrome eval 'matchMedia("(hover: hover)").matches && matchMedia("(pointer: fine)").matches'
has "webdriver flag is off"       "false" agent-chrome eval --main 'String(navigator.webdriver)'
if [ "$(uname -s)" = Darwin ]; then
  # macOS clamps the window to the screen, so 1920 only on a big enough display.
  has "wide viewport"               "true"  agent-chrome eval 'innerWidth >= Math.min(1920, screen.availWidth) - 16'
else
  has "1080p viewport"              "1920"  agent-chrome eval 'innerWidth'
fi

# --- python client (python/agent_chrome) -------------------------------------
pyout="$(python3 test/python_client.py 2>&1)"
printf '%s\n' "$pyout" | grep -v '^python: passed' || true
if [[ "$pyout" =~ python:\ passed\ ([0-9]+),\ failed\ ([0-9]+) ]]; then
  pass=$((pass + BASH_REMATCH[1])); fail=$((fail + BASH_REMATCH[2]))
else
  bad "python client" "$(echo "$pyout" | tail -3 | tr '\n' '~')"
fi

echo
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
