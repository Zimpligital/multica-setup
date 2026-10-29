#!/usr/bin/env bash
# Multica member setup — macOS / Linux   (Windows: use setup.ps1)
#
#   ./setup.sh https://multica.example.com          # macOS: Desktop app runs the agent daemon
#   ./setup.sh https://multica.example.com --cli    # macOS: also install the CLI (terminal only, no 2nd daemon)
#   ./setup.sh https://multica.example.com          # Linux: CLI + CLI daemon (autostart)
#
# From GitHub:
#   bash <(curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/setup.sh) https://multica.example.com
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/setup.sh | bash -s -- https://multica.example.com
#
# Safe to re-run: anything already set up for a different server (desktop.json, CLI config/login,
# old Desktop profiles, a second CLI daemon, a root-owned CLI copy) is fixed or removed.
# No sudo is needed to run multica; the CLI lives in ~/.local/bin.
set -euo pipefail

# ---------------- args ----------------
SERVER_URL=""; WANT_CLI=0
for arg in "$@"; do
  case "$arg" in
    --cli) WANT_CLI=1 ;;
    http://*|https://*) SERVER_URL="${arg%/}" ;;
    -h|--help) echo "Usage: setup.sh https://your-multica-server [--cli]"; exit 0 ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done
[ -n "$SERVER_URL" ] || { echo "Usage: setup.sh https://your-multica-server [--cli]"; exit 1; }
SERVER_HOST="$(printf '%s' "$SERVER_URL" | sed -E 's#^https?://##; s#/.*$##')"
DESKTOP_PROFILE="desktop-${SERVER_HOST//:/-}"

# ---------------- helpers ----------------
B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
step() { printf "\n%s==> %s%s\n" "$B" "$1" "$N"; }
ok()   { printf "%s✓ %s%s\n" "$G" "$1" "$N"; }
warn() { printf "%s! %s%s\n" "$Y" "$1" "$N"; }
fail() { printf "%s✗ %s%s\n" "$R" "$1" "$N"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
TTY=/dev/tty
[ -r "$TTY" ] || fail "No terminal available — run this from Terminal."
ask()  { local a; printf "%s" "$1"; read -r a < "$TTY"; [[ "$a" =~ ^[Yy] ]]; }
pause(){ printf "%s" "$1"; read -r _ < "$TTY"; }

case "$(uname -s)" in
  Darwin) OS=mac;  MODE=app ;;
  Linux)  OS=linux; MODE=cli; WANT_CLI=1 ;;
  MINGW*|MSYS*|CYGWIN*) fail "Windows detected — run setup.ps1 in PowerShell instead." ;;
  *) fail "Unsupported OS: $(uname -s)" ;;
esac

case "$(basename "${SHELL:-}")" in
  zsh)  RC="$HOME/.zshrc" ;;
  bash) if [ "$OS" = mac ]; then RC="$HOME/.bash_profile"; else RC="$HOME/.bashrc"; fi ;;
  *)    RC="$HOME/.profile" ;;
esac
ensure_path() {
  local dir="$1"; mkdir -p "$dir"
  case ":$PATH:" in *":$dir:"*) ;; *) export PATH="$dir:$PATH" ;; esac
  touch "$RC"
  if ! grep -qs "multica-setup: $dir" "$RC"; then
    printf '\nexport PATH="%s:$PATH"  # multica-setup: %s\n' "$dir" "$dir" >> "$RC"
    ok "Added $dir to PATH in $RC"
  fi
}
json_get() { # json_get <file> <key>  (flat string values only)
  [ -f "$1" ] && sed -nE "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$1" | head -1 || true
}

latest_tag() {  # prints e.g. v0.7.1
  local t
  t="$(curl -sI https://github.com/multica-ai/multica/releases/latest | tr -d '\r' | sed -n 's#^[Ll]ocation:.*/tag/##p' | head -1)"
  [ -n "$t" ] || t="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/multica-ai/multica/releases/latest 2>/dev/null | sed -n 's#.*/tag/##p')"
  printf '%s' "$t"
}

MULTICA_DIR="$HOME/.multica"
LOCAL_BIN="$HOME/.local/bin"

echo "${B}Multica setup${N}  server=$SERVER_URL  os=$OS  mode=$MODE$([ $WANT_CLI = 1 ] && [ $MODE = app ] && echo ' +cli')"

# ---------------- preflight ----------------
step "Checking server"
curl -fsS -o /dev/null --max-time 15 "$SERVER_URL" || fail "Cannot reach $SERVER_URL"
ok "$SERVER_URL is reachable"
ensure_path "$LOCAL_BIN"

# ---------------- Claude Code ----------------
step "Claude Code"
if have claude; then
  ok "Installed: $(claude --version 2>/dev/null | head -1)"
else
  curl -fsSL https://claude.ai/install.sh | bash
  hash -r; have claude || fail "Claude Code install failed"
  ok "Installed: $(claude --version 2>/dev/null | head -1)"
fi

step "Claude login (your own subscription)"
claude_ok() { claude -p "Reply with OK only" --max-turns 1 </dev/null >/dev/null 2>&1; }
if claude_ok; then ok "Claude is logged in"; else
  warn "Claude is not logged in."
  echo "   In Claude: type /login, finish sign-in in the browser, then type /exit"
  pause "Press Enter to open Claude… "
  claude < "$TTY" || true
  claude_ok && ok "Claude is logged in" || fail "Claude still not logged in — rerun this script after /login"
fi

# ---------------- Multica CLI (Linux always, macOS with --cli) ----------------
install_cli() {
  step "Multica CLI (user install in $LOCAL_BIN, no sudo)"
  local os arch tag ver tmp
  case "$OS" in mac) os=darwin ;; *) os=linux ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) fail "Unsupported CPU: $(uname -m)" ;; esac
  tag="$(latest_tag)"
  ver="${tag#v}"; [ -n "$ver" ] || fail "Could not find the latest Multica release"
  if [ -x "$LOCAL_BIN/multica" ] && "$LOCAL_BIN/multica" version </dev/null 2>/dev/null | grep -q "$ver"; then
    ok "Multica CLI $ver already in $LOCAL_BIN"
  else
    have multica && multica daemon stop </dev/null >/dev/null 2>&1 || true
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/m.tgz" "https://github.com/multica-ai/multica/releases/download/$tag/multica-cli-$ver-$os-$arch.tar.gz" \
      || fail "Download failed for multica-cli-$ver-$os-$arch"
    tar -xzf "$tmp/m.tgz" -C "$tmp" multica
    install -m 0755 "$tmp/multica" "$LOCAL_BIN/multica"
    rm -rf "$tmp"
    ok "Installed Multica CLI $ver to $LOCAL_BIN"
  fi
  # Remove other copies (old root-owned /usr/local/bin, Homebrew) so only the user copy is used
  for other in /usr/local/bin/multica /opt/homebrew/bin/multica /home/linuxbrew/.linuxbrew/bin/multica; do
    [ -e "$other" ] || continue
    if [[ "$other" == *brew* ]] && have brew; then
      brew uninstall multica >/dev/null 2>&1 && ok "Uninstalled Homebrew copy" || warn "Could not uninstall Homebrew copy at $other"; continue
    fi
    if rm -f "$other" 2>/dev/null; then ok "Removed old $other"
    elif ask "Old copy at $other needs your password to remove. Remove it? [y/N] "; then
      sudo rm -f "$other" < "$TTY" && ok "Removed old $other"
    else warn "Kept $other ($LOCAL_BIN is first in PATH, so the new copy is used)"; fi
  done
  hash -r
  [ "$(command -v multica)" = "$LOCAL_BIN/multica" ] || warn "PATH still finds $(command -v multica) first — open a new terminal"
}

connect_cli() {  # point the default CLI profile at our server and log in
  step "Connect CLI to $SERVER_URL"
  local cfg="$MULTICA_DIR/config.json" cur
  cur="$(json_get "$cfg" server_url)"; cur="${cur%/}"
  if [ "$cur" = "$SERVER_URL" ] && [ -n "$(json_get "$cfg" token)" ] && multica auth status </dev/null >/dev/null 2>&1; then
    ok "Already connected and logged in"
  else
    if [ -n "$cur" ] && [ "$cur" != "$SERVER_URL" ]; then
      warn "CLI was set to $cur — switching to $SERVER_URL"
      multica daemon stop </dev/null >/dev/null 2>&1 || true
      multica auth logout </dev/null >/dev/null 2>&1 || true
      cp "$cfg" "$cfg.bak.$(date +%s)"
      multica config set workspace_id "" </dev/null >/dev/null 2>&1 || true
    fi
    multica config set server_url "$SERVER_URL" </dev/null >/dev/null
    multica config set app_url "$SERVER_URL" </dev/null >/dev/null
    if [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] || { [ "$OS" = linux ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; }; then
      echo "No local browser here (SSH/headless) — use a token:"
      echo "   1) Open $SERVER_URL/settings?tab=tokens on your computer and create an API token"
      echo "   2) Paste it below (input is hidden)"
      multica login --token= < "$TTY"
    else
      echo "A browser window opens — sign in with your work email."
      multica login < "$TTY"
    fi
  fi
}

# ---------------- macOS: Desktop app owns the daemon ----------------
if [ "$MODE" = app ]; then
  step "Multica Desktop config"
  osascript -e 'quit app "Multica"' >/dev/null 2>&1 || true
  mkdir -p "$MULTICA_DIR"; CFG="$MULTICA_DIR/desktop.json"
  cur="$(json_get "$CFG" apiUrl)"; cur="${cur%/}"
  if [ "$cur" != "$SERVER_URL" ] || grep -qs '"wsUrl"\|"appUrl"' "$CFG"; then
    [ -f "$CFG" ] && cp "$CFG" "$CFG.bak.$(date +%s)" && warn "desktop.json pointed to ${cur:-?} — replaced"
    printf '{\n  "schemaVersion": 1,\n  "apiUrl": "%s"\n}\n' "$SERVER_URL" > "$CFG"
  fi
  ok "desktop.json → $SERVER_URL"
  # Remove Desktop profiles left from other servers (e.g. Multica Cloud)
  for p in "$MULTICA_DIR"/profiles/desktop-*; do
    [ -d "$p" ] || continue
    [ "$(basename "$p")" = "$DESKTOP_PROFILE" ] && continue
    rm -rf "$p" && ok "Removed old Desktop profile $(basename "$p")"
  done

  step "Multica Desktop app"
  LATEST="$(latest_tag)"; LATEST="${LATEST#v}"
  APP=""; for d in /Applications "$HOME/Applications"; do [ -d "$d/Multica.app" ] && APP="$d/Multica.app"; done
  INSTALLED="$( [ -n "$APP" ] && defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
  if [ -n "$APP" ] && [ "$INSTALLED" = "$LATEST" ]; then
    ok "Multica Desktop $INSTALLED (latest)"
  else
    ARCH="$(uname -m)"; [ "$ARCH" = x86_64 ] && ARCH=x64
    DMG_URL="https://github.com/multica-ai/multica/releases/download/v$LATEST/multica-desktop-$LATEST-mac-$ARCH.dmg"
    TMP="$(mktemp -d)"; echo "Downloading Multica Desktop $LATEST…"
    if [ -n "$LATEST" ] && curl -fL --progress-bar -o "$TMP/m.dmg" "$DMG_URL"; then
      hdiutil attach -nobrowse -quiet -mountpoint "$TMP/mnt" "$TMP/m.dmg"
      DEST=/Applications; [ -w "$DEST" ] || DEST="$HOME/Applications"; mkdir -p "$DEST"
      rm -rf "$DEST/Multica.app"; cp -R "$TMP/mnt/Multica.app" "$DEST/"
      hdiutil detach -quiet "$TMP/mnt" || true; APP="$DEST/Multica.app"
      ok "Installed Multica Desktop $LATEST to $DEST"
    else
      warn "Auto-download failed — install it from https://multica.ai/download, then rerun this script"
      open "https://multica.ai/download"
    fi
    rm -rf "$TMP"
  fi

  # Only the Desktop daemon should run on a Mac: turn off any CLI daemon from earlier setups
  if have multica || [ -x "$LOCAL_BIN/multica" ]; then
    multica daemon stop </dev/null >/dev/null 2>&1 && ok "Stopped old CLI daemon" || true
    multica daemon autostart disable </dev/null >/dev/null 2>&1 && ok "Disabled CLI daemon autostart" || true
  fi

  if [ "$WANT_CLI" = 1 ]; then
    install_cli; connect_cli
    multica daemon stop </dev/null >/dev/null 2>&1 || true   # login can auto-start it; Desktop owns the daemon
    multica daemon autostart disable </dev/null >/dev/null 2>&1 || true
    ok "CLI ready for terminal commands (daemon left to the Desktop app)"
  fi

  if [ -n "$APP" ]; then open "$APP"; fi
fi

# ---------------- Linux: CLI daemon ----------------
if [ "$MODE" = cli ]; then
  if [ -f "$MULTICA_DIR/desktop.json" ] || ls -d "$MULTICA_DIR"/profiles/desktop-* >/dev/null 2>&1; then
    step "Removing Desktop app setup (Linux uses the CLI daemon)"
    pkill -x multica-desktop >/dev/null 2>&1 || pkill -f '[Mm]ultica.*[Dd]esktop' >/dev/null 2>&1 || true
    [ -f "$MULTICA_DIR/desktop.json" ] && mv "$MULTICA_DIR/desktop.json" "$MULTICA_DIR/desktop.json.bak.$(date +%s)"
    rm -rf "$MULTICA_DIR"/profiles/desktop-*
    ok "Desktop config removed"
  fi
  install_cli; connect_cli
  step "Agent daemon"
  multica daemon autostart enable </dev/null || warn "Autostart could not be registered"
  multica daemon restart </dev/null >/dev/null 2>&1 || multica daemon start </dev/null
  loginctl enable-linger "$USER" >/dev/null 2>&1 && ok "Daemon will also run when you're not logged in" || true
  multica daemon status </dev/null || true
fi

# ---------------- done ----------------
step "Done"
if [ "$MODE" = app ]; then
  echo "Open Multica Desktop and sign in with your work email — it runs the agent daemon for this Mac."
else
  echo "The Multica daemon is running and starts automatically."
fi
echo "Then in $SERVER_URL: Agents → New agent → provider Claude Code → runtime = this computer."
echo "Open a NEW terminal window so PATH changes apply."
