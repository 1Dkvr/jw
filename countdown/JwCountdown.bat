@echo off

:: ============================================================================
:: JW Countdown
:: ============================================================================
::
:: Author      : 1Dkvr
:: Copyright   : © 2026 1Dkvr. All rights reserved.
:: Created     : 26.09.01
:: Version     : 26.09.15
:: Description : Launches the JW Countdown launcher and update manager.
:: File        : JwCountdown.bat
:: Runtime     : Windows PowerShell 5.1+
:: Platform    : Microsoft Windows
:: License     : Proprietary
::
:: ============================================================================

START /B powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0JwCountdownLauncher.ps1"
