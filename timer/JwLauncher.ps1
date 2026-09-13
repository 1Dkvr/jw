<#
.SYNOPSIS
    JW Timer Launcher - Application launcher and update manager.

.DESCRIPTION
    JwLauncher.ps1 is the official entry point for JW Timer.

    Its responsibilities are deliberately separated from the main application
    contained in JwTimer.ps1.

    The launcher:

        1. Determines the local JW Timer version.
        2. Queries the configured GitHub repository for its latest published
           release.
        3. Compares the local version with the latest available version.
        4. Notifies the user when a newer version is available.
        5. Asks the user whether they want to update.
        6. Starts JwTimer.ps1.

    IMPORTANT:
    The current implementation only detects and proposes updates.
    It does not automatically download or replace application files.

    This separation is intentional. A future update engine can be introduced
    here without modifying the core JwTimer.ps1 application.

    The launcher is designed to remain compatible with the current
    PowerShell implementation and to provide a clean migration path toward
    a future WPF / executable version of JW Timer.

.NOTES
    Product      : JW Timer
    Component    : JwLauncher
    Version      : 26.09.12
    Developer    : 1Dkvr
    Platform     : Microsoft Windows
    Runtime      : Windows PowerShell 5.1+
    Dependencies : System.Windows.Forms
    License      : Proprietary

    Copyright © 2026 1Dkvr. All rights reserved.

    This software and its source code are proprietary and protected by
    applicable intellectual property laws.

    Unauthorized copying, modification, distribution, publication,
    sublicensing or commercial use is prohibited without prior
    authorization from the copyright holder.

    GitHub API:
        https://api.github.com

    The launcher uses the GitHub Releases API to determine the latest
    published stable release.

    Security:
        The launcher does not execute remote code.
        The current update mechanism only retrieves release metadata.
        Automatic downloading and replacement are intentionally disabled
        until a dedicated update mechanism with integrity verification
        is implemented.

.LINK
    https://docs.github.com/en/rest/releases/releases
#>

# ============================================================================
# JW TIMER LAUNCHER
# ============================================================================
Set-StrictMode -Version Latest

# ============================================================================
# APPLICATION CONFIGURATION
# ============================================================================
$script:AppName = "JW Timer"

# ---------------------------------------------------------------------------
# Local launcher version.
#
# This version identifies the launcher itself.
# It currently follows the same version as the JW Timer application.
#
# Format:
#     Major.Minor.Patch
#
# Current version intentionally preserved:
#     26.09.01
# ---------------------------------------------------------------------------
$script:Version = "26.09.01"

# ---------------------------------------------------------------------------
# Developer / copyright information.
# ---------------------------------------------------------------------------
$script:Developer = "1Dkvr"

# ============================================================================
# GITHUB CONFIGURATION
# ============================================================================
# ---------------------------------------------------------------------------
# GitHub repository owner.
#
# Replace this value with the GitHub account or organization that owns the
# JW Timer repository.
#
# Example:
#     1Dkvr
# ---------------------------------------------------------------------------
$script:GitHubOwner = "YOUR_GITHUB_OWNER"

# ---------------------------------------------------------------------------
# GitHub repository name.
#
# Replace this value with the exact name of the JW Timer repository.
#
# Example:
#     JwTimer
# ---------------------------------------------------------------------------
$script:GitHubRepository = "YOUR_GITHUB_REPOSITORY"

# ---------------------------------------------------------------------------
# GitHub API endpoint.
#
# /releases/latest returns the latest published stable release:
#
#     - draft releases are excluded;
#     - pre-releases are excluded;
#     - the latest published release is returned.
# ---------------------------------------------------------------------------
$script:GitHubLatestReleaseUrl = "https://api.github.com/repos/$($script:GitHubOwner)/$($script:GitHubRepository)/releases/latest"

# ============================================================================
# APPLICATION FILE CONFIGURATION
# ============================================================================
# ---------------------------------------------------------------------------
# Main JW Timer application.
#
# JwLauncher.ps1 is responsible for launching this file after performing
# its checks.
# ---------------------------------------------------------------------------
$script:ApplicationFileName = "JwTimer.ps1"

# ---------------------------------------------------------------------------
# Update-check timeout.
#
# The launcher must never prevent the application from starting indefinitely
# because GitHub cannot be reached.
# ---------------------------------------------------------------------------
$script:UpdateCheckTimeoutSeconds = 5

# ============================================================================
# USER INTERFACE CONFIGURATION
# ============================================================================
# ---------------------------------------------------------------------------
# MessageBox title.
# ---------------------------------------------------------------------------
$script:MessageBoxTitle = "$($script:AppName) - Update"

# ============================================================================
# REQUIRED .NET ASSEMBLIES
# ============================================================================

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
} catch {
    # If Windows Forms cannot be loaded, the launcher cannot display its
    # graphical notifications. The application itself may still be launched
    # directly as a fallback.
}

# ============================================================================
# LOGGING
# ============================================================================
function Write-JWLauncherLog {
    <#
    .SYNOPSIS
        Writes a diagnostic message to the PowerShell debug stream.

    .DESCRIPTION
        The launcher deliberately avoids creating persistent log files at
        this stage. This prevents unnecessary files from being created in
        the user's JW Timer directory.

        Debug messages are useful during development and troubleshooting,
        while remaining invisible during normal execution.

    .PARAMETER Message
        Diagnostic message to write.

    .PARAMETER ErrorRecord
        Optional PowerShell error record associated with the message.

    .OUTPUTS
        None.
    #>

    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if($null -ne $ErrorRecord){
        Write-Debug "[JW Launcher] $Message | $($ErrorRecord.Exception.Message)"
    } else {
        Write-Debug "[JW Launcher] $Message"
    }
}

# ============================================================================
# VERSION MANAGEMENT
# ============================================================================
function ConvertTo-JWVersion {
    <#
    .SYNOPSIS
        Converts a JW Timer version string into a System.Version object.

    .DESCRIPTION
        JW Timer uses a three-component version format:

            Major.Minor.Patch

        Examples:

            26.09.12
            26.10.00
            27.00.00

        GitHub release tags may optionally contain a leading "v":

            v26.09.12

        The leading "v" is removed before conversion.

        Invalid version values result in $null instead of terminating the
        launcher.

    .PARAMETER VersionString
        Version string to convert.

    .OUTPUTS
        System.Version
        or
        $null
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

        # GitHub releases commonly use tags such as "v26.09.12".
        if($normalizedVersion.StartsWith("v", [System.StringComparison]::OrdinalIgnoreCase)){
            $normalizedVersion = $normalizedVersion.Substring(1)
        }

        # Remove a possible surrounding whitespace after normalization.
        $normalizedVersion = $normalizedVersion.Trim()

        $parsedVersion = New-Object System.Version

        if(-not [System.Version]::TryParse(
            $normalizedVersion,
            [ref]$parsedVersion
        )){
            return $null
        }

        return $parsedVersion
    } catch {
        Write-JWLauncherLog -Message "Unable to parse version '$VersionString'." -ErrorRecord $_
        return $null
    }
}

function Compare-JWVersions {
    <#
    .SYNOPSIS
        Compares two JW Timer version numbers.

    .DESCRIPTION
        Returns:

            -1  if VersionA is older than VersionB
             0  if VersionA equals VersionB
             1  if VersionA is newer than VersionB

        The comparison is performed numerically using System.Version rather
        than lexicographically.

        This is important because a string comparison could incorrectly
        consider values such as "26.9.00" and "26.10.00".

    .PARAMETER VersionA
        First version.

    .PARAMETER VersionB
        Second version.

    .OUTPUTS
        Int32
    #>

    param(
        [Parameter(Mandatory = $true)]
        [string]$VersionA,

        [Parameter(Mandatory = $true)]
        [string]$VersionB
    )

    $parsedA = ConvertTo-JWVersion -VersionString $VersionA
    $parsedB = ConvertTo-JWVersion -VersionString $VersionB

    if($null -eq $parsedA){
        throw "Invalid local version: '$VersionA'."
    }

    if($null -eq $parsedB){
        throw "Invalid remote version: '$VersionB'."
    }

    return $parsedA.CompareTo($parsedB)
}

# ============================================================================
# GITHUB RELEASE MANAGEMENT
# ============================================================================
function Get-JWLatestGitHubRelease {
    <#
    .SYNOPSIS
        Retrieves the latest stable JW Timer release from GitHub.

    .DESCRIPTION
        Calls the GitHub Releases API endpoint configured in
        $script:GitHubLatestReleaseUrl.

        The function retrieves release metadata only.

        No remote code is downloaded or executed.

        If GitHub is unavailable, the repository configuration is invalid,
        the API request fails, or the returned data is invalid, the function
        returns $null.

    .OUTPUTS
        PSCustomObject
        or
        $null
    #>

    try {
        # -------------------------------------------------------------------
        # Do not attempt an API request until the repository has been
        # configured.
        # -------------------------------------------------------------------
        if(
            [string]::IsNullOrWhiteSpace($script:GitHubOwner) -or
            [string]::IsNullOrWhiteSpace($script:GitHubRepository) -or
            $script:GitHubOwner -eq "YOUR_GITHUB_OWNER" -or
            $script:GitHubRepository -eq "YOUR_GITHUB_REPOSITORY"
        ){
            Write-JWLauncherLog -Message "GitHub repository is not configured. Update check skipped."
            return $null
        }

        # -------------------------------------------------------------------
        # GitHub expects a User-Agent header for API requests.
        # -------------------------------------------------------------------
        $headers = @{
            "User-Agent" = "$($script:AppName)-Launcher/$($script:Version)"
            "Accept"     = "application/vnd.github+json"
        }

        Write-JWLauncherLog -Message "Checking latest GitHub release: $($script:GitHubLatestReleaseUrl)"

        # -------------------------------------------------------------------
        # Invoke the GitHub API.
        #
        # Windows PowerShell 5.1 supports Invoke-RestMethod and the
        # TimeoutSec parameter.
        # -------------------------------------------------------------------
        $release = Invoke-RestMethod `
            -Uri $script:GitHubLatestReleaseUrl `
            -Method Get `
            -Headers $headers `
            -TimeoutSec $script:UpdateCheckTimeoutSeconds `
            -ErrorAction Stop

        if($null -eq $release){
            Write-JWLauncherLog -Message "GitHub returned an empty release response."
            return $null
        }

        # -------------------------------------------------------------------
        # A valid GitHub release must contain a tag_name.
        # -------------------------------------------------------------------
        if([string]::IsNullOrWhiteSpace($release.tag_name)){
            Write-JWLauncherLog -Message "GitHub release response does not contain tag_name."
            return $null
        }
        $remoteVersion = ConvertTo-JWVersion -VersionString $release.tag_name
        if($null -eq $remoteVersion){
            Write-JWLauncherLog -Message "GitHub release tag '$($release.tag_name)' is not a valid JW Timer version."
            return $null
        }

        # -------------------------------------------------------------------
        # Return only the information the launcher actually needs.
        #
        # Keeping a small internal object makes the rest of the launcher
        # independent from the exact GitHub API response structure.
        # -------------------------------------------------------------------
        return [PSCustomObject]@{
            Version     = $remoteVersion.ToString()
            TagName     = [string]$release.tag_name
            Name        = [string]$release.name
            PublishedAt = $release.published_at
            HtmlUrl     = [string]$release.html_url
        }
    }
    catch {
        # -------------------------------------------------------------------
        # An update check must never prevent JW Timer from starting.
        #
        # Network errors, GitHub outages, DNS failures, timeouts, API errors
        # or invalid responses therefore result in a silent fallback to the
        # locally installed version.
        # -------------------------------------------------------------------
        Write-JWLauncherLog -Message "GitHub update check failed." -ErrorRecord $_
        return $null
    }
}

# ============================================================================
# UPDATE NOTIFICATION
# ============================================================================
function Show-JWUpdateNotification {
    <#
    .SYNOPSIS
        Displays an update notification to the user.

    .DESCRIPTION
        Informs the user that a newer JW Timer release is available.

        The current implementation does not install the update.

        Selecting "Yes" opens the official GitHub release page so the user
        can review the release manually.

        Selecting "No" continues directly to JW Timer.

    .PARAMETER Release
        Latest GitHub release object returned by Get-JWLatestGitHubRelease.

    .OUTPUTS
        None.
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
        Write-JWLauncherLog -Message "Unable to display or process the update notification." -ErrorRecord $_
    }
}

# ============================================================================
# APPLICATION LAUNCH
# ============================================================================
function Start-JWTimerApplication {
    <#
    .SYNOPSIS
        Starts the main JW Timer application.

    .DESCRIPTION
        Resolves JwTimer.ps1 relative to the launcher directory and starts it
        using Windows PowerShell.

        The launcher uses the same PowerShell executable that invoked it when
        possible.

        This keeps the launcher compatible with the current PowerShell-based
        application.

    .OUTPUTS
        None.
    #>

    try {
        # -------------------------------------------------------------------
        # Resolve the directory containing this launcher.
        # -------------------------------------------------------------------
        $launcherDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
        if([string]::IsNullOrWhiteSpace($launcherDirectory)){
            throw "Unable to determine the launcher directory."
        }

        # -------------------------------------------------------------------
        # Construct the absolute path of JwTimer.ps1.
        # -------------------------------------------------------------------
        $applicationPath = Join-Path -Path $launcherDirectory -ChildPath $script:ApplicationFileName

        # -------------------------------------------------------------------
        # Verify that the application actually exists before launching it.
        # -------------------------------------------------------------------
        if(-not (Test-Path -LiteralPath $applicationPath -PathType Leaf)){
            throw "JW Timer application not found: '$applicationPath'."
        }
        Write-JWLauncherLog -Message "Starting JW Timer application: $applicationPath"

        # -------------------------------------------------------------------
        # Explicitly invoke Windows PowerShell.
        #
        # -NoProfile:
        #     Prevents user PowerShell profiles from changing application
        #     behavior.
        #
        # -ExecutionPolicy Bypass:
        #     Preserves the current launcher behavior and allows the local
        #     application script to execute.
        #
        # -WindowStyle Hidden:
        #     Prevents a PowerShell console window from being displayed.
        #
        # The actual JW Timer script is responsible for its own application
        # lifetime.
        # -------------------------------------------------------------------
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
        Write-JWLauncherLog -Message "Unable to start JW Timer." -ErrorRecord $_
        try {
            [System.Windows.Forms.MessageBox]::Show(
                "JW Timer could not be started.`r`n`r`n$($_.Exception.Message)",
                $script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        } catch {
            # Nothing else can safely be done if the graphical notification
            # itself is unavailable.
        }
        exit 1
    }
}

# ============================================================================
# MAIN LAUNCHER WORKFLOW
# ============================================================================
function Start-JWLauncher {
    <#
    .SYNOPSIS
        Executes the complete JW Timer launcher workflow.

    .DESCRIPTION
        This function is intentionally small and orchestration-oriented.

        The launcher follows this sequence:

            1. Validate the local version.
            2. Check GitHub for the latest stable release.
            3. Compare versions.
            4. Notify the user when an update exists.
            5. Start JwTimer.ps1.

        A failed update check never prevents the application from starting.
    #>

    # -----------------------------------------------------------------------
    # Validate the local application version before doing anything else.
    # -----------------------------------------------------------------------
    $localVersion = ConvertTo-JWVersion -VersionString $script:Version
    if($null -eq $localVersion){
        throw "The configured local JW Timer version '$($script:Version)' is invalid."
    }
    Write-JWLauncherLog -Message "JW Timer Launcher version: $($script:Version)"

    # -----------------------------------------------------------------------
    # Check GitHub.
    # -----------------------------------------------------------------------
    $latestRelease = Get-JWLatestGitHubRelease

    # -----------------------------------------------------------------------
    # If GitHub cannot be reached, simply continue with the local version.
    # -----------------------------------------------------------------------
    if ($null -eq $latestRelease) {
        Write-JWLauncherLog -Message "No usable remote release information. Starting local application."
        Start-JWTimerApplication
        return
    }

    Write-JWLauncherLog -Message "Latest GitHub version: $($latestRelease.Version)"

    # -----------------------------------------------------------------------
    # Compare the local version with the remote version.
    # -----------------------------------------------------------------------
    $comparison = Compare-JWVersions -VersionA $script:Version -VersionB $latestRelease.Version

    # -----------------------------------------------------------------------
    # A negative result means the local version is older.
    # -----------------------------------------------------------------------
    if($comparison -lt 0){
        Write-JWLauncherLog -Message "A newer JW Timer version is available."
        Show-JWUpdateNotification -Release $latestRelease
    } elseif ($comparison -eq 0) {
        Write-JWLauncherLog -Message "JW Timer is up to date."
    } else {
        # -------------------------------------------------------------------
        # This situation can occur during development when the local version
        # is newer than the latest published GitHub release.
        # It is not an error.
        # -------------------------------------------------------------------
        Write-JWLauncherLog -Message "Local JW Timer version is newer than the latest GitHub release."
    }

    # -----------------------------------------------------------------------
    # Finally launch the actual application.
    # -----------------------------------------------------------------------
    Start-JWTimerApplication
}

# ============================================================================
# ENTRY POINT
# ============================================================================
try {
    Start-JWLauncher
}
catch {
    Write-JWLauncherLog -Message "Fatal launcher error." -ErrorRecord $_

    try {
        [System.Windows.Forms.MessageBox]::Show(
            "JW Timer Launcher encountered an unexpected error.`r`n`r`n$($_.Exception.Message)",
            $script:AppName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch {
        # No additional recovery is possible if the graphical notification
        # cannot be displayed.
    }

    exit 1
}
