# Contributing

agent-chrome is a personal tool for my own Claude Code setup on two machines
(NixOS and macOS). Issues and pull requests are welcome, but I may not get to
them, and I will turn down changes that add dependencies or a daemon.

If you change behaviour, run `test/run.sh` first (it uses its own browser on
port 9557 and never touches 9222) and say in the PR which platform you ran it on.

If you fork it: `skill/SKILL.md` refers to my setup (a `vault` skill, my rules
for the browser) and is the part you will want to rewrite.
