# Security policy

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/minomat180/agent-chrome/security/advisories/new),
not in a public issue.

What is at stake: agent-chrome drives a browser that is signed in to real
accounts, and anything that can reach its DevTools port can act as those
accounts. The design limits that exposure as follows:

- Chrome listens on `127.0.0.1` only (`--remote-debugging-address=127.0.0.1`).
  Any local process running as the same user can still use the port; there is
  no authentication on CDP.
- `agent-chrome secret` reads the value from stdin and masks that field in all
  later output, so the agent never sees the password it types.
- `agent-chrome-ctl update` installs Chrome only after verifying Google's
  signature (apt `Release` file and hash chain on Linux, code signature and
  Gatekeeper on macOS).

Issues of particular interest: a way for page content to make agent-chrome
reveal a masked secret, to act outside the session's own tab, or to make
`agent-chrome-ctl` signal a process it did not start.
