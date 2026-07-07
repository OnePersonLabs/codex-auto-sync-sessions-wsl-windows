@echo off
setlocal EnableExtensions

set "WSL=%WINDIR%\System32\wsl.exe"
if not exist "%WSL%" (
  echo WSL was not found.
  exit /b 1
)

set "REPO_DIR_WIN=%~dp0"
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:REPO_DIR_WIN.TrimEnd('\'); if ($p -match '^\\\\wsl\$\\[^\\]+\\(?<rest>.*)$') { '/' + ($Matches.rest -replace '\\','/') } else { & $env:WINDIR\System32\wsl.exe -e wslpath -a $p }"`) do set "REPO_DIR_WSL=%%I"

if "%REPO_DIR_WSL%"=="" (
  echo Could not resolve repository path for WSL.
  exit /b 1
)

%WSL% -e bash "%REPO_DIR_WSL%/uninstall.sh" %*
exit /b %ERRORLEVEL%
