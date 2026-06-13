@echo off
setlocal
rem Set the console window title before anything else launches. The PS
rem script re-applies it (and re-applies once more after spawning Julia,
rem because juliaup's launcher sets its own title via SetConsoleTitle).
title IESA-Opt.jl
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%start-ui.ps1"
if errorlevel 1 pause