#!/usr/bin/env bash
# Multica member setup — interactive (macOS / Linux)
#
# Checks this computer first (changes nothing), asks only what it must, then installs with setup.sh.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Zimpligital/multica-setup/refs/heads/main/start.sh) \
#     https://multica.example.com [--repo=URL] [--gateway=URL] [--branch=NAME] [--dir=PATH]
#
#   <server>          Multica server URL (required)
#   --repo=<url>      Project repo for people with access to its git host (e.g. GitHub)
#   --gateway=<url>   Read-only mirror for people without that access (asks for a token)
#   --branch=<name>   Branch to download (default: the repo's default branch)
#   --dir=<path>      Where to put the project (default: ~/Projects/<repo name>)
#
# Without --repo and --gateway only Multica and Claude are set up.
# Note: bash 3.2 (macOS) — always write ${VAR} before non-ASCII text.
set -euo pipefail

SETUP_URL="${MULTICA_SETUP_URL:-https://raw.githubusercontent.com/Zimpligital/multica-setup/refs/heads/main/setup.sh}"

# ---------------- args ----------------
SERVER_URL=""; REPO=""; GATEWAY=""; BRANCH=""; DIR=""
usage() { echo "Usage: start.sh <multica-server-url> [--repo=URL] [--gateway=URL] [--branch=NAME] [--dir=PATH]"; }
for arg in "$@"; do
  case "$arg" in
    --repo=*) REPO="${arg#*=}" ;;
    --gateway=*) GATEWAY="${arg#*=}" ;;
    --branch=*) BRANCH="${arg#*=}" ;;
    --dir=*) DIR="${arg#*=}" ;;
    http://*|https://*) SERVER_URL="${arg%/}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: ${arg}"; usage; exit 1 ;;
  esac
done
[ -n "$SERVER_URL" ] || { usage; exit 1; }
REPO="${REPO%/}"; GATEWAY="${GATEWAY%/}"
case "$GATEWAY" in ""|https://*) ;; *) echo "--gateway must be an https:// URL"; exit 1 ;; esac
CODE_OFFERED=0; { [ -n "$REPO" ] || [ -n "$GATEWAY" ]; } && CODE_OFFERED=1
if [ "$CODE_OFFERED" = 1 ] && [ -z "$DIR" ]; then
  DIR="$HOME/Projects/$(basename "${REPO:-$GATEWAY}" .git)"
fi
case "$DIR" in "~"/*) DIR="$HOME/${DIR#\~/}" ;; esac

# ---------------- helpers ----------------
B=$'\033[1m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
have() { command -v "$1" >/dev/null 2>&1; }
TTY=/dev/tty
[ -r "$TTY" ] || { echo "No terminal available — run this from Terminal."; exit 1; }
yes_no() {  # yes_no "question" <default y|n>
  local a; printf "%s" "$1"; read -r a < "$TTY" || a=""
  [ -n "$a" ] || a="$2"
  case "$a" in [Yy]*) return 0 ;; *) return 1 ;; esac
}
line() { printf "  %s %s\n" "$1" "$2"; }   # line <icon> <text>
short_path() { case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

case "$(uname -s)" in
  Darwin) OS=mac ;;
  Linux)  OS=linux ;;
  *) echo "Unsupported OS: $(uname -s) (Windows: use setup.ps1)"; exit 1 ;;
esac

# ---------------- checks (change nothing) ----------------
multica_installed() {  # prints what is installed; fails if nothing
  local app v
  if [ "$OS" = mac ]; then
    for app in /Applications/Multica.app "$HOME/Applications/Multica.app"; do
      if [ -d "$app" ]; then
        v="$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
        echo "Multica app${v:+ ${v}}"; return 0
      fi
    done
    return 1
  fi
  have multica || return 1
  v="$(multica version 2>/dev/null | head -1 || true)"
  echo "Multica CLI${v:+ (${v})}"
}
claude_installed() { have claude && claude --version </dev/null 2>/dev/null | head -1 | sed 's/ (Claude Code)//'; }
claude_email() {  # prints the email; fails when not logged in
  local st; st="$(claude auth status --json </dev/null 2>/dev/null || true)"
  printf '%s' "$st" | tr -d ' \n' | grep -q '"loggedIn":true' || return 1
  printf '%s' "$st" | tr -d '\n' | sed -nE 's/.*"email"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p'
}
git_ok() {
  if [ "$OS" = mac ]; then xcode-select -p >/dev/null 2>&1 && have git; else have git; fi
}
project_ok()  { [ -d "$DIR/.git" ]; }
packages_ok() { [ -d "$DIR/node_modules" ] || { [ -d "$DIR" ] && [ ! -f "$DIR/package.json" ]; }; }
docker_ok()   { have docker && docker info </dev/null >/dev/null 2>&1; }

MULTICA_READY=0; CLAUDE_READY=0; CODE_READY=0
check() {
  local m c e missing=""
  printf "%sMultica%s\n" "$B" "$N"
  if curl -fsS -o /dev/null --max-time 15 "$SERVER_URL" 2>/dev/null; then line "✅" "Server reachable"
  else
    line "❌" "Server not reachable: ${SERVER_URL}"
    printf "     Check your internet, or ask your admin.\n"; exit 1
  fi
  if m="$(multica_installed)"; then line "✅" "$m"; MULTICA_READY=1
  else line "⬜" "Multica $([ "$OS" = mac ] && echo app || echo CLI) not installed"; MULTICA_READY=0; fi

  printf "%sClaude%s\n" "$B" "$N"
  CLAUDE_READY=0
  if c="$(claude_installed)"; then
    line "✅" "Claude Code ${c}"
    if e="$(claude_email)"; then line "✅" "Logged in${e:+ as ${e}}"; CLAUDE_READY=1
    else line "⬜" "Not logged in"; fi
  else
    line "⬜" "Claude Code not installed"
    line "⬜" "Not logged in"
  fi

  [ "$CODE_OFFERED" = 1 ] || return 0
  printf "%sCode%s\n" "$B" "$N"
  git_ok      || missing="${missing} · git"
  project_ok  || missing="${missing} · project"
  packages_ok || missing="${missing} · packages"
  docker_ok   || missing="${missing} · Docker"
  if [ -z "$missing" ]; then line "✅" "$(short_path "$DIR")"; CODE_READY=1
  elif [ "$missing" = " · git · project · packages · Docker" ]; then line "⬜" "Not set up"; CODE_READY=0
  else line "⬜" "Missing: ${missing# · }"; CODE_READY=0; fi
}

# ---------------- git gateway token ----------------
GIT_USER=token; GIT_TOKEN=""
token_works() {  # token_works <url> <user> <token>
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -u "$2:$3" "$1/info/refs?service=git-upload-pack" || true)"
  [ "$code" = 200 ]
}
ask_token() {
  local tries=0 user
  while [ $tries -lt 3 ]; do
    tries=$((tries + 1))
    printf "Git token from your admin (hidden): "
    read -rs GIT_TOKEN < "$TTY" || GIT_TOKEN=""; echo
    [ -n "$GIT_TOKEN" ] || { echo "  No token given."; continue; }
    if token_works "$GATEWAY" token "$GIT_TOKEN"; then GIT_USER=token; return 0; fi
    printf "Git user name for this token: "
    read -r user < "$TTY" || user=""
    if [ -n "$user" ] && token_works "$GATEWAY" "$user" "$GIT_TOKEN"; then GIT_USER="$user"; return 0; fi
    printf "  %sToken not accepted%s — check it, or ask your admin for a new one.\n" "$R" "$N"
  done
  echo "Stopped: no working token."; exit 1
}

# ---------------- main ----------------
echo
check
echo

WANT_CODE=0; SOURCE=""
if [ "$CODE_OFFERED" = 1 ] && [ "$CODE_READY" = 0 ]; then
  if yes_no "Set up project code too? (y/N): " n; then WANT_CODE=1; fi
fi

if [ "$MULTICA_READY" = 1 ] && [ "$CLAUDE_READY" = 1 ] && [ "$WANT_CODE" = 0 ]; then
  echo "Everything you need is ready."; exit 0
fi

if [ "$WANT_CODE" = 1 ]; then
  ORIGIN=""
  if project_ok; then ORIGIN="$(git -C "$DIR" remote get-url origin 2>/dev/null | sed -E 's#https://[^@]*@#https://#; s#/$##' || true)"; fi
  if [ -n "$ORIGIN" ] && { [ "$ORIGIN" = "$REPO" ] || [ "$ORIGIN" = "$GATEWAY" ]; }; then
    SOURCE="$ORIGIN"     # already downloaded: keep its source and saved login
  elif [ -n "$REPO" ] && [ -n "$GATEWAY" ]; then
    if yes_no "Do you have GitHub access? (y/N): " n; then SOURCE="$REPO"; else SOURCE="$GATEWAY"; ask_token; fi
  elif [ -n "$REPO" ]; then SOURCE="$REPO"
  else SOURCE="$GATEWAY"; ask_token; fi
fi

echo
yes_no "Install now? (Y/n): " y || { echo "Nothing installed."; exit 0; }

ARGS=("$SERVER_URL")
if [ "$WANT_CODE" = 1 ]; then
  ARGS+=("--repo=${SOURCE}" "--dir=${DIR}" "--docker")
  [ -n "$BRANCH" ] && ARGS+=("--branch=${BRANCH}")
  [ -n "$GIT_TOKEN" ] && ARGS+=("--git-user=${GIT_USER}")
else
  ARGS+=("--no-docker")
fi

# Use setup.sh next to this file when run from a checkout, else download it
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
TMP=""
if [ -n "$HERE" ] && [ -f "$HERE/setup.sh" ]; then SETUP="$HERE/setup.sh"
else
  TMP="$(mktemp -d)"; SETUP="$TMP/setup.sh"
  curl -fsSL -o "$SETUP" "$SETUP_URL" || { echo "Could not download setup.sh from ${SETUP_URL}"; exit 1; }
fi

printf "\n%s" "$D"; echo "Installing… (details below)"; printf "%s" "$N"
set +e
SETUP_GIT_TOKEN="$GIT_TOKEN" bash "$SETUP" "${ARGS[@]}"
RC=$?
set -e
if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
GIT_TOKEN=""

echo; printf "%sResult%s\n" "$B" "$N"
[ "$WANT_CODE" = 1 ] || CODE_OFFERED=0   # don't report code they chose to skip
check
echo
if [ "$RC" != 0 ] || [ "$MULTICA_READY" = 0 ] || [ "$CLAUDE_READY" = 0 ] || { [ "$WANT_CODE" = 1 ] && [ "$CODE_READY" = 0 ]; }; then
  echo "Not finished yet. Fix the messages above, then run the same command again — it continues where it stopped."
  exit 1
fi
if [ "$OS" = mac ]; then echo "Done. Sign in to the Multica app with your work email."
else echo "Done. The Multica runtime is running and starts automatically."; fi
