#!/usr/bin/env bash
set -euo pipefail

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

remove_hooks() {
  local hooks_file="$1"

  HOOKS_FILE="$hooks_file" python3 - <<'PY'
import json
import os
from pathlib import Path

hooks_path = Path(os.environ["HOOKS_FILE"])
if not hooks_path.exists():
    raise SystemExit(0)

data = json.loads(hooks_path.read_text(encoding="utf-8"))
hooks = data.setdefault("hooks", {})

def is_managed(hook):
    if not isinstance(hook, dict):
        return False
    return "sync-codex-sessions" in str(hook.get("command", ""))

for event in list(hooks):
    if not any(
        is_managed(hook)
        for group in hooks.get(event, [])
        if isinstance(group, dict)
        for hook in group.get("hooks", [])
    ):
        continue

    groups = []
    for group in hooks.get(event, []):
        if not isinstance(group, dict):
            groups.append(group)
            continue
        kept = [hook for hook in group.get("hooks", []) if not is_managed(hook)]
        if kept:
            next_group = dict(group)
            next_group["hooks"] = kept
            groups.append(next_group)
    if groups:
        hooks[event] = groups
    else:
        hooks.pop(event, None)

hooks_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

remove_hooks "$WSL_CODEX_HOME/hooks.json"
remove_hooks "$WINDOWS_CODEX_HOME/hooks.json"

rm -f "$WSL_CODEX_HOME/hooks/sync-codex-sessions.sh"
rm -f "$WINDOWS_CODEX_HOME/hooks/sync-codex-sessions.cmd"
rm -f "$WINDOWS_CODEX_HOME/.codex-session-sync.lock."*.pending 2>/dev/null || true
rm -f "$WSL_CODEX_HOME/sync-codex-sessions-readme.md"
rm -f "$WINDOWS_CODEX_HOME/sync-codex-sessions-readme.md"

echo "Uninstalled Codex session sync hooks and scripts."
