@echo off
setlocal
cd /d D:\Prompts\monitoring-alerts

set "PY_CMD=python"
where py >nul 2>nul
if %errorlevel%==0 set "PY_CMD=py -3"

%PY_CMD% "D:\Prompts\monitoring-alerts\poll_alerts.py" --codex-command codex 1>>"D:\Prompts\monitoring-alerts\state\poller.log" 2>>"D:\Prompts\monitoring-alerts\state\poller.err.log"
endlocal
