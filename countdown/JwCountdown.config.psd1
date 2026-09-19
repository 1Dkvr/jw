<#
.SYNOPSIS
    Shared configuration for JW Countdown.

.DESCRIPTION
    Defines the common project metadata and runtime configuration shared by JW Countdown application, launcher, updater and release tooling.

.NOTES
    Product      : JW Countdown
    Component    : Shared configuration
    Created      : 19.09.01
    Developer    : 1Dkvr
    Publisher    : Hold'inCorp.
    Platform     : Microsoft Windows
    Runtime      : Windows PowerShell 5.1+
    Dependencies : None
    License      : Custom Non-Commercial Source-Available
    License URL  : https://github.com/1Dkvr/jw/blob/main/LICENSE.md

    Copyright © 2026 [Publisher]. All rights reserved.

    This source code is subject to the terms and conditions defined in the 'LICENSE.md' file located in the root directory of this repository or online at the URL above.

    No external module or third-party dependency is required.

    Future release tooling may add package integrity and Authenticode signature verification without changing the countdown application itself.
#>

@{
    Project = @{
        Name      = "JW Countdown"
        Version   = "26.09.15"
        Developer = "1Dkvr"
        Publisher = "Hold'inCorp."
    }

    GitHub = @{
        Owner      = "1Dkvr"
        Repository = "jw"
        Project    = "countdown"
        ApiVersion = "2026-03-10"
    }

    Files = @{
        Config      = "JwCountdown.config.psd1"
        EntryPoint  = "JwCountdown.bat"
        Application = "JwCountdown.ps1"
        Launcher    = "JwCountdownLauncher.ps1"
        Updater     = "JwCountdownUpdater.ps1"
        Manifest    = "manifest.json"
    }

    Package = @{
        Prefix    = "JwCountdown"
        Extension = ".zip"
    }

    Runtime = @{
        ApplicationMutexName = "Local\JWCountdown.SingleTimer"
    }
}
