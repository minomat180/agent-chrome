# Sourced by play.sh: a throwaway browser for the recording.
# Own profile under $TMPDIR, port 9558; never the real agent browser on 9222.
export AGENT_CHROME_PORT=9558 AGENT_CHROME_SESSION=demo
export AGENT_CHROME_HOME="${TMPDIR:-/tmp}/agent-chrome-demo"
export AGENT_CHROME_PROFILE="$AGENT_CHROME_HOME/profile" AGENT_CHROME_STATE_DIR="$AGENT_CHROME_HOME/state"
export PATH="$PWD/bin:$PATH"
agent-chrome-ctl start >/dev/null
agent-chrome close >/dev/null 2>&1
