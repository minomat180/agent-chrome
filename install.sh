#!/bin/sh
# agent-chrome installer for Linux (any distro) and macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/minomat180/agent-chrome/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --yes --autostart
#   ./install.sh                      from a checkout: installs that checkout
#
# What it does, in order, asking once before anything needs sudo:
#   1. system packages the browser launcher needs (cage, wlr-randr, ... on Linux)
#   2. Node 22+: the system one if new enough, else a private copy under
#      $AGENT_CHROME_HOME/node (checked against nodejs.org's SHASUMS256.txt)
#   3. the agent-chrome package with uv, else pipx, else a private venv;
#      commands agent-chrome, agent-chrome-ctl, agent-chrome-setup
#   4. a private, signature-checked Chrome (agent-chrome-ctl update) and the
#      shared libraries it needs (Linux)
#   5. optionally: start at login (systemd user service / LaunchAgent), and the
#      Claude Code skill if ~/.claude exists
#
# Options:
#   --yes            install packages without asking (sudo included); autostart
#                    still only with --autostart
#   --no-deps        never install system packages; only say what is missing
#   --autostart      start the browser at login     --no-autostart  never ask
#   --ref REF        install branch/tag REF from GitHub (default: main)
#   --from SRC       install from a local directory or archive URL instead
#   --no-start       do not start the browser at the end
#   --uninstall      remove the package, autostart and skill link; keep the
#                    profile (your sign-ins) and Chrome. --purge removes those too
#
# Environment: AGENT_CHROME_HOME (~/.local/share/agent-chrome),
# AGENT_CHROME_BIN_DIR (~/.local/bin, where commands go when no uv/pipx),
# AGENT_CHROME_PORT (9222).
#
# Written for POSIX sh: dash, busybox ash and macOS /bin/bash 3.2 run it.

set -u

REPO="minomat180/agent-chrome"
REF="main"
SRC=""
YES=0
DEPS=1
AUTOSTART=ask
START=1
MODE=install
PURGE=0
NODE_MIN=22

AC_HOME="${AGENT_CHROME_HOME:-$HOME/.local/share/agent-chrome}"
BIN_DIR="${AGENT_CHROME_BIN_DIR:-$HOME/.local/bin}"
PORT="${AGENT_CHROME_PORT:-9222}"

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --no-deps) DEPS=0 ;;
    --autostart) AUTOSTART=yes ;;
    --no-autostart) AUTOSTART=no ;;
    --ref) REF="${2:?--ref needs a value}"; shift ;;
    --from) SRC="${2:?--from needs a value}"; shift ;;
    --no-start) START=0 ;;
    --uninstall) MODE=uninstall ;;
    --purge) MODE=uninstall; PURGE=1 ;;
    -h|--help) sed -n '2,34p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

# --- output and questions ----------------------------------------------------

if [ -t 1 ]; then B="$(printf '\033[1m')"; R="$(printf '\033[0m')"; else B=""; R=""; fi
say()  { printf '%s==>%s %s\n' "$B" "$R" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%swarning:%s %s\n' "$B" "$R" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$B" "$R" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ask "question" default(y|n): stdin is the script under `curl | sh`, so read
# the answer from the terminal; with no terminal, take the default.
ask() {
  [ "$YES" = 1 ] && return 0
  if [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then
    if [ "$2" = y ]; then printf '%s [Y/n] ' "$1" >/dev/tty; else printf '%s [y/N] ' "$1" >/dev/tty; fi
    read -r reply </dev/tty || reply=""
    case "$reply" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) [ "$2" = y ] ;;
    esac
  else
    [ "$2" = y ]
  fi
}

# --- platform ----------------------------------------------------------------

OS="$(uname -s)"
ARCH="$(uname -m)"
DISTRO=""
PM=""
NIXOS=0
MUSL=0
case "$OS" in
  Linux)
    [ -e /etc/NIXOS ] && NIXOS=1
    ls /lib/ld-musl-* >/dev/null 2>&1 && MUSL=1
    if [ -r /etc/os-release ]; then DISTRO="$(. /etc/os-release; echo "${ID:-linux} ${ID_LIKE:-}")"; fi
    if [ "$NIXOS" = 1 ]; then PM=nix
    elif have apt-get; then PM=apt
    elif have dnf; then PM=dnf
    elif have yum; then PM=yum
    elif have pacman; then PM=pacman
    elif have zypper; then PM=zypper
    elif have apk; then PM=apk
    elif have xbps-install; then PM=xbps
    elif have emerge; then PM=emerge
    fi
    ;;
  Darwin) PM=none ;;
  *) die "unsupported system $OS (agent-chrome runs on Linux and macOS)" ;;
esac

SUDO=""
if [ "$(id -u)" != 0 ]; then
  if have sudo; then SUDO="sudo"
  elif have doas; then SUDO="doas"
  fi
fi

# --- uninstall -----------------------------------------------------------------

if [ "$MODE" = uninstall ]; then
  say "uninstalling agent-chrome"
  have agent-chrome-ctl && agent-chrome-ctl stop >/dev/null 2>&1
  if [ "$OS" = Darwin ]; then
    plist="$HOME/Library/LaunchAgents/io.github.minomat180.agent-chrome.plist"
    if [ -f "$plist" ]; then
      launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1
      rm -f "$plist" && info "removed $plist"
    fi
  else
    unit="$HOME/.config/systemd/user/agent-chrome.service"
    if [ -f "$unit" ]; then
      systemctl --user disable --now agent-chrome.service >/dev/null 2>&1
      rm -f "$unit" && systemctl --user daemon-reload >/dev/null 2>&1
      info "removed $unit"
    fi
  fi
  skill="$HOME/.claude/skills/agent-chrome"
  if [ -L "$skill" ]; then
    case "$(readlink "$skill")" in *agent_chrome/_dist/skill*) rm -f "$skill" && info "removed skill link $skill" ;; esac
  fi
  if have uv && uv tool list 2>/dev/null | grep -q '^agent-chrome '; then uv tool uninstall agent-chrome && info "removed the uv tool"; fi
  if have pipx && pipx list --short 2>/dev/null | grep -q '^agent-chrome '; then pipx uninstall agent-chrome && info "removed the pipx package"; fi
  if [ -d "$AC_HOME/venv" ]; then
    for c in agent-chrome agent-chrome-ctl agent-chrome-setup; do
      [ "$(readlink "$BIN_DIR/$c" 2>/dev/null)" = "$AC_HOME/venv/bin/$c" ] && rm -f "$BIN_DIR/$c"
    done
    rm -rf "$AC_HOME/venv" && info "removed $AC_HOME/venv"
  fi
  rm -rf "$AC_HOME/node"
  if [ "$PURGE" = 1 ]; then
    rm -rf "$AC_HOME" && info "removed $AC_HOME (profile, sign-ins, private Chrome)"
  else
    kept=""
    [ -d "$AC_HOME/chrome-profile" ] && kept="the profile with your sign-ins"
    [ -d "$AC_HOME/chrome" ] && kept="${kept:+$kept and }the private Chrome"
    if [ -n "$kept" ]; then info "kept $kept in $AC_HOME; --purge removes it"
    elif [ -d "$AC_HOME" ]; then rmdir "$AC_HOME" 2>/dev/null || info "left $AC_HOME (logs only); --purge removes it"
    fi
  fi
  say "done"
  exit 0
fi

say "agent-chrome installer: $OS $ARCH${DISTRO:+ ($DISTRO)}"

# --- 1. system packages --------------------------------------------------------

# Packages per package manager. Names differ between distros; the Chrome
# libraries are handled separately in step 4, from what the binary reports.
pkgs_for() {
  case "$PM" in
    apt)    echo "curl ca-certificates gnupg binutils xz-utils tar iproute2 util-linux python3 python3-venv cage wlr-randr xwayland fonts-liberation" ;;
    dnf|yum) echo "curl ca-certificates gawk gnupg2 binutils xz tar iproute util-linux python3 cage wlr-randr xorg-x11-server-Xwayland liberation-fonts" ;;
    pacman) echo "curl ca-certificates gawk gnupg binutils xz tar iproute2 util-linux python cage wlr-randr xorg-xwayland ttf-liberation" ;;
    zypper) echo "curl ca-certificates gawk gpg2 binutils xz tar iproute2 util-linux python3 cage wlr-randr xwayland liberation-fonts" ;;
    apk)    echo "bash curl ca-certificates iproute2 util-linux python3 cage wlr-randr xwayland chromium nodejs font-liberation mesa-dri-gallium" ;;
    xbps)   echo "bash curl ca-certificates gnupg binutils xz tar iproute2 util-linux python3 cage wlr-randr xorg-server-xwayland liberation-fonts-ttf" ;;
    emerge) echo "net-misc/curl app-crypt/gnupg sys-devel/binutils app-arch/xz-utils sys-apps/iproute2 sys-apps/util-linux dev-lang/python gui-wm/cage gui-apps/wlr-randr x11-base/xwayland media-fonts/liberation-fonts" ;;
  esac
}

# Command that is missing -> install the list. (Checking commands, not package
# names, keeps this independent of what each distro calls things.)
need_cmds() {
  case "$OS" in
    Darwin) echo "curl python3" ;;
    *) if [ "$NIXOS" = 1 ]; then echo "curl python3 cage wlr-randr ss setsid"
       elif [ "$PM" = apk ]; then echo "bash curl python3 cage wlr-randr ss setsid node"
       else echo "bash curl awk python3 cage wlr-randr ss setsid gpg ar tar xz sha256sum"; fi ;;
  esac
}

pm_install() {
  [ $# -gt 0 ] || return 0
  case "$PM" in
    apt)    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" ;;
    dnf)    $SUDO dnf install -y -q --setopt=install_weak_deps=False "$@" ;;
    yum)    $SUDO yum install -y -q "$@" ;;
    pacman) $SUDO pacman -S --needed --noconfirm "$@" ;;
    zypper) $SUDO zypper --non-interactive --quiet install --no-recommends "$@" ;;
    apk)    $SUDO apk add --quiet "$@" ;;
    xbps)   $SUDO xbps-install -Sy "$@" ;;
    emerge) $SUDO emerge --noreplace "$@" ;;
    *) return 1 ;;
  esac
}

# A cage built with XWayland support refuses to start without the binary.
xwayland_missing() {
  have cage && ! have Xwayland && ldd "$(command -v cage)" 2>/dev/null | grep -q 'libxcb'
}

missing=""
for c in $(need_cmds); do have "$c" || missing="$missing $c"; done
xwayland_missing && missing="$missing Xwayland"
CAN_SUDO=0
if [ -n "$missing" ]; then
  say "missing:$missing"
  if [ "$OS" = Darwin ]; then
    case "$missing" in *python3*)
      die "python3 is missing: run xcode-select --install (Command Line Tools), or brew install python, then run this again" ;;
    esac
    die "missing:$missing"
  fi
  if [ "$NIXOS" = 1 ]; then
    info "NixOS: add these to /etc/nixos/configuration.nix and rebuild:"
    info "  environment.systemPackages = with pkgs; [ google-chrome cage wlr-randr python3 curl iproute2 nodejs_22 ];"
    info "  hardware.graphics.enable = true;"
    die "install the packages above, then run this again"
  fi
  list="$(pkgs_for)"
  [ -n "$list" ] || die "no known package manager; install the commands above yourself, then run this again"
  if [ "$DEPS" = 0 ]; then
    die "install them (for example: ${SUDO:+$SUDO }$PM install $list), then run this again"
  fi
  [ "$(id -u)" = 0 ] || [ -n "$SUDO" ] || die "need root to install packages (no sudo or doas): install $list, then run this again"
  if ask "install with ${SUDO:+$SUDO }$PM: $list?" y; then
    CAN_SUDO=1
    # shellcheck disable=SC2086
    pm_install $list || die "the package install failed; fix it and run this again"
    hash -r 2>/dev/null
  else
    die "not installing packages; install them yourself, then run this again"
  fi
  still=""
  for c in $(need_cmds); do have "$c" || still="$still $c"; done
  xwayland_missing && still="$still Xwayland"
  [ -z "$still" ] || die "still missing after the install:$still (your distribution may not package them; cage and wlr-randr come from wlroots)"
fi

# --- 2. Node -------------------------------------------------------------------

node_major() { "$1" --version 2>/dev/null | sed -n 's/^v\([0-9]*\).*/\1/p'; }

NODE=""
if [ -x "$AC_HOME/node/current/bin/node" ]; then NODE="$AC_HOME/node/current/bin/node"
elif have node && [ "$(node_major node)" -ge "$NODE_MIN" ] 2>/dev/null; then NODE="$(command -v node)"
fi

if [ -z "$NODE" ]; then
  if have node; then say "the system Node is $(node --version), agent-chrome needs $NODE_MIN or newer"
  else say "no Node on PATH"; fi
  [ "$MUSL" = 0 ] || die "musl libc: install nodejs $NODE_MIN+ with your package manager, then run this again"
  case "$OS-$ARCH" in
    Linux-x86_64) nplat=linux-x64 ;;
    Linux-aarch64|Linux-arm64) nplat=linux-arm64 ;;
    Darwin-arm64) nplat=darwin-arm64 ;;
    Darwin-x86_64) nplat=darwin-x64 ;;
    *) die "no Node build for $OS $ARCH; install Node $NODE_MIN+ yourself, then run this again" ;;
  esac
  # Current LTS release from nodejs.org's index.
  nver="$(curl -fsS --max-time 30 https://nodejs.org/dist/index.json | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if r.get("lts") and int(r["version"].lstrip("v").split(".")[0]) >= int(sys.argv[1]):
        print(r["version"]); break
' "$NODE_MIN")" || nver=""
  [ -n "$nver" ] || die "could not read the Node release index from nodejs.org"
  say "installing Node $nver privately in $AC_HOME/node (does not touch the system Node)"
  tmp="$(mktemp -d)" || die "mktemp failed"
  tarball="node-$nver-$nplat.tar.xz"
  curl -fsS --max-time 60 "https://nodejs.org/dist/$nver/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt" \
    && curl -fS --progress-bar --max-time 900 "https://nodejs.org/dist/$nver/$tarball" -o "$tmp/$tarball" \
    || { rm -rf "$tmp"; die "Node download failed"; }
  want="$(awk -v f="$tarball" '$2 == f { print $1 }' "$tmp/SHASUMS256.txt")"
  if have sha256sum; then got="$(sha256sum "$tmp/$tarball" | cut -d' ' -f1)"; else got="$(shasum -a 256 "$tmp/$tarball" | cut -d' ' -f1)"; fi
  [ -n "$want" ] && [ "$want" = "$got" ] || { rm -rf "$tmp"; die "the Node download does not match nodejs.org's SHASUMS256.txt; refusing"; }
  mkdir -p "$AC_HOME/node" && tar -xJf "$tmp/$tarball" -C "$AC_HOME/node" || { rm -rf "$tmp"; die "could not unpack Node"; }
  ln -sfn "node-$nver-$nplat" "$AC_HOME/node/current"
  rm -rf "$tmp"
  NODE="$AC_HOME/node/current/bin/node"
fi

# Node's own builds link libatomic, which minimal systems do not have.
if ! "$NODE" --version >/dev/null 2>&1; then
  nlibs="$(ldd "$NODE" 2>/dev/null | sed -n 's/^[[:space:]]*\([^[:space:]]*\) => not found.*/\1/p')"
  [ -n "$nlibs" ] || die "$NODE does not run"
  say "Node needs: $(echo $nlibs)"
  if [ "$DEPS" = 1 ] && { [ "$(id -u)" = 0 ] || [ -n "$SUDO" ]; } && { [ "$CAN_SUDO" = 1 ] || ask "install them with ${SUDO:+$SUDO }$PM?" y; }; then
    CAN_SUDO=1
    case "$PM" in
      apt) pm_install libatomic1 ;;
      pacman) pm_install gcc-libs ;;
      dnf|yum|zypper) set --; for so in $nlibs; do set -- "$@" "$so()(64bit)"; done; pm_install "$@" ;;
      *) false ;;
    esac || warn "could not install them"
  fi
  "$NODE" --version >/dev/null 2>&1 || die "$NODE still does not run (missing: $(echo $nlibs))"
fi
info "node: $NODE ($("$NODE" --version))"

# --- 3. the package ------------------------------------------------------------

if [ -z "$SRC" ]; then
  here="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  if [ -f "$here/pyproject.toml" ] && [ -f "$here/bin/agent-chrome" ]; then SRC="$here"
  else SRC="https://github.com/$REPO/archive/$REF.tar.gz"
  fi
fi

python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' || die "Python 3.9 or newer is needed (python3 is $(python3 --version 2>&1))"

say "installing the agent-chrome package from $SRC"
if have uv; then
  uv tool install --force --quiet "$SRC" || die "uv tool install failed"
  CMD_DIR="$(uv tool dir --bin 2>/dev/null || echo "$BIN_DIR")"
  info "with uv (uv tool upgrade agent-chrome / uv tool uninstall agent-chrome)"
elif have pipx; then
  pipx install --force "$SRC" >/dev/null || die "pipx install failed"
  CMD_DIR="${PIPX_BIN_DIR:-$HOME/.local/bin}"
  info "with pipx"
else
  # No uv or pipx: a venv of our own, commands linked into $BIN_DIR.
  if ! python3 -m venv "$AC_HOME/venv" >/dev/null 2>&1; then
    rm -rf "$AC_HOME/venv"
    die "python3 cannot make a venv (Debian/Ubuntu: install python3-venv), or install uv or pipx, then run this again"
  fi
  "$AC_HOME/venv/bin/python" -m pip install --quiet --upgrade pip >/dev/null 2>&1
  "$AC_HOME/venv/bin/python" -m pip install --quiet --upgrade "$SRC" || die "pip install failed"
  mkdir -p "$BIN_DIR"
  for c in agent-chrome agent-chrome-ctl agent-chrome-setup; do ln -sfn "$AC_HOME/venv/bin/$c" "$BIN_DIR/$c"; done
  CMD_DIR="$BIN_DIR"
  info "in a private venv ($AC_HOME/venv), commands linked into $BIN_DIR"
fi
CTL="$CMD_DIR/agent-chrome-ctl"
SETUP="$CMD_DIR/agent-chrome-setup"
[ -x "$CTL" ] || die "the install did not produce $CTL"
export AGENT_CHROME_NODE="$NODE"

# --- 4. Chrome -----------------------------------------------------------------

# Chrome's shared libraries, from what the binary reports missing: as
# sonames for dnf/zypper (they resolve 'libnss3.so()(64bit)' themselves), as
# Google's own Depends line for apt, as a fixed list elsewhere.
chrome_libs() {
  [ "$PM" = apt ] || [ -n "$("$CTL" libs 2>/dev/null)" ] || return 0
  case "$PM" in
    apt)
      deps="$(curl -fsS --max-time 30 "https://dl.google.com/linux/chrome/deb/dists/stable/main/binary-$(dpkg --print-architecture)/Packages" \
        | awk -v RS= '/Package: google-chrome-stable\n/' | sed -n 's/^Depends: //p' | head -1)"
      [ -n "$deps" ] || return 1
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get satisfy -y -qq --no-install-recommends "$deps" ;;
    dnf|yum|zypper)
      set --
      for so in $("$CTL" libs); do set -- "$@" "$so()(64bit)"; done
      [ $# -gt 0 ] && pm_install "$@" ;;
    pacman) pm_install nss nspr gtk3 alsa-lib libxkbcommon libxcomposite libxdamage libxrandr libxfixes libcups libdrm mesa pango cairo at-spi2-core dbus expat systemd-libs vulkan-icd-loader ;;
    xbps)   pm_install nss gtk+3 alsa-lib libxkbcommon libXcomposite libXdamage libXrandr cups-libs libdrm mesa pango at-spi2-core ;;
    *) return 1 ;;
  esac
}

if [ "$OS" = Darwin ]; then
  if [ -z "${AGENT_CHROME_BIN:-}" ]; then
    say "installing a private Chrome (Google's DMG, code signature checked)"
    "$CTL" update || die "agent-chrome-ctl update failed"
  fi
elif [ "$NIXOS" = 1 ]; then
  have google-chrome-stable || have chromium || warn "NixOS: no google-chrome on PATH; add google-chrome to environment.systemPackages"
elif [ "$PM" = apk ] || [ "$MUSL" = 1 ]; then
  info "musl libc: Google's Chrome needs glibc, so the distribution's chromium is used"
else
  if [ -z "${AGENT_CHROME_BIN:-}" ]; then
    say "installing a private Chrome (Google's apt repository, signature checked)"
    "$CTL" update || die "agent-chrome-ctl update failed"
  fi
  if [ "$PM" = apt ] || [ -n "$("$CTL" libs 2>/dev/null)" ]; then
    say "Chrome's shared libraries"
    if [ "$DEPS" = 1 ] && { [ "$CAN_SUDO" = 1 ] || [ "$(id -u)" = 0 ] || { [ -n "$SUDO" ] && ask "install Chrome's libraries with ${SUDO:+$SUDO }$PM?" y; }; }; then
      chrome_libs || warn "could not install all of them"
    fi
    left="$("$CTL" libs 2>/dev/null)"
    [ -z "$left" ] || die "Chrome is still missing: $(echo $left); install the packages that provide them, then run this again"
  fi
fi

# --- 5. autostart, skill -------------------------------------------------------

if [ "$AUTOSTART" = ask ]; then
  if [ "$YES" = 0 ] && ask "start the browser automatically at login?" n; then AUTOSTART=yes; else AUTOSTART=no; fi
fi
PATH_FOR_SERVICE="$CMD_DIR:$(dirname "$NODE"):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [ "$AUTOSTART" = yes ]; then
  if [ "$OS" = Darwin ]; then
    plist="$HOME/Library/LaunchAgents/io.github.minomat180.agent-chrome.plist"
    mkdir -p "$(dirname "$plist")" "$AC_HOME"
    cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.github.minomat180.agent-chrome</string>
  <key>ProgramArguments</key><array><string>$CTL</string><string>start</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$PATH_FOR_SERVICE</string>
    <key>AGENT_CHROME_PORT</key><string>$PORT</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$AC_HOME/launchd.log</string>
  <key>StandardErrorPath</key><string>$AC_HOME/launchd.log</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1
    launchctl bootstrap "gui/$(id -u)" "$plist" && info "LaunchAgent $plist loaded" || warn "could not load $plist"
  elif [ "$NIXOS" = 1 ]; then
    info "NixOS: declare the user service in configuration.nix (README, NixOS section)"
  elif have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
    unit="$HOME/.config/systemd/user/agent-chrome.service"
    mkdir -p "$(dirname "$unit")"
    cat >"$unit" <<EOF
[Unit]
Description=agent-chrome: the agent's own Chrome on 127.0.0.1:$PORT

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=PATH=$PATH_FOR_SERVICE
Environment=AGENT_CHROME_PORT=$PORT
ExecStart=$CTL start
ExecStop=$CTL stop

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload && systemctl --user enable agent-chrome.service >/dev/null 2>&1 \
      && info "systemd user service enabled: $unit" || warn "could not enable $unit"
    info "on a server, loginctl enable-linger $(id -un) starts it at boot instead of at login"
  else
    warn "no systemd user session here; start it from your own init system with: $CTL start"
  fi
fi

if [ -d "$HOME/.claude" ]; then
  if [ -e "$HOME/.claude/skills/agent-chrome" ]; then info "Claude Code skill already present, left alone"
  else "$SETUP" install-skill >/dev/null && info "linked the Claude Code skill into ~/.claude/skills/agent-chrome"
  fi
fi

# --- done ----------------------------------------------------------------------

if [ "$START" = 1 ]; then
  say "starting the browser"
  if [ "$AUTOSTART" = yes ] && [ -f "$HOME/.config/systemd/user/agent-chrome.service" ]; then
    systemctl --user start agent-chrome.service || warn "the service did not start; see: systemctl --user status agent-chrome"
  else
    "$CTL" start || warn "it did not start; see $AC_HOME/chrome.log"
  fi
fi
say "checking"
if [ "$START" = 1 ]; then "$SETUP" doctor || warn "doctor found problems (above)"
else "$SETUP" doctor --no-browser || warn "doctor found problems (above)"; fi

case ":$PATH:" in
  *":$CMD_DIR:"*) ;;
  *) warn "$CMD_DIR is not on your PATH; add it, e.g. echo 'export PATH=\"$CMD_DIR:\$PATH\"' >> ~/.profile" ;;
esac
say "done. Try: agent-chrome open example.com"
