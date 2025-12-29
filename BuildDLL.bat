@echo off
taskkill /f /im node.exe /t 2>nul
taskkill /f /im TestDll.exe /t 2>nul
taskkill /f /im MinimalPTY.exe /t 2>nul
timeout /t 1 /nobreak >nul

echo Building DelphiPty.dll...
dcc64 DelphiPty.dpr