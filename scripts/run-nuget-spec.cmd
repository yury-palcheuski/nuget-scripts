@echo off
cd /d "%~dp0"

set Version=5
REM powershell.exe -Version %Version% -Command "& {Set-ExecutionPolicy Unrestricted}"
powershell.exe -Version %Version% -Command "& {. .\nuget-commands.ps1; New-NuGetSpec}"

set LastExitCode=%ErrorLevel%

pause

exit %LastExitCode%