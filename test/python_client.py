"""Checks for the Python client, run by test/run.sh against its throwaway browser.

Prints one line per failure and a final "python: passed N, failed M".
"""

import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "python"))

from agent_chrome import AgentChrome, AgentChromeError, ctl, skill_dir  # noqa: E402

F = "http://localhost:8765"
passed = failed = 0


def check(name, cond, got=""):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        print("FAIL  python: %s\n      got: %s" % (name, str(got)[:300].replace("\n", "~")))


def has(name, needle, fn):
    try:
        out = fn()
    except Exception as err:  # noqa: BLE001
        out = "%s: %s" % (type(err).__name__, err)
    check(name, needle in str(out), out)
    return out


b = AgentChrome(session="py-test")
has("open lists the page", 'button "Save form"', lambda: b.open(F + "/index.html"))
has("title", "agent-chrome fixture", b.title)
has("url", "/index.html", b.url)
has("snap find", 'textbox "Email"', lambda: b.snap(find="email"))
has("fill reports", "filled", lambda: b.fill("#email", "py@example.com"))
has("value", "py@example.com", lambda: b.value("#email"))
has("eval via stdin", "42", lambda: b.eval("const a = 40; a + 2"))
has("eval keeps quotes", 'it\'s "ok"', lambda: b.eval("'it\\'s \"ok\"'"))
check("count", b.count("input") > 3, b.count("input"))
has("secret never echoed", "", lambda: b.secret("#pw", "hunter2-py"))
check("secret not in report", "hunter2-py" not in b.snap(), "secret leaked into snap")
has("run batch", "[2]", lambda: b.run(["get title", "get url"]))

try:
    b.run(["get title", "click #does-not-exist", "get url"])
    check("run failure raises", False, "no exception")
except AgentChromeError as err:
    check("run failure raises", "stopped" in err.output, err.output)

try:
    b.click("#does-not-exist")
    check("error raises", False, "no exception")
except AgentChromeError as err:
    check("error has message", bool(err.message) and err.returncode == 1, err)

shot = b.shot(Path(tempfile.mkdtemp()) / "py shot.png")
check("shot saves to path with a space", shot.is_file() and shot.stat().st_size > 1000, shot)

down = AgentChrome(port=9, session="py-test")
try:
    down.status()
    check("browser down raises", False, "no exception")
except AgentChromeError as err:
    check("browser down hints ctl start", "agent-chrome-ctl start" in str(err), err)

has("ctl status", "9557", lambda: ctl("status"))
check("skill dir bundled", (skill_dir() / "SKILL.md").is_file(), skill_dir())

with AgentChrome(session="py-ctx") as c:
    c.open(F + "/page2.html")
has("context manager closes its tab", "none yet", lambda: AgentChrome(session="py-ctx").status())
has("close", "closed", b.close)

print("python: passed %d, failed %d" % (passed, failed))
sys.exit(1 if failed else 0)
