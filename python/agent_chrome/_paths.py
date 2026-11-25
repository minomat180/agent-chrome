"""Where the bundled Node CLI, shell launcher and skill live."""

from __future__ import annotations

import os
import shutil
import stat
from pathlib import Path

_PKG = Path(__file__).resolve().parent


def root() -> Path:
    """Directory holding bin/, lib/, libexec/ and skill/.

    Inside an installed wheel that is ``agent_chrome/_dist``; from a source
    checkout (``pip install -e .`` or ``PYTHONPATH=python``) it is the repo.
    """
    dist = _PKG / "_dist"
    if (dist / "bin" / "agent-chrome").is_file():
        return dist
    repo = _PKG.parent.parent
    if (repo / "bin" / "agent-chrome").is_file():
        return repo
    raise FileNotFoundError(
        "agent-chrome: bundled scripts not found (expected %s or %s)" % (dist, repo)
    )


def script(name: str) -> Path:
    path = root() / "bin" / name
    _ensure_executable(path)
    return path


def skill_dir() -> Path:
    return root() / "skill"


def node() -> str:
    """The node binary: AGENT_CHROME_NODE, else the first one on PATH."""
    found = os.environ.get("AGENT_CHROME_NODE") or shutil.which("node")
    if not found:
        raise FileNotFoundError(
            "agent-chrome needs Node 22 or newer on PATH (or AGENT_CHROME_NODE set to a node binary)"
        )
    return found


def _ensure_executable(path: Path) -> None:
    # Wheels keep the mode bits, but not every installer restores them. The
    # Linux launcher execs agent-chrome-ctl-macos on macOS, so it needs +x.
    try:
        mode = path.stat().st_mode
        if not mode & stat.S_IXUSR:
            path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        for sibling in path.parent.iterdir():
            m = sibling.stat().st_mode
            if not m & stat.S_IXUSR:
                sibling.chmod(m | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    except OSError:
        pass  # read-only site-packages: we run through node/bash explicitly anyway
