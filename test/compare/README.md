# Reproducing the driver comparison (README, "Why replace what was there")

All drivers were attached to the same throwaway Chrome, started exactly like
the agent browser (headful, inside a headless cage, own profile, port 9555).

1. Open https://bot-detector.rebrowser.net/ with the driver under test.
2. Take a snapshot and click something, so the driver does its normal work.
3. Evaluate `js_trigger.js` with the driver's own eval (this is what exposes
   how the driver injects code), wait a second, evaluate `js_read.js`.
4. Count the red and yellow lines.

`rawcdp.py PORT URL JS [wait]` is the control: bare CDP with no Runtime.enable.

Versions measured on 2026-11-12: @playwright/cli 0.1.24 (`attach --cdp=`),
chrome-devtools-mcp 1.13.0 CLI (`start --browserUrl`), agent-browser 0.42.0
(`--cdp`), browser-harness 0.1.13 (`BU_CDP_URL`, `BH_TELEMETRY=0`).
