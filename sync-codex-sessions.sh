#!/usr/bin/env bash
set -uo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

log() {
  local level="$1"
  local message="$2"
  local now
  now="$(date -Iseconds)"
  printf '%s [%s] %s\n' "$now" "$level" "$message" >> "$LOG_FILE" || true
}

usage() {
  cat <<EOF
Usage: sync-codex-sessions.sh [--to-windows|--to-wsl] [--side windows|wsl] [--cancel-pending|--run-pending] [--windows-home <path>] [--dry-run] [--hook] [--stop-hook] [--debug]
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "Missing value for $option" >&2
    usage >&2
    exit 1
  fi
}

normalize_windows_home() {
  case "$WINDOWS_HOME" in
    ?:/*|?:\\*|\\\\*)
      if command -v wslpath >/dev/null 2>&1; then
        WINDOWS_HOME="$(wslpath -a "$WINDOWS_HOME")"
      fi
      ;;
  esac
}

ACTION="sync"
MODE=""
SIDE=""
WINDOWS_HOME="${CODEX_HOME_WINDOWS:-/mnt/c/Users/zethj/.codex}"
LOCAL_HOME="${CODEX_HOME:-$HOME/.codex}"
DRY_RUN="0"
HOOK_MODE="0"
STOP_HOOK="0"
DEBUG_OUTPUT="0"

SYNC_LOCK_FILE="${CODEX_SESSION_SYNC_LOCK_FILE:-}"
SYNC_LOCK_TIMEOUT_SECONDS="${CODEX_SESSION_SYNC_LOCK_TIMEOUT_SECONDS:-${CODEX_SYNC_LOCK_TIMEOUT_SECONDS:-2}}"
SYNC_DEBOUNCE_SECONDS="${CODEX_SESSION_SYNC_DEBOUNCE_SECONDS:-60}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to-windows)
      MODE="to-windows"
      ;;
    --to-wsl)
      MODE="to-wsl"
      ;;
    --side)
      shift
      require_value "--side" "${1:-}"
      SIDE="$1"
      ;;
    --cancel-pending)
      ACTION="cancel-pending"
      ;;
    --run-pending)
      ACTION="run-pending"
      ;;
    --windows-home)
      shift
      require_value "--windows-home" "${1:-}"
      WINDOWS_HOME="$1"
      ;;
    --dry-run)
      DRY_RUN="1"
      ;;
    --hook)
      HOOK_MODE="1"
      ;;
    --stop-hook)
      HOOK_MODE="1"
      STOP_HOOK="1"
      ;;
    --debug)
      DEBUG_OUTPUT="1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unsupported argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

normalize_windows_home

if [[ -z "$SIDE" ]]; then
  case "$MODE" in
    to-windows)
      SIDE="wsl"
      ;;
    to-wsl)
      SIDE="windows"
      ;;
  esac
fi

case "$SIDE" in
  windows|wsl)
    ;;
  *)
    echo "Missing or invalid side: expected windows or wsl" >&2
    usage >&2
    exit 1
    ;;
esac

if [[ -z "$MODE" ]]; then
  case "$SIDE" in
    windows)
      MODE="to-wsl"
      ;;
    wsl)
      MODE="to-windows"
      ;;
  esac
fi

case "$MODE" in
  to-windows)
    SOURCE_HOME="$LOCAL_HOME"
    TARGET_HOME="$WINDOWS_HOME"
    ;;
  to-wsl)
    SOURCE_HOME="$WINDOWS_HOME"
    TARGET_HOME="$LOCAL_HOME"
    ;;
  *)
    echo "Unknown sync mode: $MODE" >&2
    exit 1
    ;;
esac

LOG_FILE="${CODEX_SESSION_SYNC_LOG:-${CODEX_SYNC_LOG:-$LOCAL_HOME/sync-codex-sessions.log}}"
SYNC_LOCK_FILE="${CODEX_SESSION_SYNC_LOCK_FILE:-${CODEX_SESSION_SYNC_LOCK_DIR:-${CODEX_SYNC_LOCK_FILE:-${CODEX_SYNC_LOCK_DIR:-${WINDOWS_HOME}/.codex-session-sync.lock}}}}"
SIDE_PENDING_FILE="${SYNC_LOCK_FILE}.${SIDE}.pending"
LOCK_HELD="0"

cleanup() {
  if [[ "$LOCK_HELD" == "1" ]]; then
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
  fi
}

trap cleanup EXIT

emit_status() {
  if [[ "$DEBUG_OUTPUT" != "1" ]]; then
    log "INFO" "$1"
  else
    echo "$1"
  fi
}

emit_stop_continue() {
  if [[ "$STOP_HOOK" == "1" ]]; then
    printf '%s\n' '{"continue":true}'
  fi
}

cancel_pending_sync() {
  rm -f "$SIDE_PENDING_FILE" 2>/dev/null || true
  log "INFO" "cancelled pending sync for side=$SIDE"
  emit_status "pending sync cancelled: side=$SIDE"
}

launch_pending_runner() {
  local token="$1"
  local args=("$SCRIPT_PATH" "--run-pending" "--side" "$SIDE" "--windows-home" "$WINDOWS_HOME")

  if [[ "$DRY_RUN" == "1" ]]; then
    args+=("--dry-run")
  fi

  CODEX_SESSION_SYNC_PENDING_TOKEN="$token" \
  CODEX_SESSION_SYNC_LOCK_FILE="$SYNC_LOCK_FILE" \
  CODEX_SESSION_SYNC_DEBOUNCE_SECONDS="$SYNC_DEBOUNCE_SECONDS" \
    nohup bash "${args[@]}" >/dev/null 2>&1 &
}

schedule_pending_sync() {
  local token
  token="$(date +%s%N)-$$"

  mkdir -p "$(dirname "$SIDE_PENDING_FILE")" 2>/dev/null || return 1

  if ( set -C; printf '%s\n' "$token" > "$SIDE_PENDING_FILE" ) 2>/dev/null; then
    launch_pending_runner "$token"
    log "INFO" "scheduled debounced pending sync for side=$SIDE after ${SYNC_DEBOUNCE_SECONDS}s"
    return 0
  fi

  log "INFO" "pending sync already scheduled for side=$SIDE"
  return 0
}

reschedule_pending_sync() {
  rm -f "$SIDE_PENDING_FILE" 2>/dev/null || true
  schedule_pending_sync
}

acquire_sync_lock() {
  if [[ -d "$SYNC_LOCK_FILE" ]]; then
    log "WARN" "removing legacy lock directory at $SYNC_LOCK_FILE"
    rm -rf "$SYNC_LOCK_FILE"
  fi

  mkdir -p "$(dirname "$SYNC_LOCK_FILE")" 2>/dev/null || return 1
  exec 9>"$SYNC_LOCK_FILE" || return 1

  if ! flock -x -w "$SYNC_LOCK_TIMEOUT_SECONDS" 9; then
    exec 9>&- 2>/dev/null || true
    return 1
  fi

  {
    printf 'pid=%s\n' "$$"
    printf 'side=%s\n' "$SIDE"
    printf 'mode=%s\n' "$MODE"
    printf 'source=%s\n' "$SOURCE_HOME"
    printf 'target=%s\n' "$TARGET_HOME"
    printf 'acquired_at=%s\n' "$(date -Iseconds)"
  } > "$SYNC_LOCK_FILE" 2>/dev/null || true

  LOCK_HELD="1"
  return 0
}

hash_file() {
  sha256sum "$1" | awk '{print $1}'
}

extract_codex_version() {
  sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1
}

local_codex_version() {
  codex --version 2>/dev/null | tr -d '\r' | extract_codex_version
}

windows_codex_version() {
  local powershell="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"

  if [[ -x "$powershell" ]]; then
    "$powershell" -NoProfile -Command "codex --version" 2>/dev/null | tr -d '\r' | extract_codex_version
    return 0
  fi

  return 1
}

debug_status() {
  if [[ "$DEBUG_OUTPUT" == "1" ]]; then
    emit_status "$1"
  fi
}

require_matching_codex_versions() {
  local wsl_version
  local windows_version

  wsl_version="$(local_codex_version || true)"
  windows_version="$(windows_codex_version || true)"

  if [[ -z "$wsl_version" || -z "$windows_version" ]]; then
    log "WARN" "sync aborted: unable to compare Codex versions wsl=${wsl_version:-unknown} windows=${windows_version:-unknown}"
    debug_status "sync aborted: unable to compare Codex versions (wsl=${wsl_version:-unknown}, windows=${windows_version:-unknown})"
    return 1
  fi

  if [[ "$wsl_version" != "$windows_version" ]]; then
    log "WARN" "sync aborted: Codex versions differ wsl=$wsl_version windows=$windows_version"
    debug_status "sync aborted: Codex versions differ (wsl=$wsl_version, windows=$windows_version)"
    return 1
  fi

  log "INFO" "Codex versions match: $wsl_version"
  return 0
}

import_stamp_file() {
  printf '%s\n' "$1/.codex-session-sync.imports.tsv"
}

record_import_stamp() {
  local target_home="$1"
  local rel_path="$2"
  local source_file="$3"
  local source_size="$4"
  local stamp_file
  local source_hash

  stamp_file="$(import_stamp_file "$target_home")"
  source_hash="$(hash_file "$source_file")" || return 0
  printf '%s\t%s\t%s\n' "$source_hash" "$source_size" "$rel_path" >> "$stamp_file" || true
}

is_imported_unchanged() {
  local source_home="$1"
  local rel_path="$2"
  local source_file="$3"
  local source_size="$4"
  local stamp_file
  local source_hash

  stamp_file="$(import_stamp_file "$source_home")"
  if [[ ! -f "$stamp_file" ]]; then
    return 1
  fi

  source_hash="$(hash_file "$source_file")" || return 1
  awk -F '\t' -v h="$source_hash" -v s="$source_size" -v p="$rel_path" \
    '$1 == h && $2 == s && $3 == p { found = 1 } END { exit found ? 0 : 1 }' "$stamp_file"
}

collect_paths() {
  local root="$1"

  if [[ -d "$root/sessions" ]]; then
    find "$root/sessions" -type f -print
  fi

  if [[ -d "$root/archived_sessions" ]]; then
    find "$root/archived_sessions" -type f -print
  fi
}

copy_file_atomic() {
  local source_file="$1"
  local dst_file="$2"
  local dst_dir
  local dst_name
  local tmp_file

  dst_dir="$(dirname "$dst_file")"
  dst_name="$(basename "$dst_file")"

  if ! mkdir -p "$dst_dir"; then
    log "ERROR" "failed to create destination directory: $dst_dir"
    return 1
  fi

  if ! tmp_file="$(mktemp "$dst_dir/.${dst_name}.sync.XXXXXX")"; then
    log "ERROR" "failed to create temporary copy target in: $dst_dir"
    return 1
  fi

  if cp -p "$source_file" "$tmp_file" && mv -f "$tmp_file" "$dst_file"; then
    return 0
  fi

  rm -f "$tmp_file" 2>/dev/null || true
  log "ERROR" "failed to atomically copy $source_file -> $dst_file"
  return 1
}

merge_session_index() {
  local source_index="$SOURCE_HOME/session_index.jsonl"
  local target_index="$TARGET_HOME/session_index.jsonl"
  local target_dir
  local tmp_file
  local inputs=()
  local merged_count

  [[ -f "$target_index" ]] && inputs+=("$target_index")
  [[ -f "$source_index" ]] && inputs+=("$source_index")

  if [[ "${#inputs[@]}" -eq 0 ]]; then
    log "SKIP" "session_index.jsonl missing on both sides"
    echo "0"
    return 0
  fi

  target_dir="$(dirname "$target_index")"
  if ! mkdir -p "$target_dir"; then
    log "ERROR" "failed to create session index directory: $target_dir"
    echo "0"
    return 1
  fi

  if ! tmp_file="$(mktemp "$target_dir/.session_index.jsonl.merge.XXXXXX")"; then
    log "ERROR" "failed to create temporary session index in: $target_dir"
    echo "0"
    return 1
  fi

  awk '
    /"id":"[^"]+"/ && /"updated_at":"[^"]+"/ {
      id = $0
      sub(/^.*"id":"/, "", id)
      sub(/".*$/, "", id)

      updated = $0
      sub(/^.*"updated_at":"/, "", updated)
      sub(/".*$/, "", updated)

      if (!(id in seen)) {
        order[++count] = id
        seen[id] = 1
      }

      if (!(id in updated_by_id) || updated >= updated_by_id[id]) {
        updated_by_id[id] = updated
        line_by_id[id] = $0
      }
    }

    END {
      for (i = 1; i <= count; i++) {
        id = order[i]
        if (id in line_by_id) {
          print updated_by_id[id] "\t" line_by_id[id]
        }
      }
    }
  ' "${inputs[@]}" | sort -t $'\t' -k1,1 | cut -f2- > "$tmp_file"

  if [[ -f "$target_index" ]] && cmp -s "$tmp_file" "$target_index"; then
    rm -f "$tmp_file"
    log "SKIP" "already in-sync: session_index.jsonl"
    echo "0"
    return 0
  fi

  merged_count="$(wc -l < "$tmp_file" | tr -d ' ')"

  if (( DRY_RUN == 1 )); then
    rm -f "$tmp_file"
    log "DRY" "merge session_index.jsonl entries=$merged_count"
    echo "1"
    return 0
  fi

  if mv -f "$tmp_file" "$target_index"; then
    log "MERGE" "session_index.jsonl entries=$merged_count"
    echo "1"
    return 0
  fi

  rm -f "$tmp_file" 2>/dev/null || true
  log "ERROR" "failed to replace merged session index: $target_index"
  echo "0"
  return 1
}

reindex_target_threads() {
  local path_style="posix"
  local result
  local inserted
  local args=("$SCRIPT_DIR/reindex-codex-sessions.mjs" "--codex-home" "$TARGET_HOME" "--repair-paths")

  if [[ "$TARGET_HOME" == "$WINDOWS_HOME" ]]; then
    path_style="windows"
  fi

  args+=("--path-style" "$path_style")

  if (( DRY_RUN == 1 )); then
    args+=("--dry-run")
  fi

  if ! command -v node >/dev/null 2>&1; then
    log "WARN" "session reindex skipped: node is not available"
    echo "0"
    return 0
  fi

  if ! command -v sqlite3 >/dev/null 2>&1; then
    log "WARN" "session reindex skipped: sqlite3 is not available"
    echo "0"
    return 0
  fi

  if ! result="$(node "${args[@]}" 2>>"$LOG_FILE")"; then
    log "ERROR" "session reindex failed for target=$TARGET_HOME"
    echo "0"
    return 1
  fi

  inserted="${result##*inserted=}"
  inserted="${inserted%% *}"
  if [[ -z "$inserted" || "$inserted" == "$result" ]]; then
    inserted="0"
  fi

  log "REINDEX" "$result"
  echo "$inserted"
}

run_sync_pass() {
  local tmp_source_paths
  local tmp_unsorted
  local tmp_sorted
  local copied=0
  local skipped=0
  local src_file
  local src_mtime
  local src_size
  local src_rest
  local src_file_path
  local rel_path
  local dst_file
  local dst_mtime
  local dst_size
  local copy_needed
  local reason
  local index_merged=0
  local reindexed=0

  tmp_source_paths="$(mktemp)"
  tmp_unsorted="$(mktemp)"
  tmp_sorted="$(mktemp)"

  collect_paths "$SOURCE_HOME" > "$tmp_source_paths"

  while IFS= read -r src_file; do
    if [[ ! -f "$src_file" ]]; then
      continue
    fi

    if ! src_mtime="$(stat -c '%Y' "$src_file")"; then
      log "ERROR" "failed to stat mtime: $src_file"
      continue
    fi

    if ! src_size="$(stat -c '%s' "$src_file")"; then
      log "ERROR" "failed to stat size: $src_file"
      continue
    fi

    printf '%s\t%s\t%s\n' "$src_mtime" "$src_size" "$src_file" >> "$tmp_unsorted"
  done < "$tmp_source_paths"

  if [[ -s "$tmp_unsorted" ]]; then
    sort -t $'\t' -k1,1nr -k2,2nr -k3,3n "$tmp_unsorted" > "$tmp_sorted"
  fi

  while IFS= read -r entry; do
    if [[ -z "$entry" ]]; then
      continue
    fi

    src_mtime="${entry%%$'\t'*}"
    src_rest="${entry#*$'\t'}"
    src_size="${src_rest%%$'\t'*}"
    src_file_path="${src_rest#*$'\t'}"
    if [[ -z "$src_file_path" || -z "$src_mtime" || -z "$src_size" ]]; then
      log "SKIP" "invalid metadata line: $entry"
      ((skipped++))
      continue
    fi

    rel_path="${src_file_path#$SOURCE_HOME/}"
    dst_file="$TARGET_HOME/$rel_path"

    if [[ -f "$dst_file" ]]; then
      dst_mtime="$(stat -c '%Y' "$dst_file")"
      dst_size="$(stat -c '%s' "$dst_file")"
    else
      dst_mtime="0"
      dst_size="0"
    fi

    copy_needed=0
    reason="already in-sync"

    if [[ ! -f "$dst_file" ]]; then
      copy_needed=1
      reason="dest missing"
    elif (( src_mtime > dst_mtime )); then
      copy_needed=1
      reason="source newer by mtime"
    elif (( src_mtime == dst_mtime )) && (( src_size > dst_size )); then
      copy_needed=1
      reason="same mtime but source larger"
    fi

    if (( copy_needed == 1 )) && [[ -f "$dst_file" ]] && is_imported_unchanged "$SOURCE_HOME" "$rel_path" "$src_file_path" "$src_size"; then
      copy_needed=0
      reason="source is unchanged import from peer"
    fi

    if (( copy_needed == 1 )); then
      if (( DRY_RUN == 1 )); then
        log "DRY" "copy $src_file_path -> $dst_file ($reason)"
      else
        if ! copy_file_atomic "$src_file_path" "$dst_file"; then
          ((skipped++))
          continue
        fi
        record_import_stamp "$TARGET_HOME" "$rel_path" "$src_file_path" "$src_size"
        log "COPY" "$reason: $rel_path"
      fi
      ((copied++))
    else
      log "SKIP" "$reason: $rel_path"
      ((skipped++))
    fi
  done < "$tmp_sorted"

  rm -f "$tmp_source_paths" "$tmp_unsorted" "$tmp_sorted"
  index_merged="$(merge_session_index)"
  reindexed="$(reindex_target_threads)"
  echo "$copied $skipped $index_merged $reindexed"
}

run_pending_sync() {
  local expected_token="${CODEX_SESSION_SYNC_PENDING_TOKEN:-}"
  local current_token
  local run_result
  local copied
  local skipped
  local index_merged
  local reindexed

  if [[ -z "$expected_token" ]]; then
    exit 0
  fi

  sleep "$SYNC_DEBOUNCE_SECONDS"

  current_token="$(cat "$SIDE_PENDING_FILE" 2>/dev/null || true)"
  if [[ "$current_token" != "$expected_token" ]]; then
    exit 0
  fi

  if ! acquire_sync_lock; then
    current_token="$(cat "$SIDE_PENDING_FILE" 2>/dev/null || true)"
    if [[ "$current_token" == "$expected_token" ]]; then
      reschedule_pending_sync
    fi
    emit_status "pending sync backed off: side=$SIDE"
    exit 0
  fi

  current_token="$(cat "$SIDE_PENDING_FILE" 2>/dev/null || true)"
  if [[ "$current_token" != "$expected_token" ]]; then
    exit 0
  fi

  rm -f "$SIDE_PENDING_FILE" 2>/dev/null || true
  run_result="$(run_sync_pass)"
  read -r copied skipped index_merged reindexed <<<"$run_result"
  emit_status "pending sync completed: side=$SIDE mode=$MODE copied=$copied skipped=$skipped index_merged=$index_merged reindexed=$reindexed"
  log "INFO" "pending sync completed: side=$SIDE mode=$MODE copied=$copied skipped=$skipped index_merged=$index_merged reindexed=$reindexed"
}

if [[ "$ACTION" == "cancel-pending" ]]; then
  cancel_pending_sync
  exit 0
fi

echo "$(date -Iseconds) [sync-start] action=$ACTION side=$SIDE mode=$MODE source=$SOURCE_HOME target=$TARGET_HOME" >> "$LOG_FILE"

if [[ ! -d "$SOURCE_HOME" ]]; then
  echo "Source home not found: $SOURCE_HOME" >&2
  log "ERROR" "source home missing: $SOURCE_HOME"
  exit 2
fi

mkdir -p "$TARGET_HOME"
if [[ ! -d "$TARGET_HOME" ]]; then
  echo "Target home not found and could not be created: $TARGET_HOME" >&2
  log "ERROR" "target home missing and could not create: $TARGET_HOME"
  exit 2
fi

if ! require_matching_codex_versions; then
  emit_stop_continue
  exit 0
fi

if [[ "$ACTION" == "run-pending" ]]; then
  run_pending_sync
  exit 0
fi

if ! acquire_sync_lock; then
  if schedule_pending_sync; then
    log "INFO" "sync skipped: lock contention; debounced pending sync for side=$SIDE"
  else
    log "WARN" "sync skipped: lock contention and pending sync could not be scheduled for side=$SIDE"
  fi
  emit_status "sync skipped: lock contention (debounced ${SYNC_DEBOUNCE_SECONDS}s)"
  emit_stop_continue
  exit 0
fi

rm -f "$SIDE_PENDING_FILE" 2>/dev/null || true
run_result="$(run_sync_pass)"
read -r copied skipped index_merged reindexed <<<"$run_result"

emit_status "sync completed: side=$SIDE mode=$MODE copied=$copied skipped=$skipped index_merged=$index_merged reindexed=$reindexed"
echo "$(date -Iseconds) [sync-end] side=$SIDE mode=$MODE copied=$copied skipped=$skipped index_merged=$index_merged reindexed=$reindexed" >> "$LOG_FILE"
emit_stop_continue
exit 0
