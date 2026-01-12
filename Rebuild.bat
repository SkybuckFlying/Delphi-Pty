@echo off
setlocal enabledelayedexpansion

:: 1. Clear the screen and set a title
cls
title Node.js Build Script

echo ===========================================
echo   Cleaning and Rebuilding Project
echo ===========================================

:: 2. Check if build directory exists before trying to delete
if exist "build" (
    echo # Removing old build artifacts...
    rmdir /s /q build
    if !errorlevel! neq 0 (
        echo [ERROR] Failed to remove build directory. It might be in use.
        pause
        exit /b 1
    )
) else (
    echo # No old build directory found. Skipping clean.
)

:: 3. Verify Node version (Optional but helpful for "Node 22" target)
echo # Checking Node.js version...
node -v | findstr /i "v22" >nul
if %errorlevel% neq 0 (
    echo [WARNING] You are not running Node 22. Current version:
    node -v
)

:: 4. Run npm install with error handling
echo # Installing dependencies...
call npm install
if %errorlevel% neq 0 (
    echo [ERROR] npm install failed.
    pause
    exit /b %errorlevel%
)

echo.
echo ===========================================
echo   Build completed successfully!
echo ===========================================
pause