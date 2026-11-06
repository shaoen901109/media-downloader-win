@echo off
rem ============================================================
rem  Portable Media Downloader - login browser launcher
rem  Opens a dedicated Chrome/Edge window with its own profile
rem  (under LOCALAPPDATA, outside the project folder,
rem  so login sessions are never synced or committed) and a
rem  localhost-only debug port. Log in to Instagram / Facebook / X
rem  here; the downloader then exports cookies from this window
rem  (tools\browser.ps1 -Action export) while it stays open.
rem  Your normal Chrome profile is never touched.
rem  Optional: pass a URL, e.g.  login-browser.bat -Url https://www.instagram.com/
rem  ASCII-only on purpose: cmd.exe reads this file as ANSI.
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\browser.ps1" -Action open %* >nul
if errorlevel 1 (
    echo.
    echo [X] Login browser failed to start - see the message above.
    pause
    exit /b 1
)
exit /b 0