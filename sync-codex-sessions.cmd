@echo off
setlocal EnableExtensions

set "WSL=%WINDIR%\System32\wsl.exe"
if not exist "%WSL%" (
  exit /b 0
)

if "%~1"=="" (
  %WSL% -e bash -lc "exec \"$HOME/.codex/hooks/sync-codex-sessions.sh\" --to-wsl --side windows --windows-home \"$1\"" _ "%USERPROFILE%\.codex" >> "%TEMP%\codex-session-sync.log" 2>&1
) else (
  %WSL% -e bash -lc "exec \"$HOME/.codex/hooks/sync-codex-sessions.sh\" \"$@\" --windows-home \"$1\"" _ %* "%USERPROFILE%\.codex" >> "%TEMP%\codex-session-sync.log" 2>&1
)

exit /b 0
