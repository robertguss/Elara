# Shared by verify-elara helpers. Source only; do not execute.
# shellcheck shell=bash

set -euo pipefail

skill_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$here/.." && pwd
}

repo_root() {
  cd "$(skill_root)/../../.." && pwd
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "verify-elara: missing required command: $1" >&2
    exit 1
  }
}

default_state_path() {
  if [ -n "${ELARA_VERIFY_STATE:-}" ]; then
    printf '%s\n' "$ELARA_VERIFY_STATE"
    return
  fi
  local newest
  newest="$(ls -1dt /tmp/elara-verify-*/state.env 2>/dev/null | head -n 1 || true)"
  if [ -n "$newest" ]; then
    printf '%s\n' "$newest"
    return
  fi
  echo "verify-elara: no launch state. Run bin/launch first, or set ELARA_VERIFY_STATE." >&2
  exit 1
}

load_state() {
  local path="${1:-$(default_state_path)}"
  if [ ! -f "$path" ]; then
    echo "verify-elara: state file not found: $path" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$path"
  ELARA_VERIFY_STATE="$path"
  export ELARA_VERIFY_STATE RUN_ID VERIFY_ROOT REPO_ROOT WORKSPACE WORKTREE
  export ELARA_SERVER_PORT ELARA_TUI_STATE_DIR EVIDENCE_ROOT
  export ELARA_USER_HOME
  export HOME
  # Isolated HOME must not steal Mix/Hex/Cargo caches.
  if [ -n "${ELARA_USER_HOME:-}" ]; then
    export MIX_HOME="${MIX_HOME:-$ELARA_USER_HOME/.mix}"
    export HEX_HOME="${HEX_HOME:-$ELARA_USER_HOME/.hex}"
    export CARGO_HOME="${CARGO_HOME:-$ELARA_USER_HOME/.cargo}"
  fi
}

append_pid() {
  local pid="$1"
  local path="$ELARA_VERIFY_STATE"
  if grep -q '^PIDS=' "$path"; then
    local current
    current="$(sed -n 's/^PIDS=//p' "$path" | tail -n 1)"
    if [ -n "$current" ]; then
      sed -i.bak "s|^PIDS=.*|PIDS=${current} ${pid}|" "$path"
    else
      sed -i.bak "s|^PIDS=.*|PIDS=${pid}|" "$path"
    fi
    rm -f "${path}.bak"
  else
    printf 'PIDS=%s\n' "$pid" >>"$path"
  fi
}

pick_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

port_owner_pid() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true
}

user_home() {
  printf '%s\n' "${ELARA_USER_HOME:-$HOME}"
}

credentials_report() {
  local user_home="${1:-$(user_home)}"
  if [ -n "${ELARA_API_KEY:-}" ]; then
    echo "credentials: ELARA_API_KEY is set (value not printed)"
  elif [ -n "${XAI_API_KEY:-}" ]; then
    echo "credentials: XAI_API_KEY is set (value not printed)"
  elif [ -f "$user_home/.elara/auth.json" ]; then
    echo "credentials: $user_home/.elara/auth.json exists"
  elif [ -f "$user_home/.elara/openai-codex-auth.json" ]; then
    echo "credentials: $user_home/.elara/openai-codex-auth.json exists"
  else
    echo "credentials: none visible (scripted drives still work)"
  fi
}

evidence_dir() {
  local feature="$1"
  local dest
  dest="$EVIDENCE_ROOT/$feature/$RUN_ID"
  mkdir -p "$dest"
  printf '%s\n' "$dest"
}

write_text() {
  local path="$1"
  local body="$2"
  printf '%s' "$body" >"$path"
}
