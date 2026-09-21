<#
.SYNOPSIS
    Provides shared JW versioning functions.

.DESCRIPTION
    Defines the versioning convention used by all JW projects and provides functions to generate, validate, parse and compare project versions.

    JW project versions follow this format:

        YY.MM.BUILD

    Example:

        26.09.1779420678123

    The BUILD component is a Unix timestamp expressed in milliseconds and is generated in UTC.

.NOTES
    Product      : JW Core
    Component    : Version management
    Developer    : 1Dkvr
    Licensor     : Hold'inCorp.
    Platform     : Microsoft Windows
    Runtime      : Windows PowerShell 5.1+
    Dependencies : None
    License      : Custom Non-Commercial Source-Available
    License URL  : https://github.com/1Dkvr/jw/blob/main/LICENSE.md

    Copyright © 2019-2026 Hold'inCorp. — All rights reserved.
    Developed by 1Dkvr.
    Licensed under the Custom Non-Commercial Source-Available License.
    See `LICENSE.md` for the full license terms.

    This source code is protected by applicable copyright and other intellectual property laws. Use, reproduction, modification and redistribution are subject to the terms and conditions defined in `LICENSE.md`.

    The copyright and license notices contained in this source code must not be removed, altered or obscured without authorization.
#>

Set-StrictMode -Version Latest

$script:JwVersionPattern = '^(?<Prefix>\d{2}\.\d{2})\.(?<Build>\d+)$'

function Get-JwUnixMilliseconds {
    <#
    .SYNOPSIS
        Returns the current UTC Unix timestamp in milliseconds.

    .OUTPUTS
        System.Int64
    #>

    [CmdletBinding()]
    param()

    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Test-JwVersion {
    <#
    .SYNOPSIS
        Validates a JW project version.

    .DESCRIPTION
        Validates versions using the JW versioning convention: YY.MM.BUILD

        BUILD must be a positive Unix timestamp expressed in milliseconds.

    .PARAMETER Version
        Version string to validate.

    .OUTPUTS
        System.Boolean
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Version
    )

    return $Version -match $script:JwVersionPattern
}

function Get-JwVersionInfo {
    <#
    .SYNOPSIS
        Parses a JW project version.

    .PARAMETER Version
        Version string using the JW versioning convention.

    .OUTPUTS
        PSCustomObject
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Version
    )

    if(-not (Test-JwVersion -Version $Version)){
        throw "Invalid JW version '$Version'. Expected format: YY.MM.BUILD"
    }

    $match = [System.Text.RegularExpressions.Regex]::Match($Version, $script:JwVersionPattern)

    [int64]$build = 0

    if(-not [Int64]::TryParse(
        $match.Groups["Build"].Value,
        [System.Globalization.NumberStyles]::Integer,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$build
    )){
        throw "The build identifier '$($match.Groups["Build"].Value)' is not a valid Int64 value."
    }

    return [pscustomobject]@{
        Version       = $Version
        VersionPrefix = $match.Groups["Prefix"].Value
        Build         = $build
    }
}

function New-JwVersion {
    <#
    .SYNOPSIS
        Generates a new JW project version.

    .DESCRIPTION
        Combines a project version prefix in YY.MM format with a Unix timestamp
        expressed in milliseconds.

    .PARAMETER VersionPrefix
        Project version prefix.

        Example:
            26.09

    .PARAMETER Build
        Optional explicit build identifier.

        When omitted, the current UTC Unix timestamp in milliseconds is used.

    .OUTPUTS
        System.String
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^\d{2}\.\d{2}$')]
        [string]$VersionPrefix,

        [Parameter()]
        [ValidateRange(1, [Int64]::MaxValue)]
        [int64]$Build
    )

    if($PSBoundParameters.ContainsKey("Build")){
        $buildId = $Build
    }
    else {
        $buildId = Get-JwUnixMilliseconds
    }

    return "$VersionPrefix.$buildId"
}

function Compare-JwVersions {
    <#
    .SYNOPSIS
        Compares two JW project versions.

    .DESCRIPTION
        Returns:

            -1  Version A is older than Version B
             0  Versions are equal
             1  Version A is newer than Version B

        Comparison is performed first on the YY.MM prefix and then on the
        Unix-millisecond build identifier.

    .PARAMETER VersionA
        First JW version.

    .PARAMETER VersionB
        Second JW version.

    .OUTPUTS
        System.Int32
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VersionA,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VersionB
    )

    $parsedA = Get-JwVersionInfo -Version $VersionA
    $parsedB = Get-JwVersionInfo -Version $VersionB

    $prefixA = [version]$parsedA.VersionPrefix
    $prefixB = [version]$parsedB.VersionPrefix

    if($prefixA -lt $prefixB){
        return -1
    }

    if($prefixA -gt $prefixB){
        return 1
    }

    if($parsedA.Build -lt $parsedB.Build){
        return -1
    }

    if($parsedA.Build -gt $parsedB.Build){
        return 1
    }

    return 0
}
