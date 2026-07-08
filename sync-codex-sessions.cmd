@echo off
setlocal EnableExtensions

set "WSL=%WINDIR%\System32\wsl.exe"
if not exist "%WSL%" (
  exit /b 0
)

if "%~1"=="--stop-hook" (
  %WSL% -e bash -lc "windows_home=\"$1\"; shift; exec \"$HOME/.codex/hooks/sync-codex-sessions.sh\" \"$@\" --windows-home \"$windows_home\"" _ "%USERPROFILE%\.codex" %*
) else if "%~1"=="" (
  %WSL% -e bash -lc "windows_home=\"$1\"; shift; exec \"$HOME/.codex/hooks/sync-codex-sessions.sh\" --to-wsl --side windows --windows-home \"$windows_home\"" _ "%USERPROFILE%\.codex"
) else (
  %WSL% -e bash -lc "windows_home=\"$1\"; shift; exec \"$HOME/.codex/hooks/sync-codex-sessions.sh\" \"$@\" --windows-home \"$windows_home\"" _ "%USERPROFILE%\.codex" %*
)

exit /b 0
