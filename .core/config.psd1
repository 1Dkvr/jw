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

    Copyright © 2019 Hold'inCorp. — All rights reserved.
    Developed by 1Dkvr.
    Licensed under the Custom Non-Commercial Source-Available License.
    See `LICENSE.md` for the full license terms.

    This source code is protected by applicable copyright and other intellectual property laws. Use, reproduction, modification and redistribution are subject to the terms and conditions defined in `LICENSE.md`.

    The copyright and license notices contained in this source code must not be removed, altered or obscured without authorization.
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
