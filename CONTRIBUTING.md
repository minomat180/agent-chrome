# Contributing

agent-chrome is a personal tool for my own Claude Code setup on two machines
(NixOS and macOS). Issues and pull requests are welcome, but I may not get to
them, and I will turn down changes that add dependencies or a daemon.

If you change behaviour, run `test/run.sh` first (it uses its own browser on
port 9557 and never touches 9222) and say in the PR which platform you ran it on.

The Python package (`pyproject.toml`, `python/agent_chrome/`) only wraps the
CLI: new commands go into `bin/agent-chrome` first, then get a method in
`python/agent_chrome/client.py` and a check in `test/python_client.py`.
`uv build` makes the wheel; it bundles `bin/`, `lib/`, `libexec/` and `skill/`.

If you fork it: `skill/SKILL.md` refers to my setup (a `vault` skill, my rules
for the browser) and is the part you will want to rewrite.
