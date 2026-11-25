"""``agent-chrome-setup`` (or ``python -m agent_chrome``): setup helpers.

    agent-chrome-setup doctor          check node, bash, the Linux compositor and the browser
    agent-chrome-setup install-skill   link the agent manual into ~/.claude/skills
    agent-chrome-setup paths           where the bundled files are
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from . import __version__, _paths


def _doctor(args: argparse.Namespace) -> int:
    ok = True

    def line(good: bool, what: str, detail: str) -> None:
        nonlocal ok
        ok = ok and good
        print("%-4s %-9s %s" % ("ok" if good else "FAIL", what, detail))

    print("agent-chrome %s, files in %s" % (__version__, _paths.root()))
    try:
        node = _paths.node()
        out = subprocess.run([node, "--version"], capture_output=True, text=True).stdout.strip()
        major = int(out.lstrip("v").split(".")[0]) if out.startswith("v") else 0
        line(major >= 22, "node", "%s (%s)%s" % (out or "?", node, "" if major >= 22 else ": need 22 or newer"))
    except (FileNotFoundError, ValueError) as err:
        line(False, "node", str(err))
    bash = shutil.which("bash")
    line(bool(bash), "bash", bash or "not on PATH")
    for tool in ("python3", "curl"):
        found = shutil.which(tool)
        line(bool(found), tool, found or "not on PATH (agent-chrome-ctl uses it)")
    if sys.platform.startswith("linux"):
        for tool in ("cage", "wlr-randr", "ss", "setsid"):
            found = shutil.which(tool)
            line(bool(found), tool, found or "not on PATH (agent-chrome-ctl start needs it on Linux)")
        musl = any(name.startswith("ld-musl-") for name in os.listdir("/lib")) if os.path.isdir("/lib") else False
        if not os.path.exists("/etc/NIXOS") and not musl:
            for tool in ("gpg", "ar", "tar", "sha256sum"):
                found = shutil.which(tool)
                line(bool(found), tool, found or "not on PATH (agent-chrome-ctl update needs it)")
        if bash:
            libs = subprocess.run(
                [bash, str(_paths.script("agent-chrome-ctl")), "libs"], capture_output=True, text=True
            ).stdout.split()
            line(not libs, "libs", "missing: " + " ".join(libs) if libs else "the browser finds all its shared libraries")
    if args.no_browser:
        return 0 if ok else 1
    try:
        from .client import AgentChrome, AgentChromeError

        try:
            first = AgentChrome(timeout=15).status().splitlines()
            line(True, "browser", first[0] if first else "reachable")
        except AgentChromeError as err:
            line(False, "browser", err.message + (" (" + err.hint + ")" if err.hint else ""))
    except FileNotFoundError as err:
        line(False, "browser", str(err))
    return 0 if ok else 1


def _install_skill(args: argparse.Namespace) -> int:
    dest = Path(args.dir).expanduser() / "agent-chrome"
    src = _paths.skill_dir()
    if dest.is_symlink() or dest.exists():
        if dest.is_symlink() and Path(os.readlink(dest)) == src:
            print("already linked: %s -> %s" % (dest, src))
            return 0
        if not args.force:
            print("%s exists; pass --force to replace it" % dest, file=sys.stderr)
            return 1
        if dest.is_symlink() or dest.is_file():
            dest.unlink()
        else:
            shutil.rmtree(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    if args.copy:
        shutil.copytree(src, dest)
        print("copied %s -> %s" % (src, dest))
    else:
        dest.symlink_to(src, target_is_directory=True)
        print("linked %s -> %s" % (dest, src))
    return 0


def _paths_cmd(_: argparse.Namespace) -> int:
    root = _paths.root()
    print("root     %s" % root)
    print("cli      %s" % (root / "bin" / "agent-chrome"))
    print("ctl      %s" % (root / "bin" / "agent-chrome-ctl"))
    print("skill    %s" % _paths.skill_dir())
    return 0


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(prog="agent-chrome-setup", description="Setup helpers for agent-chrome.")
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("doctor", help="check node, bash, the Linux compositor and the browser")
    p.add_argument("--no-browser", action="store_true", help="skip the check for a running browser")
    p.set_defaults(fn=_doctor)
    p = sub.add_parser("install-skill", help="link the agent manual into a skills directory")
    p.add_argument("--dir", default="~/.claude/skills", help="skills directory (default: ~/.claude/skills)")
    p.add_argument("--copy", action="store_true", help="copy instead of symlinking")
    p.add_argument("--force", action="store_true", help="replace an existing agent-chrome skill")
    p.set_defaults(fn=_install_skill)
    sub.add_parser("paths", help="print where the bundled files are").set_defaults(fn=_paths_cmd)
    args = parser.parse_args(argv)
    return args.fn(args)


def cli() -> None:
    sys.exit(main())


if __name__ == "__main__":
    cli()
