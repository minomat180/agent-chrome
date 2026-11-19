# Security policy

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/minomat180/agent-chrome/security/advisories/new),
not in a public issue.

What is at stake: agent-chrome drives a browser that is signed in to real
accounts, and anything that can reach its DevTools port can act as those
accounts. The design limits that exposure:

- Chrome listens on `127.0.0.1` only (`--remote-debugging-address=127.0.0.1`).
  CDP has no authentication: any process on the same machine, under any user
  account, can connect to the port and act as the signed-in accounts. Run it
  only on a machine you alone use.
- `agent-chrome secret` reads the value from stdin, so it never appears in the
  command line or the agent's transcript, and masks that field in later
  snapshots, change reports and `get value`. It is not a sandbox: `eval` and
  `cdp` can still read any field, and `text <target>` shows the value of a
  field that is not `type=password`.
- `agent-chrome-ctl update` installs Chrome only after verifying Google's
  signature (apt `Release` file and hash chain on Linux, code signature and
  Gatekeeper on macOS).

Issues of particular interest: a way for page content to make agent-chrome
reveal a masked secret, to act outside the session's own tab, or to make
`agent-chrome-ctl` signal a process it did not start.
