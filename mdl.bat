@echo off
rem ============================================================
rem  Command line / agent front-end. Forwards every argument
rem  to the Python engine at src\mdl.py .
rem  The GUI launcher does NOT need Python - this one does.
rem  ASCII-only on purpose: cmd.exe reads this file as ANSI.
rem ============================================================
setlocal

py -3 -c "import sys" >nul 2>&1
if %errorlevel% equ 0 goto use_py

python -c "import sys" >nul 2>&1
if %errorlevel% equ 0 goto use_python

echo [ERROR] Python 3 was not found on this computer.
echo.
echo   Install Python 3 from https://www.python.org/downloads/
echo   and tick "Add python.exe to PATH" during setup.
echo.
echo   Note: the graphical launcher in this folder does not need
echo   Python at all - only this command line front-end does.
exit /b 1

:use_py
set "PYCMD=py -3"
goto run

:use_python
set "PYCMD=python"
goto run

:run
if not exist "%~dp0src\mdl.py" (
    echo [ERROR] Engine not found: "%~dp0src\mdl.py"
    exit /b 1
)
%PYCMD% "%~dp0src\mdl.py" %*
exit /b %errorlevel%
