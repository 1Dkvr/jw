@echo off

:: ============================================================================
:: JW Countdown
:: ============================================================================
:: Application launcher
::
:: Author      : 1Dkvr
:: Copyright   : © 2026 1Dkvr
:: Version     : 1.0.0
:: Description : Launches the JwCountdown PowerShell application in the background.
:: File        : JwCountdown.bat
:: Runtime     : Windows PowerShell
:: Platform    : Microsoft Windows
::
:: ============================================================================
:: Copyright © 2026 1Dkvr. All rights reserved.
::
:: This software and its source code are protected by applicable intellectual
:: property laws. Unauthorized copying, modification, distribution or
:: commercial use is prohibited without prior authorization from the
:: copyright holder.
::
:: ============================================================================
:: Entry point
:: ============================================================================

START /B powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0JwCountdownLauncher.ps1"
