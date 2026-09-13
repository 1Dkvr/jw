<#
.SYNOPSIS
    JW Countdown Launcher - Application launcher and update manager.

.DESCRIPTION
    JwCountdownLauncher.ps1 is the official entry point for JW Countdown.

    Its responsibilities are deliberately separated from the main application
    contained in JwCountdown.ps1.

    The launcher:
        1. Determines the local JW Countdown version.
        2. Queries the configured GitHub repository for its latest release.
        3. Compares the local version with the latest available version.
        4. Notifies the user when a newer version is available.
        5. Opens the official release page when requested.
        6. Starts JwCountdown.ps1.

    The current implementation detects and proposes updates only.
    It does not automatically install or replace application files.

.NOTES
    Product      : JW Countdown
    Component    : JwCountdownLauncher
    Version      : 26.09.01
    Developer    : 1Dkvr
    Platform     : Microsoft Windows
    Runtime      : Windows PowerShell 5.1+
    Dependencies : System.Windows.Forms
    License      : Proprietary

    Copyright © 2026 1Dkvr. All rights reserved.

    This software and its source code are proprietary and protected by
    applicable intellectual property laws.

    Unauthorized copying, modification, distribution, publication,
    sublicensing or commercial use is prohibited without prior authorization
    from the copyright holder.

    Security:
        The Countdown launcher retrieves release metadata only.
        No remote code is executed by the update-check mechanism.
#>

Set-StrictMode -Version Latest

# ============================================================================
# 1. APPLICATION CONFIGURATION
# ============================================================================
$script:AppName = "JW Countdown"
$script:Version = "26.09.01"
$script:Developer = "1Dkvr"

# ============================================================================
# 2. GITHUB CONFIGURATION
# ============================================================================
$script:GitHubOwner = "1Dkvr"
$script:GitHubRepository = "jw"
$script:GitHubProject = "countdown"

#$script:GitHubLatestReleaseUrl = "https://api.github.com/repos/$($script:GitHubOwner)/$($script:GitHubRepository)/releases/latest"
$script:GitHubReleasesUrl = "https://api.github.com/repos/$($script:GitHubOwner)/$($script:GitHubRepository)/releases"

# ============================================================================
# 3. APPLICATION CONFIGURATION
# ============================================================================
$script:ApplicationFileName = "JwCountdown.ps1"

# The update check must never prevent the application from starting for an
# extended period when GitHub is unavailable.
$script:UpdateCheckTimeoutSeconds = 5

$script:MessageBoxTitle = "$($script:AppName) - Update"

# ============================================================================
# 4. REQUIRED .NET ASSEMBLIES
# ============================================================================
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
} catch {
    # The countdown launcher can still attempt to start the main application if
    # Windows Forms cannot be loaded.
}

# ============================================================================
# 5. DIAGNOSTIC LOGGING
# ============================================================================
function Write-JWCountdownLauncherLog {
    <#
    .SYNOPSIS
        Writes a diagnostic message to the PowerShell debug stream.

    .DESCRIPTION
        No persistent log file is created. Diagnostic information is written
        only to the debug stream so normal users do not receive extra files.
    #>

    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if($null -ne $ErrorRecord){
        Write-Debug "[JW Countdown Launcher] $Message | $($ErrorRecord.Exception.Message)"
    } else {
        Write-Debug "[JW Countdown Launcher] $Message"
    }
}

# ============================================================================
# 6. VERSION MANAGEMENT
# ============================================================================
function ConvertTo-JWCountdownVersion {
    <#
    .SYNOPSIS
        Converts a JW Countdown version string into System.Version.

    .DESCRIPTION
        Supported format:
            Major.Minor.Patch

        GitHub tags may optionally begin with "v".
        Invalid values return $null.
    #>

    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$VersionString
    )

    try {
        if([string]::IsNullOrWhiteSpace($VersionString)){
            return $null
        }

        $normalizedVersion = $VersionString.Trim()

        if($normalizedVersion.StartsWith("v", [System.StringComparison]::OrdinalIgnoreCase)){
            $normalizedVersion = $normalizedVersion.Substring(1).Trim()
        }

        $parsedVersion = New-Object System.Version

        if(-not [System.Version]::TryParse(
            $normalizedVersion,
            [ref]$parsedVersion
        )){
            return $null
        }

        return $parsedVersion
    } catch {
        Write-JWCountdownLauncherLog -Message "Unable to parse version '$VersionString'." -ErrorRecord $_

        return $null
    }
}

function Compare-JWCountdownVersions {
    <#
    .SYNOPSIS
        Compares two JW Countdown versions numerically.

    .DESCRIPTION
        Returns:
            -1 when VersionA is older than VersionB.
             0 when both versions are equal.
             1 when VersionA is newer than VersionB.
    #>

    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionA,

        [Parameter(Mandatory = $true)]
        [string]$VersionB
    )

    $parsedA = ConvertTo-JWCountdownVersion -VersionString $VersionA
    $parsedB = ConvertTo-JWCountdownVersion -VersionString $VersionB

    if($null -eq $parsedA){
        throw "Invalid local version: '$VersionA'."
    }

    if($null -eq $parsedB){
        throw "Invalid remote version: '$VersionB'."
    }

    return $parsedA.CompareTo($parsedB)
}

# ============================================================================
# 7. GITHUB RELEASE MANAGEMENT
# ============================================================================
function Get-JWCountdownLatestGitHubRelease {
    <#
    .SYNOPSIS
        Retrieves the latest published stable JW Countdown release.

    .DESCRIPTION
        Calls the GitHub Releases API.

        Only release metadata is retrieved. No remote application code is
        downloaded or executed.

        A failed request returns $null so that JW Countdown can still start
        normally from the local installation.
    #>
    try {
        if(
            [string]::IsNullOrWhiteSpace($script:GitHubOwner) -or
            [string]::IsNullOrWhiteSpace($script:GitHubRepository)
        ){
            Write-JWCountdownLauncherLog -Message "GitHub repository is not configured. Update check skipped."
            return $null
        }

        $headers = @{
            "User-Agent" = "$($script:AppName)-Launcher/$($script:Version)"
            "Accept" = "application/vnd.github+json"
        }

        Write-JWCountdownLauncherLog -Message "Checking GitHub releases: $($script:GitHubReleasesUrl)"

        # @() force le tableau : PS 5.1 "déballe" un JSON array d'un seul
        # élément en objet unique, ce qui casserait .Count sous Strict Mode.
        $releases = @(Invoke-RestMethod `
            -Uri $script:GitHubReleasesUrl `
            -Method Get `
            -Headers $headers `
            -TimeoutSec $script:UpdateCheckTimeoutSeconds `
            -ErrorAction Stop)

        if($releases.Count -eq 0){
            Write-JWCountdownLauncherLog -Message "GitHub returned no releases."
            return $null
        }

        $tagPrefix = "$($script:GitHubProject)-"
        $release = $releases | Where-Object { $_.tag_name -like "$tagPrefix*" } | Select-Object -First 1

        if($null -eq $release){
            Write-JWCountdownLauncherLog -Message "No GitHub release found for project '$($script:GitHubProject)'."
            return $null
        }

        $tagVersion = $release.tag_name.Substring($tagPrefix.Length)
        $remoteVersion = ConvertTo-JWCountdownVersion -VersionString $tagVersion

        if($null -eq $remoteVersion){
            Write-JWCountdownLauncherLog -Message "GitHub release tag '$($release.tag_name)' is not a valid version."
            return $null
        }

        return [PSCustomObject]@{
            Version = $remoteVersion.ToString()
            TagName = [string]$release.tag_name
            Name = [string]$release.name
            PublishedAt = $release.published_at
            HtmlUrl = [string]$release.html_url
        }
    } catch {
        Write-JWCountdownLauncherLog -Message "GitHub update check failed." -ErrorRecord $_
        return $null
    }
}

# ============================================================================
# 8. UPDATE NOTIFICATION
# ============================================================================
function Show-JWCountdownUpdateNotification {
    <#
    .SYNOPSIS
        Notifies the user when a newer release is available.

    .DESCRIPTION
        The current implementation opens the official GitHub release page
        after user confirmation.

        Automatic installation is intentionally not implemented yet.
    #>

    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Release
    )

    try {
        $message = @"
A new version of $($script:AppName) is available.

Current version:
$($script:Version)

Latest version:
$($Release.Version)

Would you like to view the new release?
"@

        $result = [System.Windows.Forms.MessageBox]::Show(
            $message,
            $script:MessageBoxTitle,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        if(
            $result -eq [System.Windows.Forms.DialogResult]::Yes -and
            -not [string]::IsNullOrWhiteSpace($Release.HtmlUrl)
        ){
            Start-Process -FilePath $Release.HtmlUrl -ErrorAction Stop
        }
    } catch {
        Write-JWCountdownLauncherLog -Message "Unable to display or process the update notification." -ErrorRecord $_
    }
}

# ============================================================================
# 9. MAIN APPLICATION LAUNCH
# ============================================================================
function Start-JWCountdownApplication {
    <#
    .SYNOPSIS
        Starts the main JW Countdown application.

    .DESCRIPTION
        Resolves JwTimer.ps1 relative to the launcher and starts it using
        Windows PowerShell with the same execution policy and hidden-window
        behavior as the existing launcher architecture.
    #>

    try {
        $launcherDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path

        if([string]::IsNullOrWhiteSpace($launcherDirectory)){
            throw "Unable to determine the launcher directory."
        }

        $applicationPath = Join-Path -Path $launcherDirectory -ChildPath $script:ApplicationFileName

        if(-not (Test-Path -LiteralPath $applicationPath -PathType Leaf)){
            throw "JW Countdown application not found: '$applicationPath'."
        }

        Write-JWCountdownLauncherLog -Message "Starting JW Countdown application: $applicationPath"

        Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList @(
                "-ExecutionPolicy",
                "Bypass",
                "-NoProfile",
                "-WindowStyle",
                "Hidden",
                "-File",
                "`"$applicationPath`""
            ) `
            -WorkingDirectory $launcherDirectory `
            -ErrorAction Stop
    } catch {
        Write-JWCountdownLauncherLog -Message "Unable to start JW Countdown." -ErrorRecord $_

        try {
            [System.Windows.Forms.MessageBox]::Show(
                "JW Countdown could not be started.`r`n`r`n$($_.Exception.Message)",
                $script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        } catch {
            # No graphical recovery is available.
        }
        exit 1
    }
}

# ============================================================================
# 10. MAIN LAUNCHER WORKFLOW
# ============================================================================
function Start-JWCountdownLauncher {
    <#
    .SYNOPSIS
        Executes the complete JW Countdown launcher workflow.

    .DESCRIPTION
        Workflow:
            1. Validate the local version.
            2. Check GitHub for the latest stable release.
            3. Compare local and remote versions.
            4. Notify the user if an update exists.
            5. Start the local JW Countdown application.

        A failed update check never prevents application startup.
    #>

    $localVersion = ConvertTo-JWCountdownVersion -VersionString $script:Version

    if($null -eq $localVersion){
        throw "The configured local JW Countdown version '$($script:Version)' is invalid."
    }

    Write-JWCountdownLauncherLog -Message "JW Countdown Launcher version: $($script:Version)"
    $latestRelease = Get-JWCountdownLatestGitHubRelease

    if($null -eq $latestRelease){
        Write-JWCountdownLauncherLog -Message "No usable remote release information. Starting local application."
        Start-JWCountdownApplication
        return
    }
    Write-JWCountdownLauncherLog -Message "Latest GitHub version: $($latestRelease.Version)"
    $comparison = Compare-JWCountdownVersions -VersionA $script:Version -VersionB $latestRelease.Version

    if($comparison -lt 0){
        Write-JWCountdownLauncherLog -Message "A newer JW Countdown version is available."
        Show-JWCountdownUpdateNotification  -Release $latestRelease
    } elseif($comparison -eq 0){
        Write-JWCountdownLauncherLog  -Message "JW Countdown is up to date."
    } else {
        Write-JWCountdownLauncherLog -Message "Local version is newer than the latest GitHub release."
    }

    Start-JWCountdownApplication
}

# ============================================================================
# 11. ENTRY POINT
# ============================================================================
try {
    Start-JWCountdownLauncher
} catch {
    Write-JWCountdownLauncherLog -Message "Fatal launcher error." -ErrorRecord $_
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "JW Countdown Launcher encountered an unexpected error.`r`n`r`n$($_.Exception.Message)",
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch {
        # No additional recovery is possible.
    }
    exit 1
}
