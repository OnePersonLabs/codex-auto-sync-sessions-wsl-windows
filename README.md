# codex-auto-sync-sessions-wsl-windows

Portable script-based sync for Codex session files between Windows Codex Desktop and WSL Codex CLI.

Automatically sync sessions after 1 minute idle, debounced. Syncs both ways, so you can use the Codex app on windows and VS Code with wsl, and still be able to use the mobile app remote feature (which is broken if you run the desktop app in wsl natively).

The package installs:

- a WSL sync script at `~/.codex/hooks/sync-codex-sessions.sh`
- a Windows wrapper at `%USERPROFILE%\.codex\hooks\sync-codex-sessions.cmd`
- one `Stop` sync hook on each side
- one `UserPromptSubmit` pending-sync cancel hook on each side
- a local copy of [SPECIFICATION.md](./SPECIFICATION.md) into each Codex home

The sync uses one shared `flock` lock file in the Windows Codex home, side-specific pending debounce tokens, and import hash stamps to avoid bouncing unchanged imported files back to their source.

## Requirements

- Windows with WSL enabled
- Bash, `flock`, `sha256sum`, `awk`, and `python3` available in WSL
- Codex CLI/Desktop profiles at the default homes, or override paths with env vars

## Install

From WSL:

```bash
git clone <repo-url> ~/dev/sync-codex-sessions
cd ~/dev/sync-codex-sessions
./install.sh
```

From Windows:

```cmd
git clone <repo-url> %USERPROFILE%\dev\sync-codex-sessions
cd %USERPROFILE%\dev\sync-codex-sessions
install.cmd
```

Install is idempotent. Running it again updates installed scripts and replaces this package's managed hook entries without removing unrelated hooks.

## Uninstall

From WSL:

```bash
cd ~/dev/sync-codex-sessions
./uninstall.sh
```

From Windows:

```cmd
cd %USERPROFILE%\dev\sync-codex-sessions
uninstall.cmd
```

Uninstall is idempotent. Running it when already uninstalled succeeds, removes only this package's hook entries, and leaves unrelated hooks alone.

## Configuration

Optional environment overrides:

- `CODEX_HOME`: WSL Codex home, default `~/.codex`
- `CODEX_HOME_WINDOWS`: Windows Codex home as a WSL path
- `CODEX_HOME_WINDOWS_WIN`: Windows Codex home as a Windows path
- `CODEX_SESSION_SYNC_LOCK_FILE`: shared lock file
- `CODEX_SESSION_SYNC_LOCK_TIMEOUT_SECONDS`: lock acquisition timeout, default `2`
- `CODEX_SESSION_SYNC_DEBOUNCE_SECONDS`: pending sync debounce delay, default `60`

## Behavior

- WSL `Stop` syncs WSL to Windows.
- Windows `Stop` syncs Windows to WSL.
- Continuing a stopped session cancels only that side's pending debounced sync.
- Pending sync markers are side-specific and contain only opaque tokens.
- File discovery and copy decisions happen only after the shared lock is acquired.
- Unchanged imported files are skipped on the way back even if mtimes changed.

See [SPECIFICATION.md](./SPECIFICATION.md) for the full behavior contract.
