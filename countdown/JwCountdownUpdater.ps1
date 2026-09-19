<#
.SYNOPSIS
    JW Countdown update installer and rollback manager.

.DESCRIPTION
    Downloads and installs a JW Countdown update package.

    The updater verifies the package SHA-256 digest, validates the ZIP structure, validates the release manifest and file hashes, creates a backup of the current installation, installs the new files, validates the resulting installation, restores the previous version if an installation step fails, and launches the updated JW Countdown launcher.

    The updater runs as a separate process because the launcher itself may need to be replaced during an update.

.PARAMETER PackageUrl
    URL of the update package to download.

.PARAMETER PackageName
    File name of the update package.

.PARAMETER ExpectedPackageHash
    SHA-256 digest published for the update package.

.PARAMETER ExpectedVersion
    Version that the downloaded package is expected to contain.

.PARAMETER InstallDirectory
    Existing JW Countdown installation directory.

.PARAMETER ConfigPath
    Full path to the current JW Countdown configuration file.

.PARAMETER LauncherProcessId
    Process ID of the launcher that started the updater.

.NOTES
    Product      : JW Countdown
    Component    : Update installer
    Created      : 26.09.01
    Developer    : 1Dkvr
    Publisher    : Hold'inCorp.
    Platform     : Microsoft Windows
    Runtime      : Windows PowerShell 5.1+
    Dependencies : System.Windows.Forms, System.Drawing, System.IO.Compression, System.IO.Compression.FileSystem
    License      : Custom Non-Commercial Source-Available
    License URL  : https://github.com/1Dkvr/jw/blob/main/LICENSE.md

    Copyright © 2026 [Publisher]. All rights reserved.

    This source code is subject to the terms and conditions defined in the 'LICENSE.md' file located in the root directory of this repository or online at the URL above.

    No external module or third-party dependency is required.

    Future release tooling may add package integrity and Authenticode signature verification without changing the countdown application itself.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageUrl,

    [Parameter(Mandatory)]
    [string]$PackageName,

    [Parameter(Mandatory)]
    [string]$ExpectedPackageHash,

    [Parameter(Mandatory)]
    [string]$ExpectedVersion,

    [Parameter(Mandatory)]
    [string]$InstallDirectory,

    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [Parameter(Mandatory)]
    [int]$LauncherProcessId
)

Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

try {
    $script:Config = Import-PowerShellDataFile -LiteralPath $ConfigPath -ErrorAction Stop
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "The JW Countdown configuration could not be loaded.`r`n`r`n$($_.Exception.Message)",
        "Configuration error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null

    exit 1
}

$script:AppName = $script:Config.Project.Name
$script:UpdateMutexName = "Local\JWCountdown.Update"
$script:WorkingDirectory = $null
$script:ProgressForm = $null

function Show-JWUpdaterMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Error
    )

    [System.Windows.Forms.MessageBox]::Show($Message, "$($script:AppName) - Update", [System.Windows.Forms.MessageBoxButtons]::OK, $Icon) | Out-Null
}

function Show-JWUpdaterProgress {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$($script:AppName) - Update"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(460, 155)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $false
    $form.ShowInTaskbar = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Message
    $label.Location = New-Object System.Drawing.Point(24, 22)
    $label.Size = New-Object System.Drawing.Size(400, 24)
    $label.Font = New-Object System.Drawing.Font("Arial", 10)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(24, 60)
    $progress.Size = New-Object System.Drawing.Size(400, 24)
    $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $progress.MarqueeAnimationSpeed = 25

    $form.Controls.AddRange(@($label, $progress))

    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()

    return $form
}

function Close-JWUpdaterProgress {
    if($script:ProgressForm){
        try {
            $script:ProgressForm.Close()
            $script:ProgressForm.Dispose()
        } catch {
        }
        $script:ProgressForm = $null
    }
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

function Normalize-JWCountdownRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if([string]::IsNullOrWhiteSpace($Path)){ throw "An empty file path is not allowed." }

    $normalized = $Path.Replace('\', '/').TrimStart('/')

    if(
        [System.IO.Path]::IsPathRooted($Path) -or
        $normalized.Contains(':') -or
        $normalized.Contains("`0") -or
        $normalized -match '(^|/)\.\.(/|$')
    ){
        throw "Unsafe relative path: $Path"
    }

    return $normalized
}

function Test-JWCountdownPathInsideDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$RootDirectory,

        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $normalized = Normalize-JWCountdownRelativePath $RelativePath
    $root = [System.IO.Path]::GetFullPath($RootDirectory).TrimEnd('\') + '\'
    $fullPath = [System.IO.Path]::GetFullPath( (Join-Path $RootDirectory ($normalized.Replace('/', '\'))) )

    return $fullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-JWCountdownRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$RootDirectory,

        [Parameter(Mandatory)]
        [string]$FilePath
    )

    $root = [System.IO.Path]::GetFullPath($RootDirectory).TrimEnd('\') + '\'
    $file = [System.IO.Path]::GetFullPath($FilePath)

    if(-not $file.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)){
        throw "The file is outside the expected directory."
    }

    return $file.Substring($root.Length).Replace('\', '/')
}

function Test-JWCountdownPackageUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    try {
        $uri = [System.Uri]$Url
    } catch {
        throw "The update package URL is invalid."
    }

    if($uri.Scheme -ne "https"){ throw "The update package must be downloaded over HTTPS." }
}

function Test-JWCountdownPackageName {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if([string]::IsNullOrWhiteSpace($Name)){ throw "The update package name is empty." }

    if([System.IO.Path]::GetFileName($Name) -ne $Name){ throw "The update package name contains an invalid path." }

    $extension = [string]$script:Config.Package.Extension
    $prefix = [string]$script:Config.Package.Prefix

    if(-not $Name.EndsWith($extension, [System.StringComparison]::OrdinalIgnoreCase)){
        throw "The update package has an unexpected file extension."
    }

    if($Name -notlike "$prefix-*"){ throw "The update package has an unexpected name." }
}

function Download-JWCountdownPackage {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $headers = @{
        Accept       = "application/octet-stream"
        "User-Agent" = "$($script:AppName)-Updater/$($script:Config.Project.Version)"
    }

    Invoke-WebRequest `
        -Uri $Url `
        -Headers $headers `
        -OutFile $DestinationPath `
        -TimeoutSec 120 `
        -UseBasicParsing `
        -ErrorAction Stop
}

function Test-JWCountdownPackageHash {
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [string]$ExpectedHash
    )

    $expected = $ExpectedHash.Trim().ToLowerInvariant()

    if($expected.StartsWith("sha256:")){ $expected = $expected.Substring(7) }

    if($expected -notmatch '^[a-f0-9]{64}$'){ throw "The expected SHA-256 digest is invalid." }

    $actual = (
        Get-FileHash `
            -LiteralPath $PackagePath `
            -Algorithm SHA256 `
            -ErrorAction Stop
    ).Hash.ToLowerInvariant()

    if($actual -ne $expected){ throw "The downloaded update package failed SHA-256 verification." }
}

function Test-JWCountdownZipStructure {
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath
    )

    $zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    $paths = @{}

    try {
        foreach($entry in $zip.Entries){
            if([string]::IsNullOrWhiteSpace($entry.FullName)){ continue }

            $relativePath = Normalize-JWCountdownRelativePath $entry.FullName
            $isDirectory = $entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')

            if($isDirectory){ continue }

            $key = $relativePath.ToLowerInvariant()

            if($paths.ContainsKey($key)){ throw "The update package contains a duplicate file: $relativePath" }

            $paths[$key] = $true
        }
    } finally {
        $zip.Dispose()
    }
}

function Expand-JWCountdownPackage {
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [string]$DestinationDirectory
    )

    if(Test-Path -LiteralPath $DestinationDirectory){
        Remove-Item `
            -LiteralPath $DestinationDirectory `
            -Recurse `
            -Force `
            -ErrorAction Stop
    }

    New-Item `
        -ItemType Directory `
        -Path $DestinationDirectory `
        -Force `
        -ErrorAction Stop | Out-Null

    Test-JWCountdownZipStructure -PackagePath $PackagePath

    [System.IO.Compression.ZipFile]::ExtractToDirectory($PackagePath, $DestinationDirectory)
}

function Get-JWCountdownManifest {
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath
    )

    if(-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)){
        throw "$($script:Config.Files.Manifest) was not found."
    }

    try {
        $manifest = Get-Content `
            -LiteralPath $ManifestPath `
            -Raw `
            -ErrorAction Stop |
            ConvertFrom-Json `
            -ErrorAction Stop
    } catch {
        throw "The update manifest is invalid: $($_.Exception.Message)"
    }

    if(-not $manifest){ throw "The update manifest is empty." }

    foreach($propertyName in @("Product", "Version", "Files")){
        if(-not ($manifest.PSObject.Properties.Name -contains $propertyName)){
            throw "The update manifest is missing: $propertyName"
        }
    }

    if($manifest.Product -ne $script:Config.Project.Name){
        throw "The update manifest is not intended for $($script:Config.Project.Name)."
    }

    return $manifest
}

function Get-JWCountdownInstalledManifest {
    param(
        [Parameter(Mandatory)]
        [string]$InstallDirectory
    )

    $manifestPath = Join-Path `
        $InstallDirectory `
        $script:Config.Files.Manifest

    if(-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)){ return $null }

    return Get-JWCountdownManifest -ManifestPath $manifestPath
}

function Test-JWCountdownManifest {
    param(
        [Parameter(Mandatory)]
        $Manifest,

        [Parameter(Mandatory)]
        [string]$StageDirectory,

        [Parameter(Mandatory)]
        [string]$CurrentVersion,

        [Parameter(Mandatory)]
        [string]$ExpectedVersion
    )

    $manifestVersion = ConvertTo-JWCountdownVersion $Manifest.Version
    $currentVersion = ConvertTo-JWCountdownVersion $CurrentVersion
    $expectedVersionObject = ConvertTo-JWCountdownVersion $ExpectedVersion

    if($manifestVersion -ne $expectedVersionObject){
        throw "Manifest version does not match the expected update version."
    }

    if($manifestVersion -le $currentVersion){
        throw "The update version is not newer than the installed version."
    }

    $manifestFiles = @($Manifest.Files)

    if($manifestFiles.Count -eq 0){
        throw "The update manifest does not contain any files."
    }

    $manifestFilePath = Normalize-JWCountdownRelativePath $script:Config.Files.Manifest
    $declaredPaths = @{}

    foreach($entry in $manifestFiles){
        if(
            -not ($entry.PSObject.Properties.Name -contains "Path") -or
            -not ($entry.PSObject.Properties.Name -contains "SHA256")
        ){
            throw "An update manifest file entry is incomplete."
        }

        $relativePath = Normalize-JWCountdownRelativePath $entry.Path
        $key = $relativePath.ToLowerInvariant()

        if($key -eq $manifestFilePath.ToLowerInvariant()){
            throw "The update manifest cannot contain itself."
        }

        if($declaredPaths.ContainsKey($key)){
            throw "The update manifest contains a duplicate file: $relativePath"
        }

        $declaredPaths[$key] = $true

        if($entry.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){
            throw "Invalid SHA-256 value for: $relativePath"
        }

        if(-not (Test-JWCountdownPathInsideDirectory `
            -RootDirectory $StageDirectory `
            -RelativePath $relativePath)){
            throw "The update manifest contains an unsafe file path."
        }

        $filePath = Join-Path $StageDirectory ($relativePath.Replace('/', '\'))

        if(-not (Test-Path -LiteralPath $filePath -PathType Leaf)){
            throw "The update package is missing: $relativePath"
        }

        $actualHash = (
            Get-FileHash `
                -LiteralPath $filePath `
                -Algorithm SHA256 `
                -ErrorAction Stop
        ).Hash

        if($actualHash -ine $entry.SHA256){
            throw "File integrity verification failed: $relativePath"
        }
    }

    $requiredFiles = @(
        $script:Config.Files.Config,
        $script:Config.Files.EntryPoint,
        $script:Config.Files.Application,
        $script:Config.Files.Launcher,
        $script:Config.Files.Updater
    )

    foreach($requiredFile in $requiredFiles){
        $key = (Normalize-JWCountdownRelativePath $requiredFile).ToLowerInvariant()

        if(-not $declaredPaths.ContainsKey($key)){
            throw "The update manifest is missing the required file: $requiredFile"
        }
    }

    $stageFiles = @(
        Get-ChildItem `
            -LiteralPath $StageDirectory `
            -File `
            -Recurse `
            -Force `
            -ErrorAction Stop |
            ForEach-Object {
                $relativePath = Get-JWCountdownRelativePath `
                    -RootDirectory $StageDirectory `
                    -FilePath $_.FullName

                if($relativePath.ToLowerInvariant() -ne $manifestFilePath.ToLowerInvariant()){
                    $_
                }
            }
    )

    foreach($file in $stageFiles){
        $relativePath = Get-JWCountdownRelativePath `
            -RootDirectory $StageDirectory `
            -FilePath $file.FullName

        $key = $relativePath.ToLowerInvariant()

        if(-not $declaredPaths.ContainsKey($key)){
            throw "The update package contains an undeclared file: $relativePath"
        }
    }
}

function Test-JWCountdownStagedConfiguration {
    param(
        [Parameter(Mandatory)]
        [string]$StageDirectory,

        [Parameter(Mandatory)]
        $Manifest,

        [Parameter(Mandatory)]
        [string]$ExpectedVersion
    )

    $configPath = Join-Path $StageDirectory $script:Config.Files.Config

    if(-not (Test-Path -LiteralPath $configPath -PathType Leaf)){
        throw "$($script:Config.Files.Config) is missing from the update package."
    }

    try {
        $config = Import-PowerShellDataFile -LiteralPath $configPath -ErrorAction Stop
    } catch {
        throw "The updated configuration could not be loaded."
    }

    if($config.Project.Name -ne $script:Config.Project.Name){
        throw "The updated configuration belongs to another product."
    }

    $updatedVersion = ConvertTo-JWCountdownVersion $config.Project.Version

    $expectedVersionObject = ConvertTo-JWCountdownVersion $ExpectedVersion

    if($updatedVersion -ne $expectedVersionObject){
        throw "The updated configuration version does not match the expected version."
    }

    $manifestPaths = @{}

    foreach($entry in @($Manifest.Files)){
        $relativePath = Normalize-JWCountdownRelativePath $entry.Path
        $manifestPaths[$relativePath.ToLowerInvariant()] = $true
    }

    foreach($property in $config.Files.PSObject.Properties){
        $fileName = [string]$property.Value
        $relativePath = Normalize-JWCountdownRelativePath $fileName

        if($property.Name -eq "Manifest"){
            if($relativePath.ToLowerInvariant() -ne $script:Config.Files.Manifest.ToLowerInvariant()){
                throw "The updated configuration references an unexpected manifest file."
            }

            continue
        }

        $key = $relativePath.ToLowerInvariant()

        if(-not $manifestPaths.ContainsKey($key)){
            throw "The updated configuration references a file that is not declared in the manifest: $relativePath"
        }

        $filePath = Join-Path $StageDirectory ($relativePath.Replace('/', '\'))

        if(-not (Test-Path -LiteralPath $filePath -PathType Leaf)){
            throw "The updated configuration references a missing file: $relativePath"
        }
    }

    return $config
}

function Get-JWCountdownManagedFiles {
    param(
        [Parameter(Mandatory)]
        $CurrentConfig,

        [Parameter(Mandatory)]
        [object]$CurrentManifest,

        [Parameter(Mandatory)]
        $NewManifest
    )

    $paths = @{}

    foreach($property in $CurrentConfig.Files.PSObject.Properties){
        $relativePath = Normalize-JWCountdownRelativePath ([string]$property.Value)
        $paths[$relativePath.ToLowerInvariant()] = $relativePath
    }

    if($CurrentManifest){
        foreach($entry in @($CurrentManifest.Files)){
            $relativePath = Normalize-JWCountdownRelativePath $entry.Path
            $paths[$relativePath.ToLowerInvariant()] = $relativePath
        }
    }

    foreach($entry in @($NewManifest.Files)){
        $relativePath = Normalize-JWCountdownRelativePath $entry.Path
        $paths[$relativePath.ToLowerInvariant()] = $relativePath
    }

    $manifestPath = Normalize-JWCountdownRelativePath $CurrentConfig.Files.Manifest
    $paths[$manifestPath.ToLowerInvariant()] = $manifestPath

    return @($paths.Values)
}

function Backup-JWCountdownInstallation {
    param(
        [Parameter(Mandatory)]
        [string]$InstallDirectory,

        [Parameter(Mandatory)]
        [string]$BackupDirectory,

        [Parameter(Mandatory)]
        [string[]]$ManagedFiles
    )

    New-Item `
        -ItemType Directory `
        -Path $BackupDirectory `
        -Force `
        -ErrorAction Stop | Out-Null

    foreach($relativePath in $ManagedFiles){
        $sourcePath = Join-Path `
            $InstallDirectory `
            ($relativePath.Replace('/', '\'))

        if(-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)){ continue }

        $backupPath = Join-Path $BackupDirectory ($relativePath.Replace('/', '\'))
        $backupParent = Split-Path -Path $backupPath -Parent

        New-Item `
            -ItemType Directory `
            -Path $backupParent `
            -Force `
            -ErrorAction Stop | Out-Null

        Copy-Item `
            -LiteralPath $sourcePath `
            -Destination $backupPath `
            -Force `
            -ErrorAction Stop
    }
}

function Remove-JWCountdownManagedFiles {
    param(
        [Parameter(Mandatory)]
        [string]$InstallDirectory,

        [Parameter(Mandatory)]
        [string[]]$ManagedFiles
    )

    foreach($relativePath in $ManagedFiles){
        $targetPath = Join-Path $InstallDirectory ($relativePath.Replace('/', '\'))

        if(Test-Path -LiteralPath $targetPath -PathType Leaf){
            Remove-Item -LiteralPath $targetPath -Force -ErrorAction Stop
        }
    }
}

function Install-JWCountdownFiles {
    param(
        [Parameter(Mandatory)]
        [string]$StageDirectory,

        [Parameter(Mandatory)]
        [string]$InstallDirectory,

        [Parameter(Mandatory)]
        $Manifest
    )

    foreach($entry in @($Manifest.Files)){
        $relativePath = Normalize-JWCountdownRelativePath $entry.Path

        $sourcePath = Join-Path $StageDirectory ($relativePath.Replace('/', '\'))
        $destinationPath = Join-Path $InstallDirectory ($relativePath.Replace('/', '\'))
        $destinationParent = Split-Path -Path $destinationPath -Parent

        New-Item `
            -ItemType Directory `
            -Path $destinationParent `
            -Force `
            -ErrorAction Stop | Out-Null

        Copy-Item `
            -LiteralPath $sourcePath `
            -Destination $destinationPath `
            -Force `
            -ErrorAction Stop
    }

    $manifestSource = Join-Path $StageDirectory $script:Config.Files.Manifest
    $manifestDestination = Join-Path $InstallDirectory $script:Config.Files.Manifest

    Copy-Item `
        -LiteralPath $manifestSource `
        -Destination $manifestDestination `
        -Force `
        -ErrorAction Stop
}

function Restore-JWCountdownInstallation {
    param(
        [Parameter(Mandatory)]
        [string]$InstallDirectory,

        [Parameter(Mandatory)]
        [string]$BackupDirectory,

        [Parameter(Mandatory)]
        [string[]]$ManagedFiles
    )

    Remove-JWCountdownManagedFiles -InstallDirectory $InstallDirectory -ManagedFiles $ManagedFiles
    if(-not (Test-Path -LiteralPath $BackupDirectory -PathType Container)){ return }

    $backupFiles = @(
        Get-ChildItem `
            -LiteralPath $BackupDirectory `
            -File `
            -Recurse `
            -Force `
            -ErrorAction Stop
    )

    foreach($file in $backupFiles){
        $relativePath = Get-JWCountdownRelativePath -RootDirectory $BackupDirectory -FilePath $file.FullName
        $destinationPath = Join-Path $InstallDirectory ($relativePath.Replace('/', '\'))
        $destinationParent = Split-Path -Path $destinationPath -Parent

        New-Item `
            -ItemType Directory `
            -Path $destinationParent `
            -Force `
            -ErrorAction Stop | Out-Null

        Copy-Item `
            -LiteralPath $file.FullName `
            -Destination $destinationPath `
            -Force `
            -ErrorAction Stop
    }
}

function Test-JWCountdownInstallation {
    param(
        [Parameter(Mandatory)]
        [string]$InstallDirectory,

        [Parameter(Mandatory)]
        $Manifest,

        [Parameter(Mandatory)]
        [string]$ExpectedVersion
    )

    foreach($entry in @($Manifest.Files)){
        $relativePath = Normalize-JWCountdownRelativePath $entry.Path

        $filePath = Join-Path $InstallDirectory ($relativePath.Replace('/', '\'))

        if(-not (Test-Path -LiteralPath $filePath -PathType Leaf)){
            throw "Installed file is missing: $relativePath"
        }

        $actualHash = (
            Get-FileHash `
                -LiteralPath $filePath `
                -Algorithm SHA256 `
                -ErrorAction Stop
        ).Hash

        if($actualHash -ine $entry.SHA256){
            throw "Installed file integrity verification failed: $relativePath"
        }
    }

    $configPath = Join-Path $InstallDirectory $script:Config.Files.Config

    if(-not (Test-Path -LiteralPath $configPath -PathType Leaf)){
        throw "Installed configuration file is missing."
    }

    try {
        $installedConfig = Import-PowerShellDataFile -LiteralPath $configPath -ErrorAction Stop
    } catch {
        throw "The installed configuration could not be loaded."
    }

    if($installedConfig.Project.Name -ne $script:Config.Project.Name){
        throw "The installed configuration belongs to another product."
    }

    $installedVersion = ConvertTo-JWCountdownVersion $installedConfig.Project.Version
    $expectedVersionObject = ConvertTo-JWCountdownVersion $ExpectedVersion

    if($installedVersion -ne $expectedVersionObject){
        throw "Installed version does not match the expected update version."
    }
}

function Enter-JWCountdownApplicationLock {
    $mutexName = $script:Config.Runtime.ApplicationMutexName
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $acquired = $false

    try {
        try {
            $acquired = $mutex.WaitOne(0, $false)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }

        if(-not $acquired){
            $mutex.Dispose()
            return $null
        }

        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-JWCountdownApplicationLock {
    param(
        [Parameter(Mandatory)]
        $Mutex
    )

    try {
        $Mutex.ReleaseMutex()
    } catch {
    }

    $Mutex.Dispose()
}

function Wait-JWCountdownLauncherExit {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId,

        [int]$TimeoutSeconds = 30
    )

    if($ProcessId -le 0){ return }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while([DateTime]::UtcNow -lt $deadline){
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if(-not $process){ return }
        Start-Sleep -Milliseconds 250
    }

    throw "The JW Countdown launcher did not exit within the expected time."
}

function Start-JWCountdownLauncher {
    param(
        [Parameter(Mandatory)]
        [string]$InstallDirectory
    )

    $launcherFileName = [string]$script:Config.Files.Launcher
    $launcherPath = Join-Path $InstallDirectory $launcherFileName

    if(-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)){
        throw "$launcherFileName was not found after the update."
    }

    Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList @(
            "-ExecutionPolicy", "Bypass",
            "-NoProfile",
            "-WindowStyle", "Hidden",
            "-File", "`"$launcherPath`""
        ) `
        -WorkingDirectory $InstallDirectory `
        -ErrorAction Stop | Out-Null
}

$script:UpdateMutex = New-Object System.Threading.Mutex($false, $script:UpdateMutexName)

$updateMutexAcquired = $false
$applicationMutex = $null
$installationStarted = $false
$rollbackSucceeded = $false
$backupDirectory = $null
$managedFiles = @()

try {
    try {
        $updateMutexAcquired = $script:UpdateMutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        $updateMutexAcquired = $true
    }

    if(-not $updateMutexAcquired){
        throw "Another JW Countdown update is already in progress."
    }

    if(-not (Test-Path -LiteralPath $InstallDirectory -PathType Container)){
        throw "The JW Countdown installation directory was not found."
    }

    $installRoot = [System.IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\') + '\'
    $configFullPath = [System.IO.Path]::GetFullPath($ConfigPath)

    if(-not $configFullPath.StartsWith($installRoot, [System.StringComparison]::OrdinalIgnoreCase)){
        throw "The configuration file is outside the installation directory."
    }

    $configFileName = [System.IO.Path]::GetFileName($ConfigPath)

    if($configFileName -ne [string]$script:Config.Files.Config){
        throw "The supplied configuration file does not match the application configuration."
    }

    Test-JWCountdownPackageUrl -Url $PackageUrl
    Test-JWCountdownPackageName -Name $PackageName

    $currentConfig = Import-JWCountdownConfig -Path $ConfigPath

    if($currentConfig.Project.Name -ne $script:Config.Project.Name){
        throw "The installed configuration belongs to another product."
    }

    $currentVersion = ConvertTo-JWCountdownVersion $currentConfig.Project.Version
    $expectedVersionObject = ConvertTo-JWCountdownVersion $ExpectedVersion

    if($expectedVersionObject -le $currentVersion){
        throw "The requested update is not newer than the installed version."
    }

    $currentManifest = Get-JWCountdownInstalledManifest -InstallDirectory $InstallDirectory
    $updateId = [guid]::NewGuid().ToString("N")
    $script:WorkingDirectory = Join-Path $env:TEMP "JWCountdownUpdate-$updateId"

    $packagePath = Join-Path $script:WorkingDirectory $PackageName
    $stageDirectory = Join-Path $script:WorkingDirectory "package"
    $backupDirectory = Join-Path $script:WorkingDirectory "backup"
    
    New-Item `
        -ItemType Directory `
        -Path $script:WorkingDirectory `
        -Force `
        -ErrorAction Stop | Out-Null

    $script:ProgressForm = Show-JWUpdaterProgress -Message "Downloading version $ExpectedVersion..."

    Download-JWCountdownPackage -Url $PackageUrl -DestinationPath $packagePath

    Test-JWCountdownPackageHash -PackagePath $packagePath -ExpectedHash $ExpectedPackageHash

    Close-JWUpdaterProgress

    $script:ProgressForm = Show-JWUpdaterProgress -Message "Preparing version $ExpectedVersion..."

    Expand-JWCountdownPackage -PackagePath $packagePath -DestinationDirectory $stageDirectory

    $manifestPath = Join-Path $stageDirectory $script:Config.Files.Manifest

    $manifest = Get-JWCountdownManifest -ManifestPath $manifestPath

    Test-JWCountdownManifest `
        -Manifest $manifest `
        -StageDirectory $stageDirectory `
        -CurrentVersion $currentVersion.ToString() `
        -ExpectedVersion $ExpectedVersion

    $updatedConfig = Test-JWCountdownStagedConfiguration `
        -StageDirectory $stageDirectory `
        -Manifest $manifest `
        -ExpectedVersion $ExpectedVersion

    Close-JWUpdaterProgress

    Wait-JWCountdownLauncherExit -ProcessId $LauncherProcessId

    $applicationMutex = Enter-JWCountdownApplicationLock

    if(-not $applicationMutex){
        throw "JW Countdown is still running. The update cannot be installed."
    }

    $managedFiles = Get-JWCountdownManagedFiles `
        -CurrentConfig $currentConfig `
        -CurrentManifest $currentManifest `
        -NewManifest $manifest

    Backup-JWCountdownInstallation `
        -InstallDirectory $InstallDirectory `
        -BackupDirectory $backupDirectory `
        -ManagedFiles $managedFiles

    $installationStarted = $true

    $script:ProgressForm = Show-JWUpdaterProgress -Message "Installing version $ExpectedVersion..."

    Remove-JWCountdownManagedFiles -InstallDirectory $InstallDirectory -ManagedFiles $managedFiles

    Install-JWCountdownFiles `
        -StageDirectory $stageDirectory `
        -InstallDirectory $InstallDirectory `
        -Manifest $manifest

    Test-JWCountdownInstallation `
        -InstallDirectory $InstallDirectory `
        -Manifest $manifest `
        -ExpectedVersion $ExpectedVersion

    Close-JWUpdaterProgress

    if($script:WorkingDirectory -and (Test-Path -LiteralPath $script:WorkingDirectory)){
        Remove-Item `
            -LiteralPath $script:WorkingDirectory `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    $installationStarted = $false

    Exit-JWCountdownApplicationLock -Mutex $applicationMutex
    $applicationMutex = $null

    try {
        Start-JWCountdownLauncher -InstallDirectory $InstallDirectory
    } catch {
        Show-JWUpdaterMessage `
            -Message "The update was installed successfully, but the new launcher could not be started.`r`n`r`n$($_.Exception.Message)" `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning)

        exit 1
    }
}
catch {
    $errorMessage = $_.Exception.Message

    Close-JWUpdaterProgress

    if($installationStarted -and $backupDirectory){
        try {
            Restore-JWCountdownInstallation `
                -InstallDirectory $InstallDirectory `
                -BackupDirectory $backupDirectory `
                -ManagedFiles $managedFiles

            $rollbackSucceeded = $true
        } catch {
            $rollbackSucceeded = $false
        }
    }

    if($applicationMutex){
        Exit-JWCountdownApplicationLock -Mutex $applicationMutex
        $applicationMutex = $null
    }

    if($script:WorkingDirectory -and (Test-Path -LiteralPath $script:WorkingDirectory)){
        Remove-Item `
            -LiteralPath $script:WorkingDirectory `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    if($rollbackSucceeded){
        Show-JWUpdaterMessage `
            -Message "The update could not be installed and the previous version has been restored.`r`n`r`n$errorMessage"
    } elseif($installationStarted) {
        Show-JWUpdaterMessage `
            -Message "The update failed and the previous installation could not be fully restored.`r`n`r`n$errorMessage"
    } else {
        Show-JWUpdaterMessage `
            -Message "The update could not be installed.`r`n`r`n$errorMessage"
    }

    exit 1
}
finally {
    Close-JWUpdaterProgress

    if($applicationMutex){
        Exit-JWCountdownApplicationLock -Mutex $applicationMutex
        $applicationMutex = $null
    }

    if($updateMutexAcquired){
        try {
            $script:UpdateMutex.ReleaseMutex()
        } catch {
        }
    }
    
    $script:UpdateMutex.Dispose()
}

exit 0
