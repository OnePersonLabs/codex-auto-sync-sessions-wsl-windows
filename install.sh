#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_windows_profile_win() {
  if command -v cmd.exe >/dev/null 2>&1; then
    cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r' | tail -n 1
  fi
}

to_wsl_path() {
  local path="$1"
  if command -v wslpath >/dev/null 2>&1; then
    wslpath -a "$path"
  else
    printf '%s\n' "$path"
  fi
}

WINDOWS_PROFILE_WIN="${CODEX_WINDOWS_PROFILE_WIN:-$(detect_windows_profile_win)}"
if [[ -z "$WINDOWS_PROFILE_WIN" ]]; then
  WINDOWS_PROFILE_WIN="C:/Users/${USER}"
fi
WINDOWS_PROFILE_WIN="${WINDOWS_PROFILE_WIN//\\//}"

WSL_CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
WINDOWS_CODEX_HOME_WIN="${CODEX_HOME_WINDOWS_WIN:-${WINDOWS_PROFILE_WIN}/.codex}"
WINDOWS_CODEX_HOME="${CODEX_HOME_WINDOWS:-$(to_wsl_path "$WINDOWS_CODEX_HOME_WIN")}"

WSL_HOOKS_DIR="$WSL_CODEX_HOME/hooks"
WINDOWS_HOOKS_DIR="$WINDOWS_CODEX_HOME/hooks"

WSL_SCRIPT="$WSL_HOOKS_DIR/sync-codex-sessions.sh"
WINDOWS_CMD="$WINDOWS_HOOKS_DIR/sync-codex-sessions.cmd"

mkdir -p "$WSL_HOOKS_DIR" "$WINDOWS_HOOKS_DIR"
cp -f "$REPO_DIR/sync-codex-sessions.sh" "$WSL_SCRIPT"
cp -f "$REPO_DIR/sync-codex-sessions.cmd" "$WINDOWS_CMD"
cp -f "$REPO_DIR/SPECIFICATION.md" "$WSL_CODEX_HOME/sync-codex-sessions-readme.md"
cp -f "$REPO_DIR/SPECIFICATION.md" "$WINDOWS_CODEX_HOME/sync-codex-sessions-readme.md"
chmod 755 "$WSL_SCRIPT"

install_hooks() {
  local hooks_file="$1"
  local stop_command="$2"
  local cancel_command="$3"
  local stop_status="$4"
  local cancel_status="$5"

  HOOKS_FILE="$hooks_file" \
  STOP_COMMAND="$stop_command" \
  CANCEL_COMMAND="$cancel_command" \
  STOP_STATUS="$stop_status" \
  CANCEL_STATUS="$cancel_status" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

hooks_path = Path(os.environ["HOOKS_FILE"])
stop_command = os.environ["STOP_COMMAND"]
cancel_command = os.environ["CANCEL_COMMAND"]
stop_status = os.environ["STOP_STATUS"]
cancel_status = os.environ["CANCEL_STATUS"]

if hooks_path.exists():
    data = json.loads(hooks_path.read_text(encoding="utf-8"))
else:
    data = {"hooks": {}}

hooks = data.setdefault("hooks", {})

def is_managed(hook):
    return "sync-codex-sessions" in str(hook.get("command", ""))

for event in list(hooks):
    groups = []
    for group in hooks.get(event, []):
        kept = [hook for hook in group.get("hooks", []) if not is_managed(hook)]
        if kept:
            next_group = dict(group)
            next_group["hooks"] = kept
            groups.append(next_group)
    if groups:
        hooks[event] = groups
    else:
        hooks.pop(event, None)

hooks.setdefault("Stop", []).append({
    "hooks": [{
        "type": "command",
        "command": stop_command,
        "timeout": 20,
        "statusMessage": stop_status,
    }]
})

hooks.setdefault("UserPromptSubmit", []).append({
    "hooks": [{
        "type": "command",
        "command": cancel_command,
        "timeout": 5,
        "statusMessage": cancel_status,
    }]
})

hooks_path.parent.mkdir(parents=True, exist_ok=True)
hooks_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

install_hooks \
  "$WSL_CODEX_HOME/hooks.json" \
  "bash '$WSL_SCRIPT' --to-windows --side wsl" \
  "bash '$WSL_SCRIPT' --cancel-pending --side wsl" \
  "Syncing Codex sessions from WSL into Windows" \
  "Cancelling pending WSL Codex session sync"

install_hooks \
  "$WINDOWS_CODEX_HOME/hooks.json" \
  "\"$WINDOWS_CODEX_HOME_WIN/hooks/sync-codex-sessions.cmd\" --to-wsl --side windows" \
  "\"$WINDOWS_CODEX_HOME_WIN/hooks/sync-codex-sessions.cmd\" --cancel-pending --side windows" \
  "Syncing Codex sessions from Windows into WSL" \
  "Cancelling pending Windows Codex session sync"

echo "Installed Codex session sync hooks and scripts."
