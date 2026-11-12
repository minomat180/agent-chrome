#!/bin/bash
# Serve test/fixture on 127.0.0.1:8765 (loopback only). `stop` to stop it.
# Lives in a file so the pkill pattern can never match the calling shell.
cd "$(dirname "$0")/fixture" || exit 1
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/pib-fixture.pid"
if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; fi
[ "${1:-}" = stop ] && exit 0
setsid nohup python3 -m http.server 8765 --bind 127.0.0.1 >/tmp/pib-fixture.log 2>&1 &
echo $! >"$PIDFILE"
sleep 0.7
curl -s -o /dev/null -w "fixture: %{http_code} on http://localhost:8765/\n" http://localhost:8765/index.html
