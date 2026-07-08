# Codex Session Sync Specification

## Purpose

This package keeps the Windows Codex Desktop session store and the WSL Codex CLI session store synchronized without allowing hook-triggered sync jobs to collide, duplicate, or bounce unchanged files back and forth.

The intended installation paths are:

- WSL script: `~/.codex/hooks/sync-codex-sessions.sh`
- WSL reindex helper: `~/.codex/hooks/reindex-codex-sessions.mjs`
- Windows wrapper: `%USERPROFILE%/.codex/hooks/sync-codex-sessions.cmd`
- WSL hooks: `~/.codex/hooks.json`
- Windows hooks: `%USERPROFILE%/.codex/hooks.json`

## Hook Model

Each side owns one sync direction:

- WSL `Stop`: sync WSL Codex sessions to Windows.
- Windows `Stop`: sync Windows Codex sessions to WSL.

Each side also owns one cancellation hook:

- WSL `UserPromptSubmit`: cancel only the WSL-side pending debounced sync.
- Windows `UserPromptSubmit`: cancel only the Windows-side pending debounced sync.

The cancellation hook does not copy files. Its only job is to drop a pending debounce token when a stopped session is continued by a new prompt on that same side.

## Locking

All sync processes use one shared lock file:

`<Windows Codex home>/.codex-session-sync.lock`

The lock is acquired with `flock` on an open file descriptor. A sync process must acquire this lock before it scans sessions, stats files, sorts candidates, computes hashes, or copies anything.

The lock timeout defaults to 2 seconds:

`CODEX_SESSION_SYNC_LOCK_TIMEOUT_SECONDS=2`

If the lock cannot be acquired within the timeout, the process does not scan or copy files. It schedules or reuses a debounced pending sync for its side and exits successfully.

## Debounce

The debounce delay defaults to 60 seconds:

`CODEX_SESSION_SYNC_DEBOUNCE_SECONDS=60`

Pending syncs are side-specific:

- WSL pending token: `.codex-session-sync.lock.wsl.pending`
- Windows pending token: `.codex-session-sync.lock.windows.pending`

A pending file contains only an opaque token. It does not contain source paths, destination paths, file metadata, copied-file lists, session ids, or any decision about what to sync.

If another event tries to schedule a pending sync while one already exists for that side, no additional job is scheduled.

When the debounced runner wakes up, it checks that its token is still current. If the token was cancelled or replaced, it exits. If the token is current, it attempts to acquire the shared sync lock. If it cannot acquire the lock, it replaces the token with a fresh debounced pending sync and exits.

## Sync Decision Rules

A sync pass copies only these files from the source Codex home:

- `sessions/**/*`
- `archived_sessions/**/*`

After session files are copied, `session_index.jsonl` is merged by session id. The merged file keeps the entry with the newest `updated_at` for each id and is written through a temporary file plus atomic rename.

Runtime SQLite databases such as `state_5.sqlite`, `logs_*.sqlite`, and their WAL/SHM sidecars are never copied. They are owned by the local Codex install and may have version-specific migration metadata. After portable session files land, the target side reindexes missing `threads` rows inside its own local `state_5.sqlite`.

Candidate files are collected only after the shared lock is acquired.

Files are sorted newest to oldest by mtime, then largest to smallest by size, then by path. A file is copied when:

- destination is missing, or
- source mtime is newer than destination mtime, or
- source and destination have equal mtime and source is larger.

Session copies use `cp -p` into a temporary file in the destination directory, followed by atomic rename, so readers never observe a partial destination file.

## Anti-Bounce Stamps

To prevent unchanged imported files from bouncing back to their origin, each target Codex home records import stamps in:

`.codex-session-sync.imports.tsv`

Each stamp contains:

- source content hash
- source size
- relative path

Before copying a file back in the opposite direction, the sync checks whether the source side has an import stamp with the same hash, size, and relative path. If it does, the file is treated as an unchanged import from the peer and is skipped even if its mtime changed.

If the file content changes, the hash changes and the file is eligible to sync normally.

## Install and Uninstall

The package repository can be cloned anywhere accessible from WSL or Windows.

Entry points:

- WSL install: `./install.sh`
- WSL uninstall: `./uninstall.sh`
- Windows install: `install.cmd`
- Windows uninstall: `uninstall.cmd`

The Windows `.cmd` entry points call the WSL Bash scripts.

## Version and Path Safety

Before a sync pass touches files or databases, it compares the WSL and Windows `codex --version` values. If they differ, sync exits without copying or reindexing. The abort is quiet by default and only prints a reason when the script is run with `--debug`.

Normal status messages are also quiet by default and are written to the sync log. Pass `--debug` to print status to the terminal.

Each side stores native paths in its own SQLite rows:

- WSL rows use POSIX paths, such as `/home/...` or `/mnt/c/...`.
- Windows rows use Windows paths, such as `C:\...` or `\\wsl.localhost\...`.

The sync converts `rollout_path`, `cwd`, and `agent_path` metadata when it reindexes or repairs local rows. Runtime SQLite files themselves are still never copied between platforms.

Install behavior is idempotent:

- creates required hook directories
- updates installed script files
- removes previous `sync-codex-sessions` hook entries
- preserves unrelated hooks
- adds the managed `Stop` and `UserPromptSubmit` hooks

Uninstall behavior is idempotent:

- removes only `sync-codex-sessions` hook entries
- preserves unrelated hooks
- removes installed script files if present
- removes pending token files if present
- succeeds when already uninstalled

## Failure Behavior

Expected safe failures:

- If the shared lock is busy, sync backs off into one pending debounced job.
- If a pending token is cancelled before the runner wakes, the runner exits without syncing.
- If another pending token replaced the current token, the stale runner exits without syncing.
- If uninstall is run while uninstalled, it leaves hook files valid and reports success.
- If install is run while installed, scripts and hook entries are updated in place.

The sync deliberately does not delete sessions on either side. Missing destination files are copied from the source, but missing source files do not cause destination deletion.
