<#
.SYNOPSIS
    Checks for and installs JW project updates.

.DESCRIPTION
    Provides the shared update mechanism used by JW projects.
    The updater checks GitHub Releases for a newer version of the current project, prompts the user when an update is available, downloads the corresponding package and starts a temporary update worker that replaces the installedproject and JW Core after the application process has terminated.
    The updater itself never replaces the files it is currently executing.

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
        [string]$Title = "JW Update",

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
        Absolute path to the installed project directory.

    .OUTPUTS
        PSCustomObject
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
        return Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        throw "Unable to read the installed project manifest. $($_.Exception.Message)"
    }
}

function Get-JwInstalledProjectVersion {
    <#
    .SYNOPSIS
        Returns the installed project version.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $manifest = Get-JwInstalledManifest -ProjectPath $ProjectPath

    if($null -eq $manifest.Build -or [string]::IsNullOrWhiteSpace([string]$manifest.Build.Version) ){
        throw "The installed project manifest does not contain a valid version."
    }

    $version = [string]$manifest.Build.Version

    if(-not (Test-JwVersion -Version $version)){
        throw "The installed project contains an invalid JW version: $version"
    }

    return $version
}

function Get-JwReleasePackageAsset {
    <#
    .SYNOPSIS
        Finds the ZIP package belonging to a GitHub Release.
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
        Creates a temporary worker that performs the update after the application exits.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkerDirectory,

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

    $workerPath = Join-Path -Path $WorkerDirectory -ChildPath ("jw-update-worker-" + [guid]::NewGuid().ToString("N") + ".ps1")

    $workerContent = @'
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
    [int]$ParentProcessId,

    [Parameter(Mandatory)]
    [string]$WorkerPath
)

Set-StrictMode -Version Latest

$ErrorActionPreference = "Stop"

function Wait-JwParentProcess {
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId
    )

    while($true){
        try {
            Get-Process -Id $ProcessId -ErrorAction Stop | Out-Null
            Start-Sleep -Milliseconds 250
        } catch {
            break
        }
    }
}

function Copy-JwDirectoryContents {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    if(-not (Test-Path -LiteralPath $DestinationPath -PathType Container)){
        New-Item `
            -ItemType Directory `
            -Path $DestinationPath `
            -Force `
            -ErrorAction Stop | Out-Null
    }

    Get-ChildItem `
        -LiteralPath $SourcePath `
        -Force `
        -ErrorAction Stop |
        ForEach-Object {
            Copy-Item `
                -LiteralPath $_.FullName `
                -Destination $DestinationPath `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }
}

function Remove-JwDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if(Test-Path -LiteralPath $Path){
        Remove-Item `
            -LiteralPath $Path `
            -Recurse `
            -Force `
            -ErrorAction Stop
    }
}

try {
    Wait-JwParentProcess -ProcessId $ParentProcessId

    if(-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)){
        throw "Update package was not found: $PackagePath"
    }

    $extractionPath = Join-Path `
        -Path ([System.IO.Path]::GetTempPath()) `
        -ChildPath ("JW-Update-" + [guid]::NewGuid().ToString("N"))

    New-Item `
        -ItemType Directory `
        -Path $extractionPath `
        -Force `
        -ErrorAction Stop | Out-Null

    Expand-Archive `
        -LiteralPath $PackagePath `
        -DestinationPath $extractionPath `
        -Force `
        -ErrorAction Stop

    $sourceCorePath = Join-Path -Path $extractionPath -ChildPath ".core"
    $sourceProjectPath = Join-Path -Path $extractionPath -ChildPath $Project
    $sourceManifestPath = Join-Path -Path $extractionPath -ChildPath "manifest.json"
    $sourceCoreManifestPath = Join-Path -Path $sourceCorePath -ChildPath "manifest.json"

    if(-not (Test-Path -LiteralPath $sourceCorePath -PathType Container)){
        throw "The update package does not contain '.core'."
    }

    if(-not (Test-Path -LiteralPath $sourceProjectPath -PathType Container)){
        throw "The update package does not contain '$Project'."
    }

    if(
        -not (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf) -and
        -not (Test-Path -LiteralPath $sourceCoreManifestPath -PathType Leaf)
    ){
        throw "The update package does not contain a manifest."
    }

    $destinationCorePath = Join-Path `
        -Path $CollectionPath `
        -ChildPath ".core"

    $destinationProjectPath = Join-Path `
        -Path $CollectionPath `
        -ChildPath $Project

    Remove-JwDirectory -Path $destinationCorePath
    Remove-JwDirectory -Path $destinationProjectPath

    Copy-JwDirectoryContents `
        -SourcePath $sourceCorePath `
        -DestinationPath $destinationCorePath

    Copy-JwDirectoryContents `
        -SourcePath $sourceProjectPath `
        -DestinationPath $destinationProjectPath

    if(Test-Path -LiteralPath $sourceManifestPath -PathType Leaf){
        Copy-Item `
            -LiteralPath $sourceManifestPath `
            -Destination (Join-Path -Path $destinationProjectPath -ChildPath "manifest.json") `
            -Force `
            -ErrorAction Stop
    } else {
        Copy-Item `
            -LiteralPath $sourceCoreManifestPath `
            -Destination (Join-Path -Path $destinationProjectPath -ChildPath "manifest.json") `
            -Force `
            -ErrorAction Stop
    }

    foreach($collectionFile in @("LICENSE.md", "README.md")){
        $sourcePath = Join-Path -Path $extractionPath -ChildPath $collectionFile
        $destinationPath = Join-Path -Path $CollectionPath -ChildPath $collectionFile

        if(Test-Path -LiteralPath $sourcePath -PathType Leaf){
            Copy-Item `
                -LiteralPath $sourcePath `
                -Destination $destinationPath `
                -Force `
                -ErrorAction Stop
        }
    }

    Remove-Item `
        -LiteralPath $PackagePath `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        -LiteralPath $extractionPath `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    if(Test-Path -LiteralPath $WorkerPath -PathType Leaf){
        Remove-Item `
            -LiteralPath $WorkerPath `
            -Force `
            -ErrorAction SilentlyContinue
    }

    $entryPointPath = Join-Path `
        -Path $destinationProjectPath `
        -ChildPath $EntryPoint

    if(Test-Path -LiteralPath $entryPointPath -PathType Leaf){
        Start-Process `
            -FilePath "cmd.exe" `
            -ArgumentList @(
                "/c"
                "`"$entryPointPath`""
            ) `
            -WorkingDirectory $destinationProjectPath `
            -ErrorAction Stop | Out-Null
    }
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "The update could not be completed.`r`n`r`n$($_.Exception.Message)",
        "JW Update",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null

    exit 1
}
'@

    $workerContent | Set-Content -LiteralPath $workerPath -Encoding UTF8 -ErrorAction Stop

    return $workerPath
}

function Start-JwUpdateWorker {
    <#
    .SYNOPSIS
        Starts the temporary update worker process.
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
        "-WorkerPath"
        "`"$WorkerPath`""
    )

    Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList ($arguments -join " ") `
        -WindowStyle Hidden `
        -ErrorAction Stop | Out-Null
}

function Import-JwUpdaterDependencies {
    <#
    .SYNOPSIS
        Loads the shared JW Core dependencies required by the updater.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CorePath
    )

    $initializePath = Join-Path -Path $CorePath -ChildPath "initialize.ps1"
    $versionPath = Join-Path -Path $CorePath -ChildPath "version.ps1"
    $githubPath = Join-Path -Path $CorePath -ChildPath "github.ps1"

    foreach($dependencyPath in @(
        $initializePath
        $versionPath
        $githubPath
    )){
        if(-not (Test-Path -LiteralPath $dependencyPath -PathType Leaf)){
            throw "Required JW Core file was not found: $dependencyPath"
        }
    }

    . $initializePath
    . $versionPath
    . $githubPath
}

function Invoke-JwProjectUpdate {
    <#
    .SYNOPSIS
        Checks for and optionally installs a newer version of a JW project.

    .DESCRIPTION
        Checks GitHub Releases for the latest published version of the selected
        project. If a newer version exists, the user is asked whether the update
        should be installed.

        When the update is accepted, a temporary worker process is started.
        The calling application must then terminate so the worker can replace
        the installed .core and project directories safely.

    .PARAMETER CollectionPath
        Absolute path to the JW Collection.

    .PARAMETER Project
        Project directory name.

    .PARAMETER ProcessId
        Process ID of the currently running application.

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

        [Parameter()]
        [int]$ProcessId = $PID
    )

    try {
        $collectionPathResolved = [System.IO.Path]::GetFullPath($CollectionPath)
        $projectPath = Join-Path -Path $collectionPathResolved -ChildPath $Project
        $corePath = Join-Path -Path $collectionPathResolved -ChildPath ".core"

        if(-not (Test-Path -LiteralPath $collectionPathResolved -PathType Container)){
            throw "JW Collection directory was not found: $collectionPathResolved"
        }

        if(-not (Test-Path -LiteralPath $projectPath -PathType Container)){
            throw "Project directory was not found: $projectPath"
        }

        if(-not (Test-Path -LiteralPath $corePath -PathType Container)){
            throw "JW Core directory was not found: $corePath"
        }

        Import-JwUpdaterDependencies -CorePath $corePath

        $context = Initialize-JwContext -RepositoryRoot $collectionPathResolved -Project $Project
        $currentVersion = Get-JwInstalledProjectVersion -ProjectPath $projectPath
        $latestRelease = Get-JwGitHubLatestProjectRelease -Context $context

        if($null -eq $latestRelease){
            return [pscustomobject]@{
                UpdateAvailable = $false
                Updated         = $false
                RestartRequired = $false
                CurrentVersion  = $currentVersion
                LatestVersion   = $null
            }
        }

        $latestVersion = [string]$latestRelease.Version.Version

        $comparison = Compare-JwVersions `
            -VersionA $currentVersion `
            -VersionB $latestVersion

        if($comparison -ge 0){
            return [pscustomobject]@{
                UpdateAvailable = $false
                Updated         = $false
                RestartRequired = $false
                CurrentVersion  = $currentVersion
                LatestVersion   = $latestVersion
            }
        }

        $projectName = [string]$context.ProjectConfig.Project.Name

        $dialogResult = Show-JwUpdaterMessage `
            -Message "$projectName $latestVersion is available.`r`n`r`nInstalled version: $currentVersion`r`nAvailable version: $latestVersion`r`n`r`nWould you like to install this update now?" `
            -Title "$projectName Update" `
            -Buttons ([System.Windows.Forms.MessageBoxButtons]::YesNo) `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Information)

        if($dialogResult -ne [System.Windows.Forms.DialogResult]::Yes){
            return [pscustomobject]@{
                UpdateAvailable = $true
                Updated         = $false
                RestartRequired = $false
                CurrentVersion  = $currentVersion
                LatestVersion   = $latestVersion
            }
        }

        $asset = Get-JwReleasePackageAsset `
            -Context $context `
            -Release $latestRelease

        if($null -eq $asset){
            throw "The latest Release does not contain the expected ZIP package."
        }

        $updateDirectory = Join-Path `
            -Path ([System.IO.Path]::GetTempPath()) `
            -ChildPath ("JW-Update-" + [guid]::NewGuid().ToString("N"))

        New-Item `
            -ItemType Directory `
            -Path $updateDirectory `
            -Force `
            -ErrorAction Stop | Out-Null

        $packagePath = Join-Path `
            -Path $updateDirectory `
            -ChildPath ([string]$asset.name)

        Save-JwGitHubReleaseAsset `
            -Context $context `
            -Asset $asset `
            -DestinationPath $packagePath

        $entryPoint = [string]$context.ProjectConfig.Files.EntryPoint

        if([string]::IsNullOrWhiteSpace($entryPoint)){
            throw "The project configuration does not define 'Files.EntryPoint'."
        }

        $workerPath = New-JwUpdateWorker `
            -WorkerDirectory $updateDirectory `
            -PackagePath $packagePath `
            -CollectionPath $collectionPathResolved `
            -Project $Project `
            -EntryPoint $entryPoint `
            -ParentProcessId $ProcessId

        Start-JwUpdateWorker `
            -WorkerPath $workerPath `
            -PackagePath $packagePath `
            -CollectionPath $collectionPathResolved `
            -Project $Project `
            -EntryPoint $entryPoint `
            -ParentProcessId $ProcessId

        return [pscustomobject]@{
            UpdateAvailable = $true
            Updated         = $true
            RestartRequired = $true
            CurrentVersion  = $currentVersion
            LatestVersion   = $latestVersion
        }
    } catch {
        return [pscustomobject]@{
            UpdateAvailable = $false
            Updated         = $false
            RestartRequired = $false
            CurrentVersion  = $null
            LatestVersion   = $null
            Error           = $_.Exception.Message
        }
    }
}
