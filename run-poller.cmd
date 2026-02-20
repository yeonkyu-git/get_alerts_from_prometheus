@echo off
setlocal
cd /d D:\Prompts\monitoring-alerts
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\Prompts\monitoring-alerts\poll-alerts.ps1" -CodexCommand "c:\Users\???\.vscode\extensions\openai.chatgpt-0.4.76-win32-x64\bin\windows-x86_64\codex.exe" 1>>"D:\Prompts\monitoring-alerts\state\poller.log" 2>>"D:\Prompts\monitoring-alerts\state\poller.err.log"
endlocal
