@echo off

:: ============================================================================
:: JW Countdown
:: ============================================================================
::
:: Author      : 1Dkvr
:: Licensor    : Hold'inCorp.
:: Created     : 19.09.01
:: Description : Starts the JW Countdown launcher and update manager.
:: File        : JwCountdown.bat
:: Runtime     : Windows PowerShell 5.1+
:: Platform    : Microsoft Windows
:: License     : Custom Non-Commercial Source-Available
:: License URL : https://github.com/1Dkvr/jw/blob/main/LICENSE.md
::
:: Copyright © 2019-2027 [Licensor]. All rights reserved.
::
:: This source code is subject to the terms and conditions defined in the 'LICENSE.md' file located in the root directory of this repository or online at at the URL above.
::
:: ============================================================================

START "" /B powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0JwCountdownLauncher.ps1"

exit /b
