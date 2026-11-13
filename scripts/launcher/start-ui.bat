@echo off
rem Starts the IESA-Opt.jl browser UI. Paths come from this file's location, so the folder can be moved anywhere.
setlocal EnableExtensions DisableDelayedExpansion
title IESA-Opt.jl
for %%I in ("%~dp0..\..") do set "IESA_ROOT=%%~fI"
cd /d "%IESA_ROOT%"

set "JULIA_EXE="
if defined IESA_OPT_JULIA call :use "%IESA_OPT_JULIA%"
if not defined JULIA_EXE for %%J in (julia.exe) do set "JULIA_EXE=%%~$PATH:J"
if not defined JULIA_EXE call :use "%LOCALAPPDATA%\Microsoft\WindowsApps\julia.exe"
if not defined JULIA_EXE call :use "%USERPROFILE%\.juliaup\bin\julia.exe"
if not defined JULIA_EXE for /d %%D in ("%LOCALAPPDATA%\Programs\Julia*" "%ProgramFiles%\Julia*") do call :use "%%~fD\bin\julia.exe"
if not defined JULIA_EXE goto :no_julia

set "JULIA_PROJECT=%IESA_ROOT%"
"%JULIA_EXE%" --startup-file=no --threads=auto "%IESA_ROOT%\scripts\launcher\start_ui.jl"
if errorlevel 1 goto :stopped
exit /b 0

:stopped
echo.
echo IESA-Opt UI stopped. If that was unexpected, read the messages above.
pause
exit /b 1

:no_julia
echo Julia was not found. Install Julia 1.10 or newer from https://julialang.org/install/
echo and then double-click "IESA-Opt UI.cmd" again.
pause
exit /b 1

:use
if exist "%~1" set "JULIA_EXE=%~1"
exit /b 0