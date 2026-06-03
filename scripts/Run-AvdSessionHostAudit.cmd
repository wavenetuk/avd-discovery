@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_PATH=%SCRIPT_DIR%Invoke-AvdSessionHostAudit.ps1"
set "LOG_PATH=%SCRIPT_DIR%Invoke-AvdSessionHostAudit.launch.log"

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" %* > "%LOG_PATH%" 2>&1
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
  echo.
  echo The audit failed.
  echo See: %LOG_PATH%
  echo.
  pause
)

exit /b %EXIT_CODE%