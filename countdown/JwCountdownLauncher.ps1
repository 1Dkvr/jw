<#
.SYNOPSIS
    JW Countdown launcher and update manager.

.DESCRIPTION
    Starts JW Countdown and checks GitHub for a newer stable release.

    When an update is available, the launcher allows the user to review the release notes or install the update automatically.

    The launcher downloads and verifies the update package, then delegates the installation to JwCountdownUpdater.ps1 so that the launcher itself can also be replaced safely.

.NOTES
    Product      : JW Countdown
    Component    : Launcher and update manager
    Created      : 26.09.01
    Developer    : 1Dkvr
    Publisher    : Hold'inCorp.
    Platform     : Microsoft Windows
    Runtime      : Windows PowerShell 5.1+
    Dependencies : System.Windows.Forms, System.Drawing
    License      : Custom Non-Commercial Source-Available
    License URL  : https://github.com/1Dkvr/jw/blob/main/LICENSE.md

    Copyright © 2026 [Publisher]. All rights reserved.

    This source code is subject to the terms and conditions defined in the 'LICENSE.md' file located in the root directory of this repository or online at the URL above.

    No external module or third-party dependency is required.

    Future release tooling may add package integrity and Authenticode signature verification without changing the countdown application itself.
#>

Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$configPath = Join-Path $PSScriptRoot "JwCountdown.config.psd1"

if(-not (Test-Path -LiteralPath $configPath -PathType Leaf)){
    [System.Windows.Forms.MessageBox]::Show(
        "JW Countdown configuration file was not found.`r`n`r`n$configPath",
        "JW Countdown",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null

    exit 1
}

try {
    $script:Config = Import-PowerShellDataFile -LiteralPath $configPath -ErrorAction Stop
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "JW Countdown configuration could not be loaded.`r`n`r`n$($_.Exception.Message)",
        "JW Countdown",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null

    exit 1
}

$script:AppName       = $script:Config.Project.Name
$script:Version       = $script:Config.Project.Version
$script:Developer     = $script:Config.Project.Developer
$script:GitHubOwner   = $script:Config.GitHub.Owner
$script:GitHubRepo    = $script:Config.GitHub.Repository
$script:GitHubProject = $script:Config.GitHub.Project

$script:GitHubReleasesUrl         = "https://api.github.com/repos/$($script:GitHubOwner)/$($script:GitHubRepo)/releases"
$script:GitHubApiVersion          = "2026-03-10"
$script:UpdateCheckTimeoutSeconds = 5
$script:UpdateDownloadTimeoutSec  = 120
$script:UpdateWorkingDirectory    = Join-Path $env:TEMP "JWCountdownUpdate"
$script:MutexName                 = "Local\JWCountdown.SingleTimer"
$script:MessageBoxTitle           = "$($script:AppName) - Update"

function Show-JWMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [System.Windows.Forms.MessageBoxButtons]$Buttons = [System.Windows.Forms.MessageBoxButtons]::OK,

        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )

    return [System.Windows.Forms.MessageBox]::Show($Message, $script:MessageBoxTitle, $Buttons, $Icon)
}

function ConvertTo-JWCountdownVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $match = [regex]::Match($Value, '\d+(?:\.\d+){1,3}')

    if(-not $match.Success){ throw "Invalid version: $Value" }

    return [System.Version]::Parse($match.Value)
}

function Compare-JWCountdownVersions {
    param(
        [Parameter(Mandatory)]
        [string]$CurrentVersion,

        [Parameter(Mandatory)]
        [string]$LatestVersion
    )

    $current = ConvertTo-JWCountdownVersion $CurrentVersion
    $latest = ConvertTo-JWCountdownVersion $LatestVersion

    return $latest.CompareTo($current)
}

function Get-JWCountdownLatestGitHubRelease {
    $headers = @{
        Accept               = "application/vnd.github+json"
        "User-Agent"         = "$($script:AppName)-Launcher/$($script:Version)"
        "X-GitHub-Api-Version" = $script:GitHubApiVersion
    }

    try {
        $releases = @(
            Invoke-RestMethod `
                -Uri "$($script:GitHubReleasesUrl)?per_page=100" `
                -Method Get `
                -Headers $headers `
                -TimeoutSec $script:UpdateCheckTimeoutSeconds `
                -ErrorAction Stop
        )
    } catch {
        return $null
    }

    $tagPrefix = "$($script:GitHubProject)-"

    $candidates = @(
        $releases |
            Where-Object { -not $_.draft -and -not $_.prerelease -and $_.tag_name -like "$tagPrefix*"} |
            ForEach-Object {
                try {
                    [pscustomobject]@{
                        Release = $_
                        Version = ConvertTo-JWCountdownVersion $_.tag_name
                    }
                } catch {
                    $null
                }
            } | Where-Object { $_ -ne $null } | Sort-Object Version -Descending
    )

    if($candidates.Count -eq 0){ return $null }

    return $candidates[0].Release
}

function Get-JWCountdownUpdateAsset {
    param(
        [Parameter(Mandatory)]
        $Release
    )

    $assets = @($Release.assets | Where-Object { $_.state -eq "uploaded" -and $_.name -like "*.zip" })

    if($assets.Count -eq 0){ throw "No ZIP update package was found in the GitHub release." }
    if($assets.Count -eq 1){ return $assets[0] }

    $expectedPrefix = ($script:AppName -replace '\s+', '')

    $preferredAsset = $assets | Where-Object { $_.name -like "$expectedPrefix-*.zip" } | Select-Object -First 1

    if($preferredAsset){ return $preferredAsset }

    return $assets[0]
}

function Test-JWCountdownInstanceAvailable {
    $mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
    $acquired = $false

    try {
        try {
            $acquired = $mutex.WaitOne(0, $false)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        return $acquired
    } finally {
        if($acquired){
            try {
                $mutex.ReleaseMutex()
            } catch {
            }
        }
        $mutex.Dispose()
    }
}

function Start-JWCountdownApplication {
    $applicationFileName = $script:Config.Files.Application
    $applicationPath = Join-Path $PSScriptRoot $applicationFileName

    if(-not (Test-Path -LiteralPath $applicationPath -PathType Leaf)){
        Show-JWMessage `
            -Message "$applicationFileName was not found in the application directory." `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Error)

        return $false
    }

    try {
        Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList @(
                "-ExecutionPolicy", "Bypass",
                "-NoProfile",
                "-WindowStyle", "Hidden",
                "-File", "`"$applicationPath`""
            ) `
            -WorkingDirectory $PSScriptRoot `
            -ErrorAction Stop

        return $true
    } catch {
        Show-JWMessage `
            -Message "$($script:AppName) could not be started.`r`n`r`n$($_.Exception.Message)" `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Error)

        return $false
    }
}

function Show-JWCountdownUpdateDialog {
    param(
        [Parameter(Mandatory)]
        $Release,

        [Parameter(Mandatory)]
        [string]$LatestVersion
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$($script:AppName) - Update"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(460, 250)
    $form.MinimumSize = $form.Size
    $form.MaximumSize = $form.Size
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "A new version of $($script:AppName) is available."
    $titleLabel.Location = New-Object System.Drawing.Point(24, 22)
    $titleLabel.Size = New-Object System.Drawing.Size(400, 24)
    $titleLabel.Font = New-Object System.Drawing.Font("Arial", 11, [System.Drawing.FontStyle]::Bold)

    $versionLabel = New-Object System.Windows.Forms.Label
    $versionLabel.Text = "Current version: $($script:Version)`r`nLatest version:  $LatestVersion"
    $versionLabel.Location = New-Object System.Drawing.Point(24, 60)
    $versionLabel.Size = New-Object System.Drawing.Size(400, 48)
    $versionLabel.Font = New-Object System.Drawing.Font("Arial", 10)

    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Text = "The update will be downloaded and installed automatically."
    $infoLabel.Location = New-Object System.Drawing.Point(24, 114)
    $infoLabel.Size = New-Object System.Drawing.Size(400, 36)
    $infoLabel.Font = New-Object System.Drawing.Font("Arial", 9)

    $installButton = New-Object System.Windows.Forms.Button
    $installButton.Text = "INSTALL UPDATE"
    $installButton.Location = New-Object System.Drawing.Point(24, 172)
    $installButton.Size = New-Object System.Drawing.Size(125, 32)
    $installButton.DialogResult = [System.Windows.Forms.DialogResult]::Yes

    $releaseButton = New-Object System.Windows.Forms.Button
    $releaseButton.Text = "RELEASE NOTES"
    $releaseButton.Location = New-Object System.Drawing.Point(159, 172)
    $releaseButton.Size = New-Object System.Drawing.Size(125, 32)

    $laterButton = New-Object System.Windows.Forms.Button
    $laterButton.Text = "LATER"
    $laterButton.Location = New-Object System.Drawing.Point(294, 172)
    $laterButton.Size = New-Object System.Drawing.Size(125, 32)
    $laterButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $releaseButton.Add_Click({
        try {
            Start-Process $Release.html_url
        } catch {
        }
    })

    $form.Controls.AddRange(@(
        $titleLabel,
        $versionLabel,
        $infoLabel,
        $installButton,
        $releaseButton,
        $laterButton
    ))

    $form.AcceptButton = $installButton
    $form.CancelButton = $laterButton

    $result = $form.ShowDialog()
    $form.Dispose()

    if($result -eq [System.Windows.Forms.DialogResult]::Yes){ return "Install" }
    return "Later"
}

function Show-JWCountdownUpdateProgress {
    param(
        [Parameter(Mandatory)]
        [string]$LatestVersion
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$($script:AppName) - Updating"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(460, 165)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $false
    $form.ShowInTaskbar = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Downloading version $LatestVersion..."
    $label.Location = New-Object System.Drawing.Point(24, 22)
    $label.Size = New-Object System.Drawing.Size(400, 24)
    $label.Font = New-Object System.Drawing.Font("Arial", 10)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(24, 60)
    $progressBar.Size = New-Object System.Drawing.Size(400, 24)
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $progressBar.MarqueeAnimationSpeed = 25

    $form.Controls.AddRange(@($label, $progressBar))

    $form.Show()

    return $form
}

function Test-JWCountdownPackage {
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [string]$StageDirectory
    )

    $zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)

    try {
        $stageRoot = [System.IO.Path]::GetFullPath($StageDirectory).TrimEnd('\') + '\'

        foreach($entry in $zip.Entries){
            $fullPath = [System.IO.Path]::GetFullPath((Join-Path $StageDirectory $entry.FullName))
            if(-not $fullPath.StartsWith($stageRoot, [System.StringComparison]::OrdinalIgnoreCase)){
                throw "The update package contains an invalid path."
            }
        }
    } finally {
        $zip.Dispose()
    }

    Expand-Archive `
        -LiteralPath $PackagePath `
        -DestinationPath $StageDirectory `
        -Force

    $requiredFiles = @(
        $script:Config.Files.EntryPoint,
        $script:Config.Files.Application,
        $script:Config.Files.Launcher,
        $script:Config.Files.Updater,
        $script:Config.Files.Manifest
    )

    foreach($fileName in $requiredFiles){
        $file = Get-ChildItem `
            -LiteralPath $StageDirectory `
            -Filter $fileName `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if(-not $file){ throw "The downloaded package is missing: $fileName" }
    }
    return $true
}

function Start-JWCountdownUpdater {
    param(
        [Parameter(Mandatory)]
        [string]$StageDirectory,

        [Parameter(Mandatory)]
        [string]$LauncherProcessId
    )

    $updaterFileName = $script:Config.Files.Updater
    $updaterPath = Join-Path $PSScriptRoot $updaterFileName

    if(-not (Test-Path -LiteralPath $updaterPath -PathType Leaf)){
        throw "$updaterFileName was not found in the application directory."
    }

    try {
        Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList @(
                "-ExecutionPolicy", "Bypass",
                "-NoProfile",
                "-WindowStyle", "Hidden",
                "-File", "`"$updaterPath`"",
                "-StageDirectory", "`"$StageDirectory`"",
                "-InstallDirectory", "`"$PSScriptRoot`"",
                "-LauncherProcessId", $LauncherProcessId
            ) `
            -WorkingDirectory $PSScriptRoot `
            -ErrorAction Stop

        return $true
    } catch {
        throw "The updater could not be started: $($_.Exception.Message)"
    }
}

function Install-JWCountdownUpdate {
    param(
        [Parameter(Mandatory)]
        $Release,

        [Parameter(Mandatory)]
        [string]$LatestVersion
    )

    if(-not (Test-JWCountdownInstanceAvailable)){
        Show-JWMessage `
            -Message "$($script:AppName) is currently running.`r`n`r`nClose the current countdown before installing the update." `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning)

        return $false
    }

    $progressForm = $null
    $workingDirectory = $null

    try {
        $asset = Get-JWCountdownUpdateAsset -Release $Release

        if([string]::IsNullOrWhiteSpace($asset.digest) -or $asset.digest -notlike "sha256:*"){
            throw "The GitHub release does not provide a SHA-256 digest for the update package."
        }

        $workingId = [guid]::NewGuid().ToString("N")
        $workingDirectory = Join-Path $script:UpdateWorkingDirectory $workingId

        $packagePath = Join-Path $workingDirectory $asset.name
        $stageDirectory = Join-Path $workingDirectory "stage"

        New-Item `
            -ItemType Directory `
            -Path $stageDirectory `
            -Force `
            -ErrorAction Stop | Out-Null

        $progressForm = Show-JWCountdownUpdateProgress -LatestVersion $LatestVersion

        $headers = @{
            Accept       = "application/octet-stream"
            "User-Agent" = "$($script:AppName)-Launcher/$($script:Version)"
        }

        Invoke-WebRequest `
            -Uri $asset.browser_download_url `
            -Headers $headers `
            -OutFile $packagePath `
            -TimeoutSec $script:UpdateDownloadTimeoutSec `
            -UseBasicParsing `
            -ErrorAction Stop

        $expectedHash = $asset.digest.Substring(7).ToLowerInvariant()
        $actualHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()

        if($actualHash -ne $expectedHash){
            throw "The downloaded package failed SHA-256 verification."
        }

        Test-JWCountdownPackage -PackagePath $packagePath -StageDirectory $stageDirectory | Out-Null

        if($progressForm){
            $progressForm.Close()
            $progressForm.Dispose()
            $progressForm = $null
        }

        Start-JWCountdownUpdater -StageDirectory $stageDirectory -LauncherProcessId $PID | Out-Null

        return $true
    }
    catch {
        if($progressForm){
            $progressForm.Close()
            $progressForm.Dispose()
        }

        if($workingDirectory -and (Test-Path -LiteralPath $workingDirectory)){
            Remove-Item `
                -LiteralPath $workingDirectory `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }

        Show-JWMessage `
            -Message "The update could not be downloaded or prepared.`r`n`r`n$($_.Exception.Message)" `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Error)

        return $false
    }
}

function Start-JWCountdownLauncher {
    if(-not (Test-JWCountdownInstanceAvailable)){
        Show-JWMessage `
            -Message "$($script:AppName) is already running." `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Information)

        return
    }

    $release = Get-JWCountdownLatestGitHubRelease

    if(-not $release){
        Start-JWCountdownApplication
        return
    }

    try {
        $latestVersion = (
            ConvertTo-JWCountdownVersion $release.tag_name
        ).ToString()

        $comparison = Compare-JWCountdownVersions `
            -CurrentVersion $script:Version `
            -LatestVersion $latestVersion
    } catch {
        Start-JWCountdownApplication
        return
    }

    if($comparison -le 0){
        Start-JWCountdownApplication
        return
    }

    $action = Show-JWCountdownUpdateDialog -Release $release -LatestVersion $latestVersion

    if($action -eq "Install"){
        $updated = Install-JWCountdownUpdate -Release $release -LatestVersion $latestVersion
        if($updated){ return }
    }

    Start-JWCountdownApplication
}

Start-JWCountdownLauncher
