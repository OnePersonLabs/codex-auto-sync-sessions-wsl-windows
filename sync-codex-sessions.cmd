@echo off
setlocal EnableExtensions

set "WSL=%WINDIR%\System32\wsl.exe"
if not exist "%WSL%" (
  exit /b 0
)

rem Runtime SQLite databases stay local to each Codex install. The WSL sync
rem script atomically copies session files, merges session_index.jsonl, and
rem reindexes only the destination DB's missing local thread rows. Sync exits
rem quietly unless --debug is passed when Windows and WSL Codex versions differ.

if "%~1"=="--stop-hook" (
  %WSL% -e bash -lc "windows_home=\"$1\"; shift; exec \"$HOME/.codex/hooks/sync-codex-sessions.sh\" \"$@\" --windows-home \"$windows_home\"" _ "%USERPROFILE%\.codex" %*
) else if "%~1"=="" (
  %WSL% -e bash -lc "windows_home=\"$1\"; shift; exec \"$HOME/.codex/hooks/sync-codex-sessions.sh\" --to-wsl --side windows --windows-home \"$windows_home\"" _ "%USERPROFILE%\.codex"
) else (
  %WSL% -e bash -lc "windows_home=\"$1\"; shift; exec \"$HOME/.codex/hooks/sync-codex-sessions.sh\" \"$@\" --windows-home \"$windows_home\"" _ "%USERPROFILE%\.codex" %*
)

exit /b 0
