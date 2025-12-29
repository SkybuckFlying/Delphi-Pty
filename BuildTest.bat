@echo off
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
