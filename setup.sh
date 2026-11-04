#!/usr/bin/env bash
# Multica member setup — macOS / Linux   (Windows: use setup.ps1)
#
#   ./setup.sh https://multica.example.com                         # Claude Code, Multica, git
#   ./setup.sh https://multica.example.com --check                 # only check and report, change nothing
#   ./setup.sh https://multica.example.com --repo=https://git.example.com/team/app.git --git-token
#                                                                  # + download a repo and install what it needs
#   ./setup.sh https://multica.example.com --cli                   # macOS: also install the CLI (terminal only, no 2nd daemon)
#   ./setup.sh https://multica.example.com --docker                # + Docker for local containers (databases etc.)
#
# Options:
#   --repo=<git url>          Repo to download: https://… or SSH (git@host:org/repo.git). Its own files decide
#                             what else is installed:
#                             package.json "packageManager" / "engines" (bun, pnpm, yarn, npm) or its lockfile.
#   --git-token[=<token>]     Access token for --repo (for people without an account on the main git host).
#                             Without a value it is asked hidden, which keeps it out of shell history.
#                             Also read from $SETUP_GIT_TOKEN. Not needed if git can already reach the repo.
#                             github.com over https without a token: signs in with GitHub CLI in the browser
#                             (works with org SSO); the CLI is installed to ~/.local/bin if missing.
#   --git-user=<name>         Username sent with the token (default: token; some servers need your user name)
#   --branch=<name>           Branch to download (default: the repo's default branch)
#   --dir=<path>              Where to put the repo (default: ~/Projects/<repo name>)
#   --min-ram=<GB>            Warn below this much memory (default: 8)
#   --min-disk=<GB>           Stop below this much free disk (default: 5)
#   --docker[=<runtime>]      Make sure Docker (with compose) is installed and running. Runtimes on macOS:
#                             desktop (Docker Desktop, default), orbstack, colima (needs Homebrew). An engine that
#                             is already installed is used as is. Without this flag Docker is only set up when the
#                             downloaded repo has a compose file (asked first), and --no-docker skips it.
#   --check                   Report what is missing or outdated; install nothing
#
# From a URL:
#   bash <(curl -fsSL https://example.com/setup.sh) https://multica.example.com [options]
#   curl -fsSL https://example.com/setup.sh | bash -s -- https://multica.example.com [options]
#
# Safe to re-run: anything already set up for a different server (desktop.json, CLI config/login,
# old Desktop profiles, a second CLI daemon, a root-owned CLI copy) is fixed or removed, and a
# downloaded repo keeps local edits. No sudo is needed for multica (~/.local/bin) or Bun (~/.bun).
set -euo pipefail

# ---------------- args ----------------
SERVER_URL=""; WANT_CLI=0; CHECK=0; WANT_DOCKER=auto; DOCKER_RUNTIME=desktop
REPO_URL=""; REPO_NAME=""; REPO_SSH=0; NEEDS_GH=0; BRANCH=""; REPO_DIR=""; GIT_USER=token; ASK_TOKEN=0; GIT_TOKEN="${SETUP_GIT_TOKEN:-}"
RAM_MIN_GB=8; DISK_MIN_GB=5
usage() { echo "Usage: setup.sh https://your-multica-server [--repo=URL [--git-token[=TOKEN]] [--git-user=NAME] [--branch=NAME] [--dir=PATH]] [--min-ram=GB] [--min-disk=GB] [--docker[=desktop|orbstack|colima]|--no-docker] [--check] [--cli]"; }
for arg in "$@"; do
  case "$arg" in
    --cli) WANT_CLI=1 ;;
    --check) CHECK=1 ;;
    --docker) WANT_DOCKER=yes ;;
    --docker=desktop|--docker=orbstack|--docker=colima) WANT_DOCKER=yes; DOCKER_RUNTIME="${arg#*=}" ;;
    --docker=*) echo "Unknown Docker runtime: ${arg#*=} (use desktop, orbstack or colima)"; exit 1 ;;
    --no-docker) WANT_DOCKER=no ;;
    --repo=*) REPO_URL="${arg#*=}" ;;
    --git-token) ASK_TOKEN=1 ;;
    --git-token=*) GIT_TOKEN="${arg#*=}" ;;
    --git-user=*) GIT_USER="${arg#*=}" ;;
    --branch=*) BRANCH="${arg#*=}" ;;
    --dir=*) REPO_DIR="${arg#*=}" ;;
    --min-ram=*) RAM_MIN_GB="${arg#*=}" ;;
    --min-disk=*) DISK_MIN_GB="${arg#*=}" ;;
    http://*|https://*) SERVER_URL="${arg%/}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $arg"; usage; exit 1 ;;
  esac
done
[ -n "$SERVER_URL" ] || { usage; exit 1; }
SERVER_HOST="$(printf '%s' "$SERVER_URL" | sed -E 's#^https?://##; s#/.*$##')"
DESKTOP_PROFILE="desktop-${SERVER_HOST//:/-}"
if [ -n "$REPO_URL" ]; then
  case "$REPO_URL" in
    https://*) REPO_SSH=0 ;;
    ssh://*|*@*:*) REPO_SSH=1 ;;
    *) echo "--repo must be an https:// or SSH (git@host:org/repo.git) URL"; exit 1 ;;
  esac
  REPO_URL="${REPO_URL%/}"
  if [ "$REPO_SSH" = 1 ] && { [ "$ASK_TOKEN" = 1 ] || [ -n "$GIT_TOKEN" ]; }; then
    echo "--git-token only works with an https:// --repo (SSH uses your SSH key)"; exit 1
  fi
  REPO_NAME="$(basename "$REPO_URL" .git)"
  [ -n "$REPO_DIR" ] || REPO_DIR="$HOME/Projects/$REPO_NAME"
  case "$REPO_DIR" in "~"/*) REPO_DIR="$HOME/${REPO_DIR#\~/}" ;; esac
elif [ "$ASK_TOKEN" = 1 ] || [ -n "$GIT_TOKEN" ]; then
  echo "--git-token needs --repo=URL"; exit 1
fi

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
# --check: record a problem instead of fixing it
TODO=()
need() { TODO+=("$1"); warn "$1"; }
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]; }

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
  local dir="$1"
  case ":$PATH:" in *":$dir:"*) ;; *) export PATH="$dir:$PATH" ;; esac
  [ "$CHECK" = 1 ] && return 0
  mkdir -p "$dir"; touch "$RC"
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

echo "${B}Multica setup${N}  server=$SERVER_URL  os=$OS  mode=$MODE$([ $WANT_CLI = 1 ] && [ $MODE = app ] && echo ' +cli')$([ -n "$REPO_URL" ] && echo " +repo $REPO_NAME")$([ $CHECK = 1 ] && echo '  (check only)')"

# ---------------- preflight ----------------
step "Checking server"
curl -fsS -o /dev/null --max-time 15 "$SERVER_URL" || fail "Cannot reach $SERVER_URL"
ok "$SERVER_URL is reachable"
ensure_path "$LOCAL_BIN"
ensure_path "$HOME/.bun/bin"

if [ -n "$REPO_URL" ] && [ "$REPO_SSH" = 1 ]; then
  step "Access to $REPO_URL"
  ok "SSH address — your SSH key is used when downloading"
elif [ -n "$REPO_URL" ]; then
  step "Access to $REPO_URL"
  if [ "$ASK_TOKEN" = 1 ] && [ -z "$GIT_TOKEN" ]; then
    printf "Paste your git access token (input is hidden): "
    read -rs GIT_TOKEN < "$TTY"; echo
    [ -n "$GIT_TOKEN" ] || fail "No token given"
  fi
  # Ask the server with plain HTTP (git may not be installed yet). Without a token, a login
  # prompt is fine when git has its own login for this host; the download step will tell.
  if [ -n "$GIT_TOKEN" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -u "$GIT_USER:$GIT_TOKEN" "$REPO_URL/info/refs?service=git-upload-pack" || true)"
  else
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$REPO_URL/info/refs?service=git-upload-pack" || true)"
  fi
  case "$code" in
    200) ok "Repo is reachable${GIT_TOKEN:+ with your token}" ;;
    401|403|404)
      if [ -n "$GIT_TOKEN" ]; then fail "Token rejected for $REPO_URL (HTTP $code) — wrong, expired or no access. Ask your admin."
      elif [[ "$REPO_URL" == https://github.com/* ]]; then NEEDS_GH=1; ok "Private GitHub repo — you sign in with GitHub in the browser below"
      else warn "Repo needs a login (HTTP $code) — using your existing git login; add --git-token if you have none"; fi ;;
    000) fail "Cannot reach $REPO_URL" ;;
    *) warn "Unexpected answer $code from $REPO_URL — trying anyway" ;;
  esac
fi

# ---------------- system check ----------------
step "This computer"
if [ "$OS" = mac ]; then
  MACOS="$(sw_vers -productVersion)"; RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
  CHIP="$( [ "$(uname -m)" = arm64 ] && echo 'Apple Silicon' || echo Intel)"
  ok "macOS $MACOS, $CHIP"
else
  RAM_GB=$(( $(sed -n 's/^MemTotal: *\([0-9]*\).*/\1/p' /proc/meminfo) / 1048576 ))
  ok "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -sr), $(uname -m)"
fi
[ "$RAM_GB" -ge "$RAM_MIN_GB" ] && ok "Memory ${RAM_GB} GB" \
  || warn "Memory ${RAM_GB} GB — ${RAM_MIN_GB} GB or more recommended; close heavy apps while working."
DISK_GB=$(( $(df -Pk "$HOME" | awk 'NR==2{print $4}') / 1048576 ))
[ "$DISK_GB" -ge "$DISK_MIN_GB" ] && ok "Free disk ${DISK_GB} GB" || need "Only ${DISK_GB} GB free — at least ${DISK_MIN_GB} GB needed"

# ---------------- Claude Code ----------------
step "Claude Code"
if have claude; then
  ok "Installed: $(claude --version 2>/dev/null | head -1)"
elif [ "$CHECK" = 1 ]; then
  need "Claude Code is not installed"
else
  curl -fsSL https://claude.ai/install.sh | bash
  hash -r; have claude || fail "Claude Code install failed"
  ok "Installed: $(claude --version 2>/dev/null | head -1)"
fi

if have claude; then
  step "Claude login (your own subscription)"
  claude_ok() { claude -p "Reply with OK only" --max-turns 1 </dev/null >/dev/null 2>&1; }
  if claude_ok; then ok "Claude is logged in"
  elif [ "$CHECK" = 1 ]; then need "Claude is not logged in"
  else
    warn "Claude is not logged in."
    echo "   In Claude: type /login, finish sign-in in the browser, then type /exit"
    pause "Press Enter to open Claude… "
    claude < "$TTY" || true
    claude_ok && ok "Claude is logged in" || fail "Claude still not logged in — rerun this script after /login"
  fi
fi

# ---------------- git (Apple Command Line Tools) ----------------
step "git"
if [ "$OS" = mac ]; then
  if xcode-select -p >/dev/null 2>&1; then ok "Command Line Tools installed ($(git --version))"
  elif [ "$CHECK" = 1 ]; then need "Apple Command Line Tools (git) are not installed"
  else
    xcode-select --install >/dev/null 2>&1 || true
    warn "macOS opened an install window for the Command Line Tools."
    echo "   Click Install (your Mac password may be needed) and wait — this can take 5–15 minutes."
    for _ in $(seq 1 360); do xcode-select -p >/dev/null 2>&1 && break; sleep 5; done
    xcode-select -p >/dev/null 2>&1 || fail "Command Line Tools are still not installed — finish the install window, then rerun this script"
    ok "Command Line Tools installed ($(git --version))"
  fi
else
  have git && ok "$(git --version)" || need "git is not installed — install it with your package manager (e.g. sudo apt install git)"
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
  elif [ "$CHECK" = 1 ]; then
    need "Multica CLI is missing or not the latest ($ver)"; return 0
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
  [ "$CHECK" = 1 ] && return 0
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
  elif [ "$CHECK" = 1 ]; then
    need "Multica CLI is set to ${cur:-no server} or not logged in — will switch to $SERVER_URL and log in"
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
  mkdir -p "$MULTICA_DIR"; CFG="$MULTICA_DIR/desktop.json"
  cur="$(json_get "$CFG" apiUrl)"; cur="${cur%/}"
  if [ "$cur" = "$SERVER_URL" ] && ! grep -qs '"wsUrl"\|"appUrl"' "$CFG"; then
    ok "desktop.json → $SERVER_URL"
  elif [ "$CHECK" = 1 ]; then
    need "Multica Desktop points to ${cur:-nothing} — will switch to $SERVER_URL (you sign in again)"
  else
    osascript -e 'quit app "Multica"' >/dev/null 2>&1 || true
    [ -f "$CFG" ] && cp "$CFG" "$CFG.bak.$(date +%s)" && warn "desktop.json pointed to ${cur:-?} — replaced"
    printf '{\n  "schemaVersion": 1,\n  "apiUrl": "%s"\n}\n' "$SERVER_URL" > "$CFG"
    ok "desktop.json → $SERVER_URL"
  fi
  # Remove Desktop profiles left from other servers (e.g. Multica Cloud, an old self-hosted URL)
  for p in "$MULTICA_DIR"/profiles/desktop-*; do
    [ -d "$p" ] || continue
    [ "$(basename "$p")" = "$DESKTOP_PROFILE" ] && continue
    if [ "$CHECK" = 1 ]; then need "Old Desktop profile $(basename "$p") will be removed"
    else osascript -e 'quit app "Multica"' >/dev/null 2>&1 || true; rm -rf "$p" && ok "Removed old Desktop profile $(basename "$p")"; fi
  done

  step "Multica Desktop app"
  LATEST="$(latest_tag)"; LATEST="${LATEST#v}"
  APP=""; for d in /Applications "$HOME/Applications"; do [ -d "$d/Multica.app" ] && APP="$d/Multica.app"; done
  INSTALLED="$( [ -n "$APP" ] && defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
  if [ -n "$APP" ] && { [ "$INSTALLED" = "$LATEST" ] || [ -z "$LATEST" ]; }; then
    ok "Multica Desktop ${INSTALLED:-installed}$([ -n "$LATEST" ] && echo ' (latest)')"
  elif [ "$CHECK" = 1 ]; then
    need "Multica Desktop ${INSTALLED:+$INSTALLED → }${LATEST:-latest} will be installed"
  else
    osascript -e 'quit app "Multica"' >/dev/null 2>&1 || true
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
  if [ "$CHECK" = 0 ] && { have multica || [ -x "$LOCAL_BIN/multica" ]; }; then
    multica daemon stop </dev/null >/dev/null 2>&1 && ok "Stopped old CLI daemon" || true
    multica daemon autostart disable </dev/null >/dev/null 2>&1 && ok "Disabled CLI daemon autostart" || true
  fi

  if [ "$WANT_CLI" = 1 ]; then
    install_cli; connect_cli
    if [ "$CHECK" = 0 ]; then
      multica daemon stop </dev/null >/dev/null 2>&1 || true   # login can auto-start it; Desktop owns the daemon
      multica daemon autostart disable </dev/null >/dev/null 2>&1 || true
      ok "CLI ready for terminal commands (daemon left to the Desktop app)"
    fi
  fi
fi

# ---------------- Linux: CLI daemon ----------------
if [ "$MODE" = cli ]; then
  if [ -f "$MULTICA_DIR/desktop.json" ] || ls -d "$MULTICA_DIR"/profiles/desktop-* >/dev/null 2>&1; then
    if [ "$CHECK" = 1 ]; then need "Desktop app config found — will be removed (Linux uses the CLI daemon)"
    else
      step "Removing Desktop app setup (Linux uses the CLI daemon)"
      pkill -x multica-desktop >/dev/null 2>&1 || pkill -f '[Mm]ultica.*[Dd]esktop' >/dev/null 2>&1 || true
      [ -f "$MULTICA_DIR/desktop.json" ] && mv "$MULTICA_DIR/desktop.json" "$MULTICA_DIR/desktop.json.bak.$(date +%s)"
      rm -rf "$MULTICA_DIR"/profiles/desktop-*
      ok "Desktop config removed"
    fi
  fi
  install_cli; connect_cli
  step "Agent daemon"
  if [ "$CHECK" = 1 ]; then
    multica daemon status </dev/null >/dev/null 2>&1 && ok "Daemon is running" || need "Multica daemon is not running"
  else
    multica daemon autostart enable </dev/null || warn "Autostart could not be registered"
    multica daemon restart </dev/null >/dev/null 2>&1 || multica daemon start </dev/null
    loginctl enable-linger "$USER" >/dev/null 2>&1 && ok "Daemon will also run when you're not logged in" || true
    multica daemon status </dev/null || true
  fi
fi

# ---------------- repo + the tools it asks for ----------------
ensure_bun() {  # ensure_bun <min version or empty>
  local want="$1" v; v="$(have bun && bun --version 2>/dev/null || true)"
  if [ -n "$v" ] && { [ -z "$want" ] || version_ge "$v" "$want"; }; then ok "Bun $v"; return 0; fi
  if [ "$CHECK" = 1 ]; then need "Bun ${v:-is not installed}${v:+ is older than $want}${want:+ (repo needs $want+)}"; return 1; fi
  if [ -n "$v" ]; then bun upgrade >/dev/null 2>&1 || fail "Bun upgrade failed — run: bun upgrade"
  else
    curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || fail "Bun install failed — see https://bun.sh"
    hash -r; have bun || fail "Bun install failed"
    [ -z "$want" ] || version_ge "$(bun --version)" "$want" || bun upgrade >/dev/null 2>&1 || true
  fi
  ok "Bun $(bun --version)"
}
install_node() {  # latest Node.js LTS into ~/.local/node (no admin)
  local os arch v tmp
  case "$OS" in mac) os=darwin ;; *) os=linux ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=x64 ;; arm64|aarch64) arch=arm64 ;; *) return 1 ;; esac
  v="$(curl -fsSL https://nodejs.org/dist/index.tab | awk -F'\t' 'NR>1 && $10!="-" {print $1; exit}')"
  [ -n "$v" ] || return 1
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/node.tgz" "https://nodejs.org/dist/$v/node-$v-$os-$arch.tar.gz" || { rm -rf "$tmp"; return 1; }
  rm -rf "$HOME/.local/node"; mkdir -p "$HOME/.local/node"
  tar -xzf "$tmp/node.tgz" -C "$HOME/.local/node" --strip-components 1; rm -rf "$tmp"
  for b in node npm npx corepack; do ln -sf "$HOME/.local/node/bin/$b" "$LOCAL_BIN/$b"; done
  hash -r; have node
}
ensure_node_pm() {  # ensure_node_pm <npm|pnpm|yarn> <version or empty>
  local pm="$1" ver="$2"
  if ! have node; then
    if [ "$CHECK" = 1 ]; then need "Node.js is not installed (this repo uses $pm) — will install the LTS"; return 1; fi
    echo "Installing Node.js LTS into ~/.local/node…"
    install_node || { need "Node.js install failed — install the LTS from https://nodejs.org, then rerun"; return 1; }
  fi
  ok "Node $(node --version)"
  [ "$pm" = npm ] && return 0
  if have "$pm"; then ok "$pm $("$pm" --version 2>/dev/null)"; return 0; fi
  if [ "$CHECK" = 1 ]; then need "$pm is not installed — will be installed"; return 1; fi
  # corepack where Node still ships it, else npm into ~/.local (no admin either way)
  if ! { have corepack && corepack enable --install-directory "$LOCAL_BIN" "$pm" >/dev/null 2>&1 && hash -r && have "$pm"; }; then
    npm install -g --prefix "$HOME/.local" "$pm${ver:+@$ver}" >/dev/null 2>&1 || { need "Could not install $pm — run: npm install -g $pm"; return 1; }
  fi
  hash -r; have "$pm" || { need "$pm installed but not found on PATH — open a new terminal and rerun"; return 1; }
  ok "$pm $("$pm" --version 2>/dev/null)"
}

ensure_gh() {  # GitHub CLI in ~/.local/bin (no admin)
  have gh && return 0
  [ "$CHECK" = 1 ] && return 1
  local tag ver os arch ext tmp
  tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest | sed -n 's#.*/tag/##p')"
  ver="${tag#v}"; [ -n "$ver" ] || return 1
  case "$OS" in mac) os=macOS; ext=zip ;; *) os=linux; ext=tar.gz ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) return 1 ;; esac
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/gh.$ext" "https://github.com/cli/cli/releases/download/$tag/gh_${ver}_${os}_${arch}.$ext" || { rm -rf "$tmp"; return 1; }
  if [ "$ext" = zip ]; then unzip -q "$tmp/gh.zip" -d "$tmp"; else tar -xzf "$tmp/gh.tar.gz" -C "$tmp"; fi
  install -m 0755 "$tmp/gh_${ver}_${os}_${arch}/bin/gh" "$LOCAL_BIN/gh"; rm -rf "$tmp"; hash -r; have gh
}
github_login() {  # browser sign-in; git then uses it for github.com (overrides old saved passwords)
  step "GitHub sign-in"
  if have gh && gh auth status --hostname github.com </dev/null >/dev/null 2>&1; then
    ok "Signed in to GitHub as $(gh api user --jq .login </dev/null 2>/dev/null || echo '?')"
  elif [ "$CHECK" = 1 ]; then
    need "Not signed in to GitHub — will open the browser to sign in (GitHub CLI)"; return 0
  else
    ensure_gh || fail "Could not install GitHub CLI — install it from https://cli.github.com and rerun"
    echo "A browser window opens: sign in to GitHub and approve. If your organization uses SSO, also click Authorize for it."
    gh auth login --hostname github.com --git-protocol https --web < "$TTY" || fail "GitHub sign-in did not finish — rerun this script"
    ok "Signed in to GitHub as $(gh api user --jq .login </dev/null 2>/dev/null || echo '?')"
  fi
  if [ "$CHECK" = 0 ]; then
    gh auth setup-git --hostname github.com </dev/null >/dev/null 2>&1 && ok "git uses this GitHub sign-in" \
      || warn "Could not connect git to the GitHub sign-in — run: gh auth setup-git"
  fi
  return 0
}

if [ -n "$REPO_URL" ]; then
  [ "$NEEDS_GH" = 1 ] && github_login
  step "Repo \"$REPO_NAME\" → $REPO_DIR"
  AUTH_URL="$REPO_URL"; [ -n "$GIT_TOKEN" ] && AUTH_URL="https://$GIT_USER:$GIT_TOKEN@${REPO_URL#https://}"
  if [ -d "$REPO_DIR/.git" ]; then
    CUR_REMOTE="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null | sed -E 's#https://[^@]*@#https://#')"
    if [ "${CUR_REMOTE%/}" = "$REPO_URL" ]; then
      ok "Already downloaded ($(git -C "$REPO_DIR" branch --show-current)), local edits are kept"
      if [ -n "$GIT_TOKEN" ] && [ "$CHECK" = 0 ]; then git -C "$REPO_DIR" remote set-url origin "$AUTH_URL"; fi
    elif [ "$CHECK" = 1 ]; then need "$REPO_DIR comes from $CUR_REMOTE — will switch to $REPO_URL"
    else git -C "$REPO_DIR" remote set-url origin "$AUTH_URL"; ok "Switched source to $REPO_URL (local edits are kept)"; fi
  elif [ -e "$REPO_DIR" ] && [ -n "$(ls -A "$REPO_DIR" 2>/dev/null)" ]; then
    fail "$REPO_DIR exists and is not a git repo — move it away or pick another folder with --dir="
  elif [ "$CHECK" = 1 ]; then
    need "Repo is not downloaded yet${BRANCH:+ (branch $BRANCH)}"
  elif ! have git; then
    fail "git is missing — see the git step above"
  else
    mkdir -p "$(dirname "$REPO_DIR")"
    if [ -n "$BRANCH" ]; then git clone --quiet --branch "$BRANCH" "$AUTH_URL" "$REPO_DIR"
    else git clone --quiet "$AUTH_URL" "$REPO_DIR"; fi \
      || fail "Download failed — check the URL${BRANCH:+, branch $BRANCH} and your access$(
           [ "$REPO_SSH" = 1 ] && echo ". SSH: add your key to the git host (and authorize it for org SSO if used)."
           [ "$NEEDS_GH" = 1 ] && echo ". GitHub: make sure you are in the organization and authorized SSO for your sign-in (github.com → Settings → Applications).")"
    ok "Downloaded $(git -C "$REPO_DIR" branch --show-current)"
  fi
  # The token lives in .git/config: only this user may read it
  [ -n "$GIT_TOKEN" ] && [ -f "$REPO_DIR/.git/config" ] && [ "$CHECK" = 0 ] && chmod 600 "$REPO_DIR/.git/config"

  # What does the repo need?  packageManager / engines in package.json, else the lockfile.
  if [ -f "$REPO_DIR/package.json" ]; then
    PKG="$REPO_DIR/package.json"
    PM_FIELD="$(json_get "$PKG" packageManager)"        # e.g. bun@1.2.3, pnpm@9.1.0+sha512...
    PM="${PM_FIELD%%@*}"; PM_VER="${PM_FIELD#*@}"; [ "$PM_VER" = "$PM_FIELD" ] && PM_VER=""
    PM_VER="${PM_VER%%+*}"
    if [ -z "$PM" ]; then
      if   [ -f "$REPO_DIR/bun.lock" ] || [ -f "$REPO_DIR/bun.lockb" ]; then PM=bun
      elif [ -f "$REPO_DIR/pnpm-lock.yaml" ]; then PM=pnpm
      elif [ -f "$REPO_DIR/yarn.lock" ]; then PM=yarn
      else PM=npm; fi
    fi
    PM_OK=0
    if [ "$PM" = bun ]; then
      WANT="$(json_get "$PKG" bun | sed -E 's/^[^0-9]*//; s/[^0-9.].*$//')"   # engines.bun ">=1.2.3" -> 1.2.3
      if [ -n "$PM_VER" ] && { [ -z "$WANT" ] || version_ge "$PM_VER" "$WANT"; }; then WANT="$PM_VER"; fi
      step "Bun (this repo uses bun${WANT:+ $WANT+})"
      ensure_bun "$WANT" && PM_OK=1
    else
      step "Node.js + $PM (this repo uses $PM${PM_VER:+ $PM_VER})"
      ensure_node_pm "$PM" "$PM_VER" && PM_OK=1
    fi
    step "Dependencies"
    if [ -d "$REPO_DIR/node_modules" ]; then ok "Installed"
    elif [ "$CHECK" = 1 ]; then need "Dependencies are not installed yet ($PM install)"
    elif [ "$PM_OK" = 1 ] && [ -d "$REPO_DIR" ]; then
      LOG="$REPO_DIR/.setup-install.log"
      echo "Running $PM install (can take a few minutes the first time)…"
      (cd "$REPO_DIR" && "$PM" install >"$LOG" 2>&1) || fail "$PM install failed — see $LOG"
      rm -f "$LOG"; ok "Installed"
    fi
  fi
fi

# ---------------- Docker (local containers) ----------------
compose_in_repo() { # the downloaded repo runs containers locally
  local f
  [ -n "${REPO_DIR:-}" ] && [ -d "$REPO_DIR" ] || return 1
  for f in compose.yaml compose.yml docker-compose.yml docker-compose.yaml compose.local.yml docker/compose.local.yml docker/compose.yaml; do
    [ -f "$REPO_DIR/$f" ] && return 0
  done
  return 1
}
docker_running() { have docker && docker info >/dev/null 2>&1; }
docker_start_known() { # start an installed engine on macOS (no admin needed)
  if [ -d /Applications/Docker.app ] || [ -d "$HOME/Applications/Docker.app" ]; then open -a Docker
  elif [ -d /Applications/OrbStack.app ] || have orb; then open -a OrbStack 2>/dev/null || orb start >/dev/null 2>&1
  elif have colima; then colima start >/dev/null 2>&1
  else return 1; fi
}
docker_wait() { # up to ~3 min: first starts unpack images and may ask for approval in a window
  local i; for i in $(seq 1 90); do docker_running && return 0; sleep 2; done; return 1
}
install_dmg_app() { # install_dmg_app <url> <App name>
  local url="$1" app="$2" tmp dest
  tmp="$(mktemp -d)"
  echo "Downloading $app…"
  curl -fL --progress-bar -o "$tmp/app.dmg" "$url" || { rm -rf "$tmp"; return 1; }
  hdiutil attach -nobrowse -quiet -mountpoint "$tmp/mnt" "$tmp/app.dmg" || { rm -rf "$tmp"; return 1; }
  dest=/Applications
  if [ -w "$dest" ]; then rm -rf "$dest/$app.app"; cp -R "$tmp/mnt/$app.app" "$dest/"
  else
    echo "Copying $app to /Applications needs your Mac password."
    sudo rm -rf "$dest/$app.app" < "$TTY" && sudo cp -R "$tmp/mnt/$app.app" "$dest/" < "$TTY"
  fi
  hdiutil detach -quiet "$tmp/mnt" || true; rm -rf "$tmp"
  [ -d "$dest/$app.app" ]
}

DOCKER_NEEDED=0
case "$WANT_DOCKER" in
  yes) DOCKER_NEEDED=1 ;;
  auto)
    if compose_in_repo; then
      if docker_running; then DOCKER_NEEDED=1
      elif [ "$CHECK" = 1 ]; then DOCKER_NEEDED=1
      elif ask "This project runs a local database in Docker. Set up Docker now? [y/N] "; then DOCKER_NEEDED=1
      else warn "Skipped Docker — the apps run, but not the local database. Rerun with --docker later."; fi
    fi ;;
esac

if [ "$DOCKER_NEEDED" = 1 ]; then
  step "Docker"
  if docker_running; then
    ok "Docker is running ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'))"
  elif [ "$CHECK" = 1 ]; then
    if have docker; then need "Docker is installed but not running — will start it"
    else need "Docker is not installed — will install ${DOCKER_RUNTIME}"; fi
  elif [ "$OS" = linux ]; then
    if have docker; then
      id -nG | grep -qw docker || need "Add yourself to the docker group: sudo usermod -aG docker $USER (then log out and in)"
      need "Docker is installed but not running — start it: sudo systemctl enable --now docker"
    else
      need "Install Docker Engine for your distribution: https://docs.docker.com/engine/install/ (then rerun this script)"
    fi
  else
    if ! docker_start_known; then
      ARCH_D="$(uname -m)"
      case "$DOCKER_RUNTIME" in
        desktop)
          [ "$ARCH_D" = arm64 ] && d_arch=arm64 || d_arch=amd64
          install_dmg_app "https://desktop.docker.com/mac/main/$d_arch/Docker.dmg" Docker || fail "Docker Desktop install failed — install it from https://www.docker.com/products/docker-desktop/ and rerun"
          ok "Installed Docker Desktop"
          echo "   Docker Desktop opens: accept the terms, allow the helper (your Mac password), you can skip sign-in."
          open -a Docker ;;
        orbstack)
          [ "$ARCH_D" = arm64 ] && o_arch=arm64 || o_arch=amd64
          install_dmg_app "https://orbstack.dev/download/stable/latest/$o_arch" OrbStack || fail "OrbStack install failed — install it from https://orbstack.dev and rerun"
          ok "Installed OrbStack"
          echo "   OrbStack opens: finish its short welcome steps (choose Docker)."
          open -a OrbStack ;;
        colima)
          have brew || fail "Colima needs Homebrew (https://brew.sh). Install Homebrew, or rerun with --docker=desktop"
          brew install colima docker docker-compose >/dev/null || fail "brew install colima docker docker-compose failed"
          mkdir -p "$HOME/.docker/cli-plugins"
          ln -sfn "$(brew --prefix)/opt/docker-compose/bin/docker-compose" "$HOME/.docker/cli-plugins/docker-compose"
          ok "Installed Colima"
          colima start --cpu 2 --memory 4 >/dev/null 2>&1 || true ;;
      esac
      hash -r
    fi
    echo "Waiting for Docker to start (the first time can take a few minutes)…"
    if docker_wait; then ok "Docker is running ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'))"
    else need "Docker did not start yet — open the Docker app, finish any steps it shows, then rerun this script"; fi
  fi
  if docker_running; then
    docker compose version >/dev/null 2>&1 && ok "docker compose $(docker compose version --short 2>/dev/null)" \
      || need "docker compose is missing — reinstall Docker, or rerun with --docker=desktop"
  fi
fi

# ---------------- done ----------------
step "Done"
if [ "$CHECK" = 1 ]; then
  if [ ${#TODO[@]} -eq 0 ]; then ok "Everything is ready — nothing to install."
  else
    echo "${B}${#TODO[@]} thing(s) to fix:${N}"; for t in "${TODO[@]}"; do echo "  - $t"; done
    echo "Run the same command without --check to fix them."
  fi
  exit 0
fi
[ ${#TODO[@]} -eq 0 ] || { echo "${B}Still needs attention:${N}"; for t in "${TODO[@]}"; do echo "  - $t"; done; }
if [ "$MODE" = app ]; then
  [ -n "${APP:-}" ] && open "$APP"
  echo "Open Multica Desktop and sign in with your work email — it runs the agent daemon for this Mac."
else
  echo "The Multica daemon is running and starts automatically."
fi
echo "Then in $SERVER_URL: Agents → New agent → provider Claude Code → runtime = this computer."
[ -n "$REPO_URL" ] && echo "Repo is ready in $REPO_DIR."
echo "Open a NEW terminal window so PATH changes apply."
