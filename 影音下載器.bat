@echo off
rem ============================================================
rem  Portable Media Downloader - GUI launcher
rem  Starts tools\gui.ps1 (WinForms) with no visible console.
rem  ASCII-only on purpose: cmd.exe reads this file as ANSI.
rem ============================================================
start "" /B powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0tools\gui.ps1"
exit /b 0
