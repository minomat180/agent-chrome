"""Console-script entry points: hand straight over to the bundled scripts."""

from __future__ import annotations

import os
import shutil
import sys

from . import _paths


def _exec(argv: list) -> None:
    try:
        os.execv(argv[0], argv)
    except OSError as err:
        sys.stderr.write("agent-chrome: cannot run %s: %s\n" % (argv[0], err))
        sys.exit(127)


def agent_chrome() -> None:
    try:
        argv = [_paths.node(), str(_paths.script("agent-chrome"))]
    except FileNotFoundError as err:
        sys.stderr.write("error: %s\n" % err)
        sys.exit(127)
    _exec(argv + sys.argv[1:])


def agent_chrome_ctl() -> None:
    bash = shutil.which("bash")
    if not bash:
        sys.stderr.write("error: agent-chrome-ctl needs bash on PATH\n")
        sys.exit(127)
    try:
        argv = [bash, str(_paths.script("agent-chrome-ctl"))]
    except FileNotFoundError as err:
        sys.stderr.write("error: %s\n" % err)
        sys.exit(127)
    _exec(argv + sys.argv[1:])
