@echo off
setlocal
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-RemarkableMirror.ps1" %*
) else (
  pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-RemarkableMirror.ps1" %*
)
set "RMMIRROR_INSTALL_EXIT=%ERRORLEVEL%"
if not "%RMMIRROR_INSTALL_EXIT%"=="0" (
  echo.
  echo reMarkable Mirror installation did not finish.
  pause
)
exit /b %RMMIRROR_INSTALL_EXIT%
