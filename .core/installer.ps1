<#
.SYNOPSIS
    Installs a JW project into a local JW Collection.

.DESCRIPTION
    Installs a packaged JW project into a JW Collection selected by the user. The installer first checks for a previously registered collection location, then checks common user locations before allowing manual selection.
    Shared JW Core components are installed into the collection's hidden `.core` directory, while project-specific files are installed into the project's own directory.
    The installer does not require an Internet connection.

.NOTES
    Product      : JW Core
    Component    : Project installer
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
Add-Type -AssemblyName System.Drawing

function Show-JwInstallerMessage {
    <#
    .SYNOPSIS
        Displays an installer message.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [string]$Title = "JW Installer",

        [Parameter()]
        [System.Windows.Forms.MessageBoxButtons]$Buttons = [System.Windows.Forms.MessageBoxButtons]::OK,

        [Parameter()]
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )

    return [System.Windows.Forms.MessageBox]::Show($Message, $Title, $Buttons, $Icon)
}

function Get-JwInstallerContext {
    <#
    .SYNOPSIS
        Loads the packaged JW project context.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageRoot
    )

    $corePath = Join-Path -Path $PackageRoot -ChildPath ".core"
    $initializePath = Join-Path -Path $corePath -ChildPath "initialize.ps1"

    if(-not (Test-Path -LiteralPath $corePath -PathType Container)){
        throw "The JW Core directory was not found: $corePath"
    }

    if(-not (Test-Path -LiteralPath $initializePath -PathType Leaf)){
        throw "The JW initialization script was not found: $initializePath"
    }

    . $initializePath

    $manifestPaths = @(Get-ChildItem -LiteralPath $PackageRoot -Directory -Force -ErrorAction Stop | ForEach-Object {
        $candidateManifestPath = Join-Path -Path $_.FullName -ChildPath "manifest.json"

        if(Test-Path -LiteralPath $candidateManifestPath -PathType Leaf){
            $candidateManifestPath
        }
    })

    if($manifestPaths.Count -ne 1){ throw "Unable to determine the packaged project manifest." }

    $manifestPath = $manifestPaths[0]

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        throw "Unable to read the package manifest. $($_.Exception.Message)"
    }

    if($null -eq $manifest.Project -or [string]::IsNullOrWhiteSpace([string]$manifest.Project.Directory)){
        throw "The package manifest does not define a valid project directory."
    }

    $project = [string]$manifest.Project.Directory

    $context = Initialize-JwContext -RepositoryRoot $PackageRoot -Project $project

    return [pscustomobject]@{
        Context      = $context
        Manifest     = $manifest
        PackageRoot  = $PackageRoot
        CorePath     = $corePath
        Project      = $project
        ProjectPath  = Join-Path -Path $PackageRoot -ChildPath $project
        ManifestPath = $manifestPath
    }
}

function Get-JwCollectionName {
    <#
    .SYNOPSIS
        Generates the collection directory name from the repository name.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context
    )

    return "$($Context.RepositoryIdentifier)Collection"
}

function Get-JwCollectionRegistryPath {
    <#
    .SYNOPSIS
        Returns the registry location used to remember the user's JW Collection.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context
    )

    return "HKCU:\Software\$($Context.RepositoryOwner)\$($Context.Repository)"
}

function Get-JwStoredCollectionPath {
    <#
    .SYNOPSIS
        Returns the previously registered JW Collection path when available.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context
    )

    $registryPath = Get-JwCollectionRegistryPath -Context $Context

    if(-not (Test-Path -LiteralPath $registryPath)){ return $null }

    try {
        $registryItem = Get-ItemProperty -LiteralPath $registryPath -Name "CollectionPath" -ErrorAction Stop
        $storedPath = [string]$registryItem.CollectionPath

        if(-not [string]::IsNullOrWhiteSpace($storedPath) -and (Test-Path -LiteralPath $storedPath -PathType Container)){
            return [System.IO.Path]::GetFullPath($storedPath)
        }
    } catch {
        return $null
    }

    return $null
}

function Save-JwCollectionPath {
    <#
    .SYNOPSIS
        Saves the selected JW Collection path for future installations.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CollectionPath
    )

    $registryPath = Get-JwCollectionRegistryPath -Context $Context

    try {
        if(-not (Test-Path -LiteralPath $registryPath)){
            New-Item -Path $registryPath -Force -ErrorAction Stop | Out-Null
        }

        New-ItemProperty `
            -LiteralPath $registryPath `
            -Name "CollectionPath" `
            -Value ([System.IO.Path]::GetFullPath($CollectionPath)) `
            -PropertyType String `
            -Force `
            -ErrorAction Stop | Out-Null
    } catch {
        # Installation remains valid even if the preference cannot be stored.
    }
}

function Get-JwCandidateCollectionPaths {
    <#
    .SYNOPSIS
        Returns likely JW Collection locations for the current user.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CollectionName
    )

    $paths = New-Object System.Collections.Generic.List[string]

    $storedPath = Get-JwStoredCollectionPath -Context $Context

    if(-not [string]::IsNullOrWhiteSpace($storedPath)){ [void]$paths.Add($storedPath) }

    $userHome = [Environment]::GetFolderPath("UserProfile")
    $documents = [Environment]::GetFolderPath("MyDocuments")
    $desktop = [Environment]::GetFolderPath("Desktop")
    $downloads = Join-Path -Path $userHome -ChildPath "Downloads"
    $localAppData = [Environment]::GetFolderPath("LocalApplicationData")
    $roamingAppData = [Environment]::GetFolderPath("ApplicationData")

    $commonRoots = @(
        $userHome
        $documents
        $desktop
        $downloads
        $localAppData
        $roamingAppData
    )

    foreach($root in $commonRoots){
        if([string]::IsNullOrWhiteSpace($root)){ continue }

        $candidate = Join-Path -Path $root -ChildPath $CollectionName

        if(Test-Path -LiteralPath $candidate -PathType Container){
            [void]$paths.Add([System.IO.Path]::GetFullPath($candidate))
        }
    }

    return @($paths | Select-Object -Unique)
}

function Select-JwCollectionPath {
    <#
    .SYNOPSIS
        Determines the JW Collection installation path.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CollectionName
    )

    $candidates = @(Get-JwCandidateCollectionPaths -Context $Context -CollectionName $CollectionName)

    if($candidates.Count -gt 0){
        $selectedCandidate = $candidates[0]

        $result = Show-JwInstallerMessage `
            -Message "A JW Collection was found at:`r`n`r`n$selectedCandidate`r`n`r`nInstall $($Context.Project) in this collection?" `
            -Title "JW Installer" `
            -Buttons ([System.Windows.Forms.MessageBoxButtons]::YesNoCancel) `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Question)

        switch($result){
            ([System.Windows.Forms.DialogResult]::Yes) { return $selectedCandidate }
            ([System.Windows.Forms.DialogResult]::Cancel) { return $null }
        }
    }

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Choose the location where JW Collection will be created."
    $dialog.ShowNewFolderButton = $true

    try {
        $result = $dialog.ShowDialog()

        if($result -ne [System.Windows.Forms.DialogResult]::OK){ return $null }

        $selectedLocation = [System.IO.Path]::GetFullPath($dialog.SelectedPath)

        if([System.StringComparer]::OrdinalIgnoreCase.Equals((Split-Path -Path $selectedLocation -Leaf), $CollectionName)){
            return $selectedLocation
        }

        return (Join-Path -Path $selectedLocation -ChildPath $CollectionName)
    } finally {
        $dialog.Dispose()
    }
}

function Test-JwWritableDirectory {
    <#
    .SYNOPSIS
        Verifies that a directory can be written to.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    try {
        if(-not (Test-Path -LiteralPath $Path -PathType Container)){
            New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        $testFile = Join-Path -Path $Path -ChildPath ".core-write-test-$PID.tmp"

        Set-Content `
            -LiteralPath $testFile `
            -Value "JW" `
            -Encoding ASCII `
            -ErrorAction Stop

        Remove-Item `
            -LiteralPath $testFile `
            -Force `
            -ErrorAction Stop

        return $true
    } catch {
        return $false
    }
}

function Install-JwCore {
    <#
    .SYNOPSIS
        Installs the shared JW Core files into the collection.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageCorePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CollectionCorePath
    )

    if(-not (Test-Path -LiteralPath $PackageCorePath -PathType Container)){
        throw "Packaged JW Core directory was not found: $PackageCorePath"
    }

    if(-not (Test-Path -LiteralPath $CollectionCorePath -PathType Container)){
        New-Item `
            -ItemType Directory `
            -Path $CollectionCorePath `
            -Force `
            -ErrorAction Stop | Out-Null
    }

    $coreFiles = @(
        "config.psd1"
        "initialize.ps1"
        "version.ps1"
        "github.ps1"
        "updater.ps1"
        "installer.ps1"
    )

    foreach($fileName in $coreFiles){
        $sourcePath = Join-Path -Path $PackageCorePath -ChildPath $fileName
        $destinationPath = Join-Path -Path $CollectionCorePath -ChildPath $fileName

        if(-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)){
            throw "Required JW Core file was not found in the package: $sourcePath"
        }

        Copy-Item `
            -LiteralPath $sourcePath `
            -Destination $destinationPath `
            -Force `
            -ErrorAction Stop
    }
}

function Install-JwProject {
    <#
    .SYNOPSIS
        Installs the selected project into the JW Collection.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageProjectPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CollectionPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Project
    )

    if(-not (Test-Path -LiteralPath $PackageProjectPath -PathType Container)){
        throw "Packaged project directory was not found: $PackageProjectPath"
    }

    $destinationProjectPath = Join-Path -Path $CollectionPath -ChildPath $Project

    if(-not (Test-Path -LiteralPath $destinationProjectPath -PathType Container)){
        New-Item `
            -ItemType Directory `
            -Path $destinationProjectPath `
            -Force `
            -ErrorAction Stop | Out-Null
    }

    Get-ChildItem `
        -LiteralPath $PackageProjectPath `
        -Force `
        -ErrorAction Stop |
        ForEach-Object {
            Copy-Item `
                -LiteralPath $_.FullName `
                -Destination $destinationProjectPath `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }

    return $destinationProjectPath
}

function Install-JwCollectionFiles {
    <#
    .SYNOPSIS
        Installs shared collection documentation when it is not already present.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageRoot,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CollectionPath
    )

    foreach($fileName in @("LICENSE.md", "README.md")){
        $sourcePath = Join-Path -Path $PackageRoot -ChildPath $fileName
        $destinationPath = Join-Path -Path $CollectionPath -ChildPath $fileName

        if(
            (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
            (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf))
        ){
            Copy-Item `
                -LiteralPath $sourcePath `
                -Destination $destinationPath `
                -Force `
                -ErrorAction Stop
        }
    }
}

function Install-JwProjectManifest {
    <#
    .SYNOPSIS
        Installs the project manifest alongside the installed project.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageManifestPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $destinationPath = Join-Path -Path $ProjectPath -ChildPath "manifest.json"

    Copy-Item `
        -LiteralPath $PackageManifestPath `
        -Destination $destinationPath `
        -Force `
        -ErrorAction Stop
}

function Start-JwInstalledProject {
    <#
    .SYNOPSIS
        Starts the installed project through its configured entry point.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    if(-not $Context.ProjectConfig.ContainsKey("Files")){ return }
    if(-not $Context.ProjectConfig.Files.ContainsKey("EntryPoint")){ return }

    $entryPoint = [string]$Context.ProjectConfig.Files.EntryPoint

    if([string]::IsNullOrWhiteSpace($entryPoint)){ return }

    $entryPointPath = Join-Path -Path $ProjectPath -ChildPath $entryPoint

    if(-not (Test-Path -LiteralPath $entryPointPath -PathType Leaf)){ return }

    try {
        Start-Process -FilePath $entryPointPath -WorkingDirectory $ProjectPath -ErrorAction Stop
    } catch {
        Show-JwInstallerMessage `
            -Message "The project was installed successfully, but its entry point could not be started.`r`n`r`n$($_.Exception.Message)" `
            -Title "JW Installer" `
            -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
}

function Install-JwProjectPackage {
    <#
    .SYNOPSIS
        Executes the complete JW project installation process.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageRoot
    )

    $installerContext = Get-JwInstallerContext -PackageRoot $PackageRoot
    $context = $installerContext.Context
    $collectionName = Get-JwCollectionName -Context $context
    $collectionPath = Select-JwCollectionPath -Context $context -CollectionName $collectionName

    if([string]::IsNullOrWhiteSpace($collectionPath)){ return $false }

    if(-not (Test-JwWritableDirectory -Path $collectionPath)){
        throw "The selected JW Collection directory is not writable: $collectionPath"
    }

    $collectionCorePath = Join-Path -Path $collectionPath -ChildPath ".core"

    Install-JwCollectionFiles `
        -PackageRoot $PackageRoot `
        -CollectionPath $collectionPath

    Install-JwCore `
        -PackageCorePath $installerContext.CorePath `
        -CollectionCorePath $collectionCorePath

    $installedProjectPath = Install-JwProject `
        -PackageProjectPath $installerContext.ProjectPath `
        -CollectionPath $collectionPath `
        -Project $installerContext.Project

    Install-JwProjectManifest `
        -PackageManifestPath $installerContext.ManifestPath `
        -ProjectPath $installedProjectPath

    Save-JwCollectionPath `
        -Context $context `
        -CollectionPath $collectionPath

    $projectName = [string]$installerContext.Manifest.Project.Name
    $version = [string]$installerContext.Manifest.Build.Version

    $message = "$projectName $version was installed successfully.`r`n`r`nCollection:`r`n$collectionPath`r`n`r`nProject:`r`n$installedProjectPath`r`n`r`nLaunch the project now?"

    $result = Show-JwInstallerMessage `
        -Message $message `
        -Title "JW Installer" `
        -Buttons ([System.Windows.Forms.MessageBoxButtons]::YesNo) `
        -Icon ([System.Windows.Forms.MessageBoxIcon]::Information)

    if($result -eq [System.Windows.Forms.DialogResult]::Yes){
        Start-JwInstalledProject `
            -Context $context `
            -ProjectPath $installedProjectPath
    }

    return $true
}

$packageRoot = Split-Path -Path $PSScriptRoot -Parent

try {
    $installed = Install-JwProjectPackage -PackageRoot $packageRoot
    if(-not $installed){ exit 0 }
    exit 0
} catch {
    Show-JwInstallerMessage `
        -Message ("Installation failed.`r`n`r`n" + $_.Exception.Message) `
        -Title "JW Installer" `
        -Icon ([System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null

    exit 1
}
