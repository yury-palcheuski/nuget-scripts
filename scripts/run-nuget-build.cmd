@echo off
cd /d "%~dp0"

set Version=5
REM powershell.exe -Version %Version% -Command "& {Set-ExecutionPolicy Unrestricted}"
REM powershell.exe -Version %Version% .\build-sln.ps1
powershell.exe -Version %Version% -Command "& {. .\nuget-commands.ps1; Build-MSBuild }"

set LastExitCode=%ErrorLevel%

pause

exit %LastExitCode%