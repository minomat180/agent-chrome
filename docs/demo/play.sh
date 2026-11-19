#!/usr/bin/env bash
# Plays the README demo: types each command like a person would, then runs it
# for real against a throwaway browser (docs/demo/setup.sh). Recorded with
#   asciinema rec --headless --window-size 96x40 -c 'bash docs/demo/play.sh' demo.cast
#   agg --font-size 18 --theme monokai --idle-time-limit 4 demo.cast docs/demo/demo.gif
# Needs jq and network access to httpbin.org.
cd "$(dirname "$0")/../.." || exit 1
source docs/demo/setup.sh
clear

n=0
say() {  # type a command at a human pace, run it, pause
  ((n++)) && printf '\n'
  printf '\033[1;32m$\033[0m '
  local i; for ((i = 0; i < ${#1}; i++)); do printf '%s' "${1:i:1}"; sleep 0.03; done
  sleep 0.4; printf '\n'
  eval "$1"
  sleep "${2:-1.6}"
}

say 'agent-chrome open httpbin.org/forms/post' 3
say 'agent-chrome fill e1 Ada Lovelace'
say 'agent-chrome click "text=Large"'
say 'agent-chrome check e10'
say 'agent-chrome fill e11 19:30'
say 'agent-chrome click "text=Submit order"' 2.5
say 'agent-chrome text | jq -c .form' 4
agent-chrome close >/dev/null
