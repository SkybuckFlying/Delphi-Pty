@echo off
taskkill /f /im node.exe /t 2>nul
taskkill /f /im TestDll.exe /t 2>nul
taskkill /f /im MinimalPTY.exe /t 2>nul
timeout /t 1 /nobreak >nul

echo Building DelphiPty.dll...
dcc64 DelphiPty.dpr
if %ERRORLEVEL% NEQ 0 (
    echo Failed to build DelphiPty.dll
    exit /b %ERRORLEVEL%
)

echo Building TestDll.exe...
dcc64 TestDll.dpr
if %ERRORLEVEL% NEQ 0 (
    echo Failed to build TestDll.exe
    exit /b %ERRORLEVEL%
)

echo Build successful.
