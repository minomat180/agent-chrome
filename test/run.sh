#!/bin/bash
# End-to-end tests: a throwaway Chrome (own profile, own port, headless cage)
# driven through the real CLI against test/fixture.
#
#   test/run.sh            run everything
#   KEEP=1 test/run.sh     leave the browser up afterwards (port 9557)
#
# Never touches the real agent browser on 9222.

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
WORK="$(mktemp -d /tmp/pib-test.XXXXXX)"
export PIB_PORT=9557 PIB_HOME="$WORK/home" PIB_PROFILE="$WORK/profile" PIB_STATE_DIR="$WORK/state" PIB_SESSION=test
PATH="$ROOT/bin:$PATH"
F=http://localhost:8765

pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); printf 'FAIL  %s\n      %s\n' "$1" "$2"; }
# has <name> <needle> <command...>   output must contain needle
has()  { local name="$1" needle="$2"; shift 2; local out; out="$("$@" 2>&1)"; if [[ "$out" == *"$needle"* ]]; then ok; else bad "$name" "wanted: $needle | got: $(echo "$out" | head -c 300 | tr '\n' '~')"; fi; }
# hasnt <name> <needle> <command...> output must NOT contain needle
hasnt(){ local name="$1" needle="$2"; shift 2; local out; out="$("$@" 2>&1)"; if [[ "$out" != *"$needle"* ]]; then ok; else bad "$name" "must not contain: $needle"; fi; }
ref()  { pib snap --find "$1" | sed -n 's/^ *\(e[0-9]*\) .*/\1/p' | head -1; }

cleanup() {
  [ -n "${KEEP:-}" ] || pib-chrome stop >/dev/null 2>&1
  test/serve-fixture.sh stop
  [ -n "${KEEP:-}" ] || rm -rf "$WORK"
}
trap cleanup EXIT

test/serve-fixture.sh >/dev/null
pib-chrome start >/dev/null || { echo "could not start the test browser"; exit 1; }

# --- lifecycle ---------------------------------------------------------------
has  "status: no tab"            "none yet"                  pib status
has  "snap without tab explains" "pib open"                  pib snap
has  "open lists the page"       'button "Save form"'        pib open $F/index.html
has  "bare host gets a scheme"   "pib fixture"               pib open localhost:8765/index.html

# --- snapshot ----------------------------------------------------------------
S="$(pib snap)"
for want in 'textbox "Email" type=email required' 'type=password' 'select "Country"' 'options=--|Switzerland|Germany|France' \
            'checkbox "I agree"' 'clickable "Clickable card (div)"' 'button "Shadow open button"' 'button "Shadow closed button"' \
            '[iframe "same-origin frame"]' '[iframe "cross-site frame" cross-site]' 'type=file' '## Form'; do
  if [[ "$S" == *"$want"* ]]; then ok; else bad "snap contains" "$want"; fi
done
[ "$(echo "$S" | grep -c 'Frame button')" = 2 ] && ok || bad "snap" "both iframes' buttons listed"
hasnt "hidden things are not listed" "Hidden menu item"       pib snap
has   "snap --find narrows"       'button "Confirm"'          pib snap --find confirm
has   "snap -a adds text"         'text "'                    pib snap -a

# --- forms -------------------------------------------------------------------
has "fill"                 "filled"                      pib fill "#email" mino@example.com
has "fill reports rewrite" 'changed it to "HELLO"'       pib fill "#ctl" hello
has "fill textarea"        'value="two words"'           pib fill "#notes" two words
has "fill date"            'value="2026-12-24"'          pib fill "#date" 2026-12-24
has "fill contenteditable" "rich text"                   pib fill "#editor" rich text
has "fill empties"         "filled"                      pib fill "#notes" ""
has "fill empties (check)" '""'                          pib eval 'JSON.stringify(document.querySelector("#notes").value)'
has "select by label"      'selected "Germany"'          pib select "#country" Germany
has "select bad option"    "options:"                    pib select "#country" Narnia
has "check"                "checked"                     pib check "#agree"
has "check is idempotent"  "already checked"             pib check "#agree"
has "uncheck"              "unchecked"                   pib uncheck "#agree"
has "fill on checkbox"     "pib check"                   pib fill "#agree" x
has "styled checkbox (invisible input under its label)" "checked" pib check "#cc"
has "styled checkbox took" "true"                        pib eval 'document.querySelector("#cc").checked'
has "upload"               "attached 1 file"             pib upload "#file" "$ROOT/test/fixture/data.csv"
has "upload missing file"  "no such file"                pib upload "#file" /nonexistent/file
has "submit"               'submitted:{"email":"mino@example.com"' pib click "text=Save form"

# --- secrets -----------------------------------------------------------------
PW="$(ref Password)"
OUT="$(printf 'hunter2-S3cret' | pib secret "$PW" 2>&1)"
[[ "$OUT" == *"secret typed"* ]] && ok || bad "secret" "$OUT"
[[ "$OUT" != *"hunter2"* ]] && ok || bad "secret" "value leaked into output"
has   "secret reached the field" "14"                    pib eval 'document.querySelector("#pw").value.length'
hasnt "get value masks it"       "hunter2"               pib get value "$PW"
hasnt "snap masks it"            "hunter2"               pib snap
hasnt "text masks it"            "hunter2"               pib text "#pw"

# --- clicking ----------------------------------------------------------------
has "trusted events"        "trusted=true"       pib click "text=Trusted check"
has "clickable div"         "card-clicked"       pib click "text=Clickable card"
has "open shadow DOM"       "shadow-open"        pib click "text=Shadow open button"
has "closed shadow DOM"     "shadow-closed"      pib click "text=Shadow closed button"
has "offscreen is scrolled" "bottom-clicked"     pib click "text=Bottom button"
has "unknown ref"           "unknown ref"        pib click e9999
has "bad selector"          "invalid selector"   pib click "###"
has "no match"              "no element matches" pib click "#nope"
has "ambiguous text"        "elements match"     pib click "text=Frame button"
has "coordinates"           "clicked 5,5"        pib click 5,5

# same-process and cross-site iframes
FB="$(pib snap --find 'Frame button' | sed -n 's/^ *\(e[0-9]*\) .*/\1/p')"
has "iframe click (same origin)"  "msg:frame-button" pib click "$(echo "$FB" | sed -n 1p)"
has "iframe click (cross-site)"   "clicked"          pib click "$(echo "$FB" | sed -n 2p)"
FI="$(pib snap --find 'Frame input' | sed -n 's/^ *\(e[0-9]*\) .*/\1/p')"
has "iframe fill (same origin)"   'value="in frame"'   pib fill "$(echo "$FI" | sed -n 1p)" in frame
has "iframe fill (cross-site)"    'value="cross site"' pib fill "$(echo "$FI" | sed -n 2p)" cross site

# appearing content, covers, hover
pib -q click "text=Reveal later" >/dev/null
has "wait text"              "Late button"     pib wait text "Late button"
has "late element clickable" "late-clicked"    pib click "text=Late button"
pib -q click "text=Show overlay briefly" >/dev/null
has "waits out a brief cover" "covered-clicked" pib click "text=Covered button"
pib -q click "text=Show overlay forever" >/dev/null
has "reports a lasting cover" "covered by <div#overlay>" pib click "text=Covered button"
has "--force clicks anyway"   "clicked"                  pib click "text=Covered button" --force
pib eval 'document.getElementById("overlay").style.display="none"; 1' >/dev/null
has "hover reveals"           'button "Hidden menu item"' pib hover ".hovermenu"

# --- dialogs -----------------------------------------------------------------
has "alert accepted"        '(accepted)'        pib click "text=Alert"
has "alert did not block"   "alert-done"        pib eval 'document.getElementById("log").textContent'
has "confirm dismissed"     "DISMISSED"         pib click "text=Confirm"
has "confirm=false"         "confirm=false"     pib eval 'document.getElementById("log").textContent'
has "confirm --accept"      "-> accepted"       pib click "text=Confirm" --accept
has "confirm=true"          "confirm=true"      pib eval 'document.getElementById("log").textContent'

# --- reading -----------------------------------------------------------------
has "eval isolated"         "undefined"          pib eval 'typeof window.pageGlobal'
has "eval --main"           "42"                 pib eval --main 'window.pageGlobal.answer'
has "eval hint"             "--main"             pib eval 'pageGlobal.answer'
has "eval statements"       "3"                  pib eval 'const a = 1; return a + 2'
has "eval object"           '"b": 2'             pib eval '({a: 1, b: 2})'
has "text of element"       "Fixture"            pib text h1
has "get title"             "ctl:"               pib get title
has "get attr"              "email"              pib get attr "#email" type
has "get count"             "2"                  pib get count iframe
has "html"                  "<h1>Fixture</h1>"   pib html h1
has "read"                  "# Fixture"          pib read
has "read --filter"         "## Shadow DOM"      pib read --filter shadow
has "read --outline"        "## Frames"          pib read --outline
hasnt "read --outline"      "Go to page two"     pib read --outline
has "read <url>"            "You made it to page two" pib read $F/page2.html
has "read <url> drops refs" "no snapshot yet"    pib click e3
pib -q open $F/index.html >/dev/null

# --- keys, scrolling, screenshots, downloads ----------------------------------
pib -q click "#notes" >/dev/null
has "type"                  'value="typed text"' pib type typed text
has "press combo"           "pressed ctrl+a"     pib press ctrl+a
has "press Backspace"       "pressed Backspace"  pib press Backspace
has "field emptied by keys" '""'                 pib eval 'JSON.stringify(document.querySelector("#notes").value)'
has "bad key"               "unknown key"        pib press Flurb
has "scroll bottom"         "(bottom)"           pib scroll bottom
has "scroll top"            "(top)"              pib scroll top
has "shot"                  "saved $WORK/a.png"  pib shot "$WORK/a.png"
[ "$(head -c 4 "$WORK/a.png" | tail -c 3)" = PNG ] && ok || bad "shot" "not a PNG"
has "shot --el"             "saved"              pib shot "$WORK/b.png" --el "text=Save form"
has "shot --full"           "saved"              pib shot "$WORK/c.png" --full
has "download"              "downloaded $WORK/dl/data.csv" pib download "text=Download CSV" --to "$WORK/dl"
[ "$(cat "$WORK/dl/data.csv" 2>/dev/null | head -1)" = "a,b" ] && ok || bad "download" "file content"

# --- navigation, tabs, sessions ----------------------------------------------
has "link navigates"        "page: Page two"     pib click "text=Go to page two"
pib -q open $F/index.html >/dev/null      # -q: no report, so no fresh refs
has "stale ref after nav"   "page changed"       pib click e1
pib -q open $F/page2.html >/dev/null
has "list is capped"        "more lines"         pib snap
has "back"                  "page: pib fixture"  pib back
has "forward"               "page: Page two"     pib forward
has "reload"                "page: Page two"     pib reload
has "wait url"              "ok after"           pib wait url page2
has "wait timeout"          "timed out"          pib wait text "never appears" --timeout 600
pib -q open $F/index.html >/dev/null
has "new tab is followed"   "switched to it"     pib click "text=Open page two in new tab"
has "tabs shows both"       "+ "                 pib tabs
has "tab close"             "now on"             pib tab close
has "batch"                 "[3] get title"      pib run <<EOF
open $F/page2.html
click "text=Item number 3"
get title
EOF
has "batch stops on error"  "1 later command not run" pib run <<EOF
click "#nope"
get title
EOF
# a second session gets its own tab and cannot see the first one's refs
has "other session: own tab"   "page: pib fixture" env PIB_SESSION=other pib open $F/index.html
has "other session: isolated"  "Page two"          pib get title
has "tabs marks other session" "o "                pib tabs
has "close"                    "closed 1 tab"      env PIB_SESSION=other pib close
has "cdp escape hatch"         "cssContentSize"    pib cdp Page.getLayoutMetrics
has "Runtime.enable refused"   "refused"           pib cdp Runtime.enable
has "close"                    "closed"            pib close
has "browser down is explained" "pib-chrome start" env PIB_PORT=9 pib status

# --- not detectable ----------------------------------------------------------
pib -q open $F/index.html >/dev/null
has "has a mouse (hover: hover)"  "true"  pib eval 'matchMedia("(hover: hover)").matches && matchMedia("(pointer: fine)").matches'
has "webdriver flag is off"       "false" pib eval --main 'String(navigator.webdriver)'
if [ "$(uname -s)" = Darwin ]; then
  # macOS clamps the window to the screen, so 1920 only on a big enough display.
  has "wide viewport"               "true"  pib eval 'innerWidth >= Math.min(1920, screen.availWidth) - 16'
else
  has "1080p viewport"              "1920"  pib eval 'innerWidth'
fi

echo
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
