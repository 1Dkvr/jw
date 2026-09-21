<#
.SYNOPSIS
    Provides shared GitHub integration functions for JW projects.

.DESCRIPTION
    Provides reusable functions for communicating with the GitHub REST API.

    This component is responsible for:
    - Reading GitHub Releases.
    - Filtering Releases by JW project.
    - Determining the latest Release for a project.
    - Downloading Release assets.
    - Creating GitHub Releases.
    - Uploading Release assets.

    This component does not contain:
    - Build logic.
    - Installation logic.
    - Update policy.
    - Project-specific application logic.

    GitHub is treated as the authoritative source for published project Releases.

.NOTES
    Product      : JW Core
    Component    : GitHub integration
    Developer    : 1Dkvr
    Licensor     : Hold'inCorp.
    Platform     : Microsoft Windows
    Runtime      : Windows PowerShell 5.1+
    Dependencies : None
    License      : Custom Non-Commercial Source-Available
    License URL  : https://github.com/1Dkvr/jw/blob/main/LICENSE.md

    Copyright © 2019 Hold'inCorp. — All rights reserved.
    Developed by 1Dkvr.
    Licensed under the Custom Non-Commercial Source-Available License.
    See `LICENSE.md` for the full license terms.

    This source code is protected by applicable copyright and other intellectual property laws. Use, reproduction, modification and redistribution are subject to the terms and conditions defined in `LICENSE.md`.

    The copyright and license notices contained in this source code must not be removed, altered or obscured without authorization.
#>

Set-StrictMode -Version Latest

function Get-JwGitHubToken {
    <#
    .SYNOPSIS
        Returns the GitHub authentication token available to the current process.

    .DESCRIPTION
        Checks explicitly supplied tokens first, then standard GitHub Actions environment variables.

    .PARAMETER Token
        Optional GitHub authentication token.

    .OUTPUTS
        System.String
    #>

    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Token
    )

    if(-not [string]::IsNullOrWhiteSpace($Token)){ return $Token }

    if(-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)){ return $env:GITHUB_TOKEN }

    if(-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)){ return $env:GH_TOKEN }

    return $null
}

function Get-JwGitHubHeaders {
    <#
    .SYNOPSIS
        Builds standard headers for GitHub REST API requests.

    .PARAMETER Context
        Initialized JW project context.

    .PARAMETER Token
        Optional GitHub authentication token.

    .OUTPUTS
        System.Collections.Hashtable
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context,

        [Parameter()]
        [AllowNull()]
        [string]$Token
    )

    $headers = @{
        "Accept"               = "application/vnd.github+json"
        "User-Agent"           = "JW-Core"
        "X-GitHub-Api-Version" = [string]$Context.GlobalConfig.GitHub.ApiVersion
    }

    $githubToken = Get-JwGitHubToken -Token $Token

    if(-not [string]::IsNullOrWhiteSpace($githubToken)){
        $headers["Authorization"] = "Bearer $githubToken"
    }

    return $headers
}

function Invoke-JwGitHubRequest {
    <#
    .SYNOPSIS
        Executes an HTTP request against the GitHub REST API.

    .PARAMETER Context
        Initialized JW project context.

    .PARAMETER Method
        HTTP method.

    .PARAMETER Endpoint
        API endpoint relative to https://api.github.com.

    .PARAMETER Token
        Optional GitHub authentication token.

    .PARAMETER Body
        Optional request body.

    .OUTPUTS
        System.Object
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [ValidateSet(
            "GET",
            "POST",
            "PATCH",
            "PUT",
            "DELETE"
        )]
        [string]$Method,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Endpoint,

        [Parameter()]
        [AllowNull()]
        [string]$Token,

        [Parameter()]
        [AllowNull()]
        [hashtable]$Body
    )

    $uri = "https://api.github.com/$($Endpoint.TrimStart('/'))"
    $headers = Get-JwGitHubHeaders -Context $Context -Token $Token

    $requestParameters = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $headers
        ErrorAction = "Stop"
    }

    if($null -ne $Body){
        $requestParameters["ContentType"] = "application/json"
        $requestParameters["Body"] = ($Body | ConvertTo-Json -Depth 10)
    }

    try {
        return Invoke-RestMethod @requestParameters
    } catch {
        $statusCode = $null

        if($null -ne $_.Exception.Response){
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode
            } catch {
                $statusCode = $null
            }
        }

        if($null -ne $statusCode){
            throw "GitHub API request failed with HTTP $statusCode. $($_.Exception.Message)"
        }

        throw "GitHub API request failed. $($_.Exception.Message)"
    }
}

function Get-JwGitHubReleases {
    <#
    .SYNOPSIS
        Returns all published GitHub Releases for the repository.

    .DESCRIPTION
        Retrieves Releases page by page to avoid relying on the first 100
        repository Releases when several JW projects share the same repository.

    .PARAMETER Context
        Initialized JW project context.

    .PARAMETER Token
        Optional GitHub authentication token.

    .OUTPUTS
        System.Object[]
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context,

        [Parameter()]
        [AllowNull()]
        [string]$Token
    )

    $allReleases = New-Object System.Collections.Generic.List[object]
    $page = 1
    $perPage = 100

    do {
        $endpoint = "repos/$($Context.RepositoryOwner)/$($Context.Repository)/releases?per_page=$perPage&page=$page"

        $releases = @(Invoke-JwGitHubRequest `
            -Context $Context `
            -Method "GET" `
            -Endpoint $endpoint `
            -Token $Token)

        foreach($release in $releases){
            if(
                (-not [bool]$release.draft) -and
                (-not [bool]$release.prerelease)
            ){
                $allReleases.Add($release)
            }
        }

        $page++
    }
    while($releases.Count -eq $perPage)

    return $allReleases.ToArray()
}

function Get-JwGitHubProjectReleases {
    <#
    .SYNOPSIS
        Returns published GitHub Releases belonging to the current JW project.

    .DESCRIPTION
        JW project Release tags use the project directory name as their prefix.

        Example:

            countdown-26.09.1779420678123

        A project named "advanced-countdown" therefore uses:

            advanced-countdown-...

    .PARAMETER Context
        Initialized JW project context.

    .PARAMETER Token
        Optional GitHub authentication token.

    .OUTPUTS
        System.Object[]
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context,

        [Parameter()]
        [AllowNull()]
        [string]$Token
    )

    $projectPrefix = "$($Context.Project.ToLowerInvariant())-"
    $releases = Get-JwGitHubReleases -Context $Context -Token $Token

    $projectReleases = foreach($release in $releases){
        $tagName = [string]$release.tag_name

        if(-not $tagName.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)){ continue }

        $version = $tagName.Substring($projectPrefix.Length)

        if(-not (Test-JwVersion -Version $version)){ continue }

        $versionInfo = Get-JwVersionInfo -Version $version

        [pscustomobject]@{
            Release = $release
            Version = $versionInfo
        }
    }

    return @($projectReleases)
}

function Get-JwGitHubLatestProjectRelease {
    <#
    .SYNOPSIS
        Returns the latest published GitHub Release for the current JW project.

    .PARAMETER Context
        Initialized JW project context.

    .PARAMETER Token
        Optional GitHub authentication token.

    .OUTPUTS
        PSCustomObject
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context,

        [Parameter()]
        [AllowNull()]
        [string]$Token
    )

    $projectReleases = Get-JwGitHubProjectReleases -Context $Context -Token $Token

    if($projectReleases.Count -eq 0){ return $null }

    $latest = $null

    foreach($candidate in $projectReleases){
        if($null -eq $latest){
            $latest = $candidate
            continue
        }

        $comparison = Compare-JwVersions `
            -VersionA $candidate.Version.Version `
            -VersionB $latest.Version.Version

        if($comparison -gt 0){ $latest = $candidate }
    }

    return $latest
}

function Get-JwGitHubReleaseAsset {
    <#
    .SYNOPSIS
        Finds an asset by filename in a GitHub Release.

    .PARAMETER Release
        GitHub Release object.

    .PARAMETER AssetName
        Exact asset filename.

    .OUTPUTS
        System.Object
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Release,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AssetName
    )

    foreach($asset in @($Release.assets)){
        if([string]::Equals([string]$asset.name, $AssetName, [System.StringComparison]::OrdinalIgnoreCase)){ return $asset }
    }

    return $null
}

function Save-JwGitHubReleaseAsset {
    <#
    .SYNOPSIS
        Downloads a GitHub Release asset to a local file.

    .PARAMETER Context
        Initialized JW project context.

    .PARAMETER Asset
        GitHub Release asset object.

    .PARAMETER DestinationPath
        Local destination path.

    .PARAMETER Token
        Optional GitHub authentication token.

    .OUTPUTS
        System.String
        Returns the destination path.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Asset,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [Parameter()]
        [AllowNull()]
        [string]$Token
    )

    $destinationDirectory = Split-Path -Path $DestinationPath -Parent

    if(
        -not [string]::IsNullOrWhiteSpace($destinationDirectory) -and
        -not (Test-Path -LiteralPath $destinationDirectory -PathType Container)
    ){
        New-Item `
            -ItemType Directory `
            -Path $destinationDirectory `
            -Force `
            -ErrorAction Stop | Out-Null
    }

    $headers = Get-JwGitHubHeaders -Context $Context -Token $Token
    $headers["Accept"] = "application/octet-stream"

    try {
        Invoke-WebRequest `
            -Uri ([string]$Asset.url) `
            -Headers $headers `
            -Method GET `
            -OutFile $DestinationPath `
            -ErrorAction Stop | Out-Null
    } catch {
        throw "Unable to download GitHub Release asset '$($Asset.name)'. $($_.Exception.Message)"
    }

    return [System.IO.Path]::GetFullPath($DestinationPath)
}

function New-JwGitHubRelease {
    <#
    .SYNOPSIS
        Creates a published GitHub Release.

    .DESCRIPTION
        Creates a Release using a new or existing Git tag.

    .PARAMETER Context
        Initialized JW project context.

    .PARAMETER TagName
        Git tag associated with the Release.

    .PARAMETER TargetCommitish
        Commit SHA or branch used when the tag does not already exist.

    .PARAMETER Name
        Human-readable Release name.

    .PARAMETER Body
        Release description.

    .PARAMETER Token
        GitHub authentication token.

    .OUTPUTS
        System.Object
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TagName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetCommitish,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter()]
        [AllowNull()]
        [string]$Body = "",

        [Parameter()]
        [AllowNull()]
        [string]$Token
    )

    $requestBody = @{
        tag_name               = $TagName
        target_commitish       = $TargetCommitish
        name                   = $Name
        body                   = $Body
        draft                  = $false
        prerelease             = $false
        generate_release_notes = $true
        make_latest            = "true"
    }

    return Invoke-JwGitHubRequest `
        -Context $Context `
        -Method "POST" `
        -Endpoint "repos/$($Context.RepositoryOwner)/$($Context.Repository)/releases" `
        -Token $Token `
        -Body $requestBody
}

function Publish-JwGitHubReleaseAsset {
    <#
    .SYNOPSIS
        Uploads a local file to a GitHub Release.

    .PARAMETER Context
        Initialized JW project context.

    .PARAMETER Release
        GitHub Release object returned by the API.

    .PARAMETER FilePath
        Local file to upload.

    .PARAMETER Token
        GitHub authentication token.

    .OUTPUTS
        System.Object
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Release,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [Parameter()]
        [AllowNull()]
        [string]$Token
    )

    if(-not (Test-Path -LiteralPath $FilePath -PathType Leaf)){
        throw "Release asset file was not found: $FilePath"
    }

    $githubToken = Get-JwGitHubToken -Token $Token

    if([string]::IsNullOrWhiteSpace($githubToken)){
        throw "A GitHub authentication token is required to upload Release assets."
    }

    $headers = Get-JwGitHubHeaders -Context $Context -Token $githubToken

    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $escapedFileName = [System.Uri]::EscapeDataString($fileName)

    $uploadUrl = [string]$Release.upload_url
    $uploadUrl = $uploadUrl -replace '\{\?name,label\}$', ""

    $uploadUri = "$uploadUrl?name=$escapedFileName"

    $extension = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()

    switch($extension){
        ".zip"  { $contentType = "application/zip" }
        ".json" { $contentType = "application/json" }
        default { $contentType = "application/octet-stream" }
    }

    try {
        return Invoke-RestMethod `
            -Uri $uploadUri `
            -Method POST `
            -Headers $headers `
            -ContentType $contentType `
            -InFile $FilePath `
            -ErrorAction Stop
    } catch {
        throw "Unable to upload Release asset '$fileName'. $($_.Exception.Message)"
    }
}
