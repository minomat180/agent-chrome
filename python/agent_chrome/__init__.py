"""agent-chrome: drive one real, signed-in Chrome from Python.

    from agent_chrome import AgentChrome

    with AgentChrome(session="my-plugin") as b:
        print(b.open("example.com"))   # page listing with refs (e1, e2 ...)
        print(b.click("text=Learn more"))  # what changed

The browser itself is started with ``agent-chrome-ctl start`` (or
``agent_chrome.ctl("start")``); this package never launches one on its own.
"""

from .client import AgentChrome, AgentChromeError, ctl
from ._paths import skill_dir

__all__ = ["AgentChrome", "AgentChromeError", "ctl", "skill_dir", "__version__"]

try:
    from importlib.metadata import PackageNotFoundError, version as _version

    try:
        __version__ = _version("agent-chrome")
    except PackageNotFoundError:
        __version__ = "0+source"
except ImportError:  # pragma: no cover
    __version__ = "0+source"
