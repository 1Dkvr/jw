<#
.SYNOPSIS
    Shared repository configuration for the JW project collection.

.DESCRIPTION
    Defines metadata and conventions shared by all projects hosted in the JW repository.

.NOTES
    Developer    : 1Dkvr
    Licensor     : Hold'inCorp.
    Platform     : Microsoft Windows
    License      : Custom Non-Commercial Source-Available
    License URL  : https://github.com/1Dkvr/jw/blob/main/LICENSE.md

    Copyright © 2019 Hold'inCorp. All rights reserved.

    This source code is subject to the terms and conditions defined in the 'LICENSE.md' file located in the root directory of this repository or online at at the URL above.
#>

@{
    Copyright = @{
        StartYear = 2019
        Licensor  = "Hold'inCorp."
    }
    
    License = @{
        Name      = "Custom Non-Commercial Source-Available"
        File      = "LICENSE.md"
        Url       = "https://github.com/1Dkvr/jw/blob/main/LICENSE.md"
    }

    GitHub = @{
        Repository = "jw"
        Owner      = "1Dkvr"
        ApiVersion = "2026-03-10"
    }   
    
    Package = @{
        Extension = ".zip"
    }
}
