@echo off
title First-time setup - downloading yt-dlp.exe / ffmpeg.exe
rem ============================================================
rem  Downloads the portable tools into bin\ . Nothing is
rem  installed into Windows itself.
rem  ASCII-only on purpose: cmd.exe reads this file as ANSI.
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\setup.ps1"
echo.
pause
