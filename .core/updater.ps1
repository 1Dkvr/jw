<#
.SYNOPSIS
    Checks for and installs JW project updates.

.DESCRIPTION
    Provides the shared update mechanism used by JW projects.
    The updater checks GitHub Releases for a newer version of the current project, prompts the user when an update is available, downloads the corresponding package and replaces the installed project and JW Core through a temporary updater process.
    GitHub Releases are the authoritative source for published project versions.

.NOTES
    Product      : JW Core
    Component    : Project updater
    Developer    : 1Dkvr
    Licensor     : Hold'inCorp.
    Platform     : Microsoft Windows
    Runtime      : Windows PowerShell 5.1+
    Dependencies : System.Windows.Forms
    License      : Custom Non-Commercial Source-Available
    License URL  : https://github.com/1Dkvr/jw/blob/main/LICENSE.md

    Copyright © 2019 Hold'inCorp. — All rights reserved.
    Developed by 1Dkvr.
    Licensed under the Custom Non-Commercial Source-Available License.
    See `LICENSE.md` for the full license terms.

    This source code is protected by applicable copyright and other intellectual property laws. Use, reproduction, modification and redistribution are subject to the terms and conditions defined in `LICENSE.md`.

    The copyright and license notices contained in this source code must not be removed, altered or obscured without authorization.
#>

param(
    [Parameter()]
    [switch]$Library
)

Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Windows.Forms

function Show-JwUpdaterMessage {
    <#
    .SYNOPSIS
        Displays an updater message.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [string]$Title = "JW Countdown",

        [Parameter()]
        [System.Windows.Forms.MessageBoxButtons]$Buttons = [System.Windows.Forms.MessageBoxButtons]::OK,

        [Parameter()]
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )

    return [System.Windows.Forms.MessageBox]::Show($Message, $Title, $Buttons, $Icon)
}

function Get-JwInstalledManifest {
    <#
    .SYNOPSIS
        Reads the installed project's manifest.

    .PARAMETER ProjectPath
        Path to the installed project directory.

    .OUTPUTS
        System.Object
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $manifestPath = Join-Path -Path $ProjectPath -ChildPath "manifest.json"

    if(-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)){
        throw "The installed project manifest was not found: $manifestPath"
    }

    try {
        return Get-Content `
            -LiteralPath $manifestPath `
            -Raw `
            -ErrorAction Stop |
            ConvertFrom-Json
    } catch {
        throw "Unable to read the installed project manifest. $($_.Exception.Message)"
    }
}

function Get-JwInstalledProjectVersion {
    <#
    .SYNOPSIS
        Returns the installed project version from its manifest.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $manifest = Get-JwInstalledManifest -ProjectPath $ProjectPath

    if(
        $null -eq $manifest.Build -or
        [string]::IsNullOrWhiteSpace([string]$manifest.Build.Version)
    ){
        throw "The installed project manifest does not contain a valid version."
    }

    $version = [string]$manifest.Build.Version

    if(-not (Test-JwVersion -Version $version)){
        throw "The installed project contains an invalid JW version: $version"
    }

    return $version
}

function Get-JwUpdaterReleasePackage {
    <#
    .SYNOPSIS
        Finds the downloadable ZIP package for a GitHub Release.

    .PARAMETER Context
        Initialized JW project context.

    .PARAMETER Release
        GitHub Release information.

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
        [pscustomobject]$Release
    )

    $expectedPrefix = "$($Context.ProductIdentifier)-"
    $extension = [string]$Context.PackageExtension

    foreach($asset in @($Release.Release.assets)){
        $assetName = [string]$asset.name

        if(
            $assetName.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
            $assetName.EndsWith($extension, [System.StringComparison]::OrdinalIgnoreCase)
        ){
            return $asset
        }
    }

    return $null
}

function New-JwUpdateWorker {
    <#
    .SYNOPSIS
        Creates the temporary process responsible for replacing the application.

    .DESCRIPTION
        The worker runs independently from the application's updater process so
        that the installed .core directory can safely be replaced after the
        application and updater processes have terminated.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$UpdateRoot,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CollectionPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Project,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$EntryPoint,

        [Parameter(Mandatory)]
        [int]$ParentProcessId
    )

    $workerPath = Join-Path -Path $UpdateRoot -ChildPath "jw-update-worker-$PID.ps1"

    $workerTemplate = @'
param(
    [Parameter(Mandatory)]
    [string]$PackagePath,

    [Parameter(Mandatory)]
    [string]$CollectionPath,

    [Parameter(Mandatory)]
    [string]$Project,

    [Parameter(Mandatory)]
    [string]$EntryPoint,

    [Parameter(Mandatory)]
    [int]$ParentProcessId
)

Set-StrictMode -Version Latest

$ErrorActionPreference = "Stop"

function Remove-DirectorySafely {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if(Test-Path -LiteralPath $Path){
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    if(-not (Test-Path -LiteralPath $DestinationPath -PathType Container)){
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    Get-ChildItem -LiteralPath $SourcePath -Force |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $DestinationPath -Recurse -Force
        }
}

function Wait-ForProcessExit {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId
    )

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $process.WaitForExit()
    } catch {
        # The parent process has already exited.
    }
}

try {
    Wait-ForProcessExit -ProcessId $ParentProcessId

    $updateExtractionPath = Join-Path `
        -Path ([System.IO.Path]::GetTempPath()) `
        -ChildPath ("JW-Update-" + [guid]::NewGuid().ToString("N"))

    New-Item `
        -ItemType Directory `
        -Path $updateExtractionPath `
        -Force | Out-Null

    Expand-Archive `
        -LiteralPath $PackagePath `
        -DestinationPath $updateExtractionPath `
        -Force

    $sourceCorePath = Join-Path -Path $updateExtractionPath -ChildPath ".core"
    $sourceProjectPath = Join-Path -Path $updateExtractionPath -ChildPath $Project

    if(-not (Test-Path -LiteralPath $sourceCorePath -PathType Container)){
        throw "The update package does not contain .core."
    }

    if(-not (Test-Path -LiteralPath $sourceProjectPath -PathType Container)){
        throw "The update package does not contain the project directory."
    }

    $destinationCorePath = Join-Path -Path $CollectionPath -ChildPath ".core"
    $destinationProjectPath = Join-Path -Path $CollectionPath -ChildPath $Project

    Remove-DirectorySafely -Path $destinationCorePath
    Remove-DirectorySafely -Path $destinationProjectPath

    Copy-DirectoryContents `
        -SourcePath $sourceCorePath `
        -DestinationPath $destinationCorePath

    Copy-DirectoryContents `
        -SourcePath $sourceProjectPath `
        -DestinationPath $destinationProjectPath

    if(Test-Path -LiteralPath (Join-Path -Path $updateExtractionPath -ChildPath "LICENSE.md") -PathType Leaf){
        Copy-Item `
            -LiteralPath (Join-Path -Path $updateExtractionPath -ChildPath "LICENSE.md") `
            -Destination (Join-Path -Path $CollectionPath -ChildPath "LICENSE.md") `
            -Force
    }

    if(Test-Path -LiteralPath (Join-Path -Path $updateExtractionPath -ChildPath "README.md") -PathType Leaf
    ){
        Copy-Item `
            -LiteralPath (Join-Path -Path $updateExtractionPath -ChildPath "README.md") `
            -Destination (Join-Path -Path $CollectionPath -ChildPath "README.md") `
            -Force
    }

    Remove-Item `
        -LiteralPath $PackagePath `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-DirectorySafely -Path $updateExtractionPath

    $entryPointPath = Join-Path `
        -Path $destinationProjectPath `
        -ChildPath $EntryPoint

    if(Test-Path -LiteralPath $entryPointPath -PathType Leaf){
        Start-Process -FilePath $entryPointPath -WorkingDirectory $destinationProjectPath
    }
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "The update could not be completed.`r`n`r`n$($_.Exception.Message)",
        "JW Updater",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null

    exit 1
}
'@

    $workerContent = $workerTemplate

    $workerContent | Set-Content -LiteralPath $workerPath -Encoding UTF8 -ErrorAction Stop

    return $workerPath
}

function Start-JwUpdateWorker {
    <#
    .SYNOPSIS
        Starts the temporary update worker.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkerPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CollectionPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Project,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$EntryPoint,

        [Parameter(Mandatory)]
        [int]$ParentProcessId
    )

    $arguments = @(
        "-NoLogo"
        "-NoProfile"
        "-ExecutionPolicy"
        "Bypass"
        "-File"
        "`"$WorkerPath`""
        "-PackagePath"
        "`"$PackagePath`""
        "-CollectionPath"
        "`"$CollectionPath`""
        "-Project"
        "`"$Project`""
        "-EntryPoint"
        "`"$EntryPoint`""
        "-ParentProcessId"
        $ParentProcessId
    )

    Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList ($arguments -join " ") `
        -WindowStyle Hidden `
        -ErrorAction Stop | Out-Null
}

function Invoke-JwProjectUpdate {
    <#
    .SYNOPSIS
        Checks for and optionally installs a newer version of the current project.

    .PARAMETER CollectionPath
        Root path of the installed JW Collection.

    .PARAMETER Project
        Installed project directory name.

    .PARAMETER Context
        Initialized JW project context.

    .OUTPUTS
        PSCustomObject
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CollectionPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Project,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context
    )

    $projectPath = Join-Path -Path $CollectionPath -ChildPath $Project

    $currentVersion = Get-JwInstalledProjectVersion `
        -ProjectPath $projectPath

    $latestRelease = Get-JwGitHubLatestProjectRelease `
        -Context $Context

    if($null -eq $latestRelease){
        return [pscustomobject]@{
            UpdateAvailable = $false
            CurrentVersion  = $currentVersion
            LatestVersion   = $null
            Updated         = $false
        }
    }

    $latestVersion = [string]$latestRelease.Version.Version

    $comparison = Compare-JwVersions -VersionA $currentVersion -VersionB $latestVersion

    if($comparison -ge 0){
        return [pscustomobject]@{
            UpdateAvailable = $false
            CurrentVersion  = $currentVersion
            LatestVersion   = $latestVersion
            Updated         = $false
        }
    }

    $projectName = [string]$Context.ProjectConfig.Project.Name

    $result = Show-JwUpdaterMessage `
        -Message "$projectName $latestVersion is available.`r`n`r`nInstalled version: $currentVersion`r`nAvailable version: $latestVersion`r`n`r`nWould you like to install the update now?" `
        -Title "$projectName Update" `
        -Buttons ([System.Windows.Forms.MessageBoxButtons]::YesNo) `
        -Icon ([System.Windows.Forms.MessageBoxIcon]::Information)

    if($result -ne [System.Windows.Forms.DialogResult]::Yes){
        return [pscustomobject]@{
            UpdateAvailable = $true
            CurrentVersion  = $currentVersion
            LatestVersion   = $latestVersion
            Updated         = $false
        }
    }

    $asset = Get-JwUpdaterReleasePackage `
        -Context $Context `
        -Release $latestRelease

    if($null -eq $asset){
        throw "The latest Release does not contain the expected project package."
    }

    $updateRoot = Join-Path `
        -Path ([System.IO.Path]::GetTempPath()) `
        -ChildPath ("JW-Update-" + [guid]::NewGuid().ToString("N"))

    New-Item `
        -ItemType Directory `
        -Path $updateRoot `
        -Force `
        -ErrorAction Stop | Out-Null

    $packagePath = Join-Path `
        -Path $updateRoot `
        -ChildPath ([string]$asset.name)

    Save-JwGitHubReleaseAsset `
        -Context $Context `
        -Asset $asset `
        -DestinationPath $packagePath

    $entryPoint = [string]$Context.ProjectConfig.Files.EntryPoint

    if([string]::IsNullOrWhiteSpace($entryPoint)){
        throw "The project configuration does not define an EntryPoint."
    }

    $workerPath = New-JwUpdateWorker `
        -UpdateRoot $updateRoot `
        -PackagePath $packagePath `
        -CollectionPath $CollectionPath `
        -Project $Project `
        -EntryPoint $entryPoint `
        -ParentProcessId $PID

    Start-JwUpdateWorker `
        -WorkerPath $workerPath `
        -PackagePath $packagePath `
        -CollectionPath $CollectionPath `
        -Project $Project `
        -EntryPoint $entryPoint `
        -ParentProcessId $PID

    return [pscustomobject]@{
        UpdateAvailable = $true
        CurrentVersion  = $currentVersion
        LatestVersion   = $latestVersion
        Updated         = $true
        RestartRequired = $true
    }
}

if(-not $Library){
    try {
        $collectionPath = Split-Path -Path $PSScriptRoot -Parent
        $projectPath = Join-Path -Path $collectionPath -ChildPath $env:JW_PROJECT

        if(-not (Test-Path -LiteralPath $projectPath -PathType Container)){ return }

        $corePath = Join-Path -Path $collectionPath -ChildPath ".core"
        $initializePath = Join-Path -Path $corePath -ChildPath "initialize.ps1"
        $versionPath = Join-Path -Path $corePath -ChildPath "version.ps1"
        $githubPath = Join-Path -Path $corePath -ChildPath "github.ps1"

        . $initializePath
        . $versionPath
        . $githubPath

        $context = Initialize-JwContext `
            -RepositoryRoot $collectionPath `
            -Project $env:JW_PROJECT

        [void](Invoke-JwProjectUpdate `
            -CollectionPath $collectionPath `
            -Project $env:JW_PROJECT `
            -Context $context)
    } catch {
        # Update checks must never prevent the application from starting.
    }
}
