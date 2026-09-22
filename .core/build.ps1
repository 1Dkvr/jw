<#
.SYNOPSIS
    Builds a distributable JW project package.

.DESCRIPTION
    Creates a versioned project package from the shared JW Core and the selected project. The build process generates the build version, prepares the installation structure, generates the project manifest, creates the ZIP package and produces a SHA-256 checksum.

.NOTES
    Product      : JW Core
    Component    : Project build
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

function Copy-JwBuildFile {
    <#
    .SYNOPSIS
        Copies a file into the build staging directory.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath
    )

    if(-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)){
        throw "Build source file was not found: $SourcePath"
    }

    $destinationDirectory = Split-Path -Path $DestinationPath -Parent

    if(
        -not [string]::IsNullOrWhiteSpace($destinationDirectory) -and
        -not (Test-Path -LiteralPath $destinationDirectory -PathType Container)
    ){
        New-Item -ItemType Directory -Path $destinationDirectory -Force -ErrorAction Stop | Out-Null
    }

    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force -ErrorAction Stop
}

function New-JwInstallLauncher {
    <#
    .SYNOPSIS
        Creates the generic installation launcher for a JW package.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath
    )

    $content = @'
@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0.core\installer.ps1"
set "exitCode=%ERRORLEVEL%"
endlocal & exit /b %exitCode%
'@

    Set-Content `
        -LiteralPath $DestinationPath `
        -Value $content `
        -Encoding ASCII `
        -ErrorAction Stop
}

function New-JwManifest {
    <#
    .SYNOPSIS
        Creates the machine-readable manifest for a JW build.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Version,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TagName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath
    )

    $versionInfo = Get-JwVersionInfo -Version $Version

    $manifest = [ordered]@{
        Project = @{
            Directory = $Context.Project
            Name      = [string]$Context.ProjectConfig.Project.Name
        }

        Repository = @{
            Owner      = $Context.RepositoryOwner
            Name       = $Context.Repository
            FullName   = "$($Context.RepositoryOwner)/$($Context.Repository)"
        }

        Build = @{
            Version       = $Version
            VersionPrefix = $versionInfo.VersionPrefix
            Build         = $versionInfo.Build
            BuiltUtc      = [DateTimeOffset]::UtcNow.ToString("o")
        }

        Release = @{
            Tag     = $TagName
            Package = $PackageName
        }
    }

    $manifest | ConvertTo-Json -Depth 10 | Set-Content `
        -LiteralPath $DestinationPath `
        -Encoding UTF8 `
        -ErrorAction Stop
}

function New-JwProjectBuild {
    <#
    .SYNOPSIS
        Builds a complete distributable JW project package.

    .PARAMETER RepositoryRoot
        Absolute path to the JW repository root.

    .PARAMETER Project
        Name of the project directory.

    .PARAMETER OutputRoot
        Directory used for generated build files.

    .OUTPUTS
        PSCustomObject
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Project,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$OutputRoot = ".build"
    )

    $corePath = Join-Path -Path $RepositoryRoot -ChildPath ".core"
    $initializeScriptPath = Join-Path -Path $corePath -ChildPath "initialize.ps1"
    $versionScriptPath = Join-Path -Path $corePath -ChildPath "version.ps1"

    if(-not (Test-Path -LiteralPath $initializeScriptPath -PathType Leaf)){
        throw "Initialization script was not found: $initializeScriptPath"
    }

    if(-not (Test-Path -LiteralPath $versionScriptPath -PathType Leaf)){
        throw "Version script was not found: $versionScriptPath"
    }

    . $initializeScriptPath
    . $versionScriptPath

    $context = Initialize-JwContext `
        -RepositoryRoot $RepositoryRoot `
        -Project $Project

    if(-not $context.ProjectConfig.Project.ContainsKey("VersionPrefix")){
        throw "The project configuration does not define 'Project.VersionPrefix'."
    }

    $versionPrefix = [string]$context.ProjectConfig.Project.VersionPrefix

    if(-not (Test-JwVersion -Version (New-JwVersion -VersionPrefix $versionPrefix -Build 1))){
        throw "Invalid project version prefix: $versionPrefix"
    }

    $outputRootPath = [System.IO.Path]::GetFullPath(
        (Join-Path -Path $RepositoryRoot -ChildPath $OutputRoot)
    )

    $projectOutputPath = Join-Path -Path $outputRootPath -ChildPath $context.Project
    $stagingRoot = Join-Path -Path $projectOutputPath -ChildPath "staging"

    if(-not (Test-Path -LiteralPath $projectOutputPath -PathType Container)){
        New-Item -ItemType Directory -Path $projectOutputPath -Force -ErrorAction Stop | Out-Null
    }

    if(Test-Path -LiteralPath $stagingRoot){
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction Stop
    }

    New-Item -ItemType Directory -Path $stagingRoot -Force -ErrorAction Stop | Out-Null

    do {
        $version = New-JwVersion -VersionPrefix $versionPrefix
        $packageName = "$($context.ProductIdentifier)-$version$($context.PackageExtension)"
        $packagePath = Join-Path -Path $projectOutputPath -ChildPath $packageName
    } 
    while(Test-Path -LiteralPath $packagePath)

    $tagName = "$($context.Project.ToLowerInvariant())-$version"

    $runtimeCoreFiles = @(
        "config.psd1",
        "initialize.ps1",
        "version.ps1",
        "github.ps1",
        "updater.ps1",
        "installer.ps1"
    )

    $runtimeCorePath = Join-Path -Path $stagingRoot -ChildPath ".core"

    foreach($coreFile in $runtimeCoreFiles){
        $sourcePath = Join-Path -Path $corePath -ChildPath $coreFile
        $destinationPath = Join-Path -Path $runtimeCorePath -ChildPath $coreFile

        Copy-JwBuildFile -SourcePath $sourcePath -DestinationPath $destinationPath
    }

    $projectOutputDirectory = Join-Path -Path $stagingRoot -ChildPath $context.Project

    if(-not (Test-Path -LiteralPath $projectOutputDirectory -PathType Container)){
        New-Item -ItemType Directory -Path $projectOutputDirectory -Force -ErrorAction Stop | Out-Null
    }

    $projectConfigSource = $context.ProjectConfigPath
    $projectConfigDestination = Join-Path -Path $projectOutputDirectory -ChildPath "config.psd1"

    Copy-JwBuildFile -SourcePath $projectConfigSource -DestinationPath $projectConfigDestination

    if(-not $context.ProjectConfig.ContainsKey("Files")){
        throw "The project configuration does not contain a 'Files' section."
    }

    $projectFiles = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    foreach($fileValue in @($context.ProjectConfig.Files.Values)){
        foreach($fileName in @($fileValue)){
            if([string]::IsNullOrWhiteSpace([string]$fileName)){ continue }
            [void]$projectFiles.Add([string]$fileName)
        }
    }

    foreach($fileName in $projectFiles){
        $sourcePath = Join-Path -Path $context.ProjectPath -ChildPath $fileName
        $destinationPath = Join-Path -Path $projectOutputDirectory -ChildPath $fileName

        Copy-JwBuildFile -SourcePath $sourcePath -DestinationPath $destinationPath
    }

    $manifestPath = Join-Path -Path $runtimeCorePath -ChildPath "manifest.json"

    New-JwManifest `
        -Context $context `
        -Version $version `
        -TagName $tagName `
        -PackageName $packageName `
        -DestinationPath $manifestPath

    # Installation launcher: temporary package entry point. It is generated for the distributed package and is not installed into JwCollection.
    $installerPath = Join-Path -Path $stagingRoot -ChildPath "install.bat"

    New-JwInstallLauncher -DestinationPath $installerPath

    $licenseSource = Join-Path -Path $RepositoryRoot -ChildPath "LICENSE.md"
    $licenseDestination = Join-Path -Path $stagingRoot -ChildPath "LICENSE.md"

    if(Test-Path -LiteralPath $licenseSource -PathType Leaf){
        Copy-JwBuildFile -SourcePath $licenseSource -DestinationPath $licenseDestination
    }

    $readmeSource = Join-Path -Path $RepositoryRoot -ChildPath "README.md"
    $readmeDestination = Join-Path -Path $stagingRoot -ChildPath "README.md"

    if(Test-Path -LiteralPath $readmeSource -PathType Leaf){
        Copy-JwBuildFile -SourcePath $readmeSource -DestinationPath $readmeDestination
    }

    Compress-Archive `
        -Path (Join-Path -Path $stagingRoot -ChildPath "*") `
        -DestinationPath $packagePath `
        -CompressionLevel Optimal `
        -Force `
        -ErrorAction Stop

    $hash = (Get-FileHash `
        -LiteralPath $packagePath `
        -Algorithm SHA256 `
        -ErrorAction Stop).Hash.ToLowerInvariant()

    $checksumPath = "$packagePath.sha256"

    Set-Content `
        -LiteralPath $checksumPath `
        -Value "$hash *$packageName" `
        -Encoding ASCII `
        -ErrorAction Stop

    return [pscustomobject]@{
        Project           = $context.Project
        ProjectName       = [string]$context.ProjectConfig.Project.Name
        Version           = $version
        VersionPrefix     = $versionPrefix
        Build             = (Get-JwVersionInfo -Version $version).Build
        TagName           = $tagName
        ProductIdentifier = $context.ProductIdentifier
        PackageName       = $packageName
        PackagePath       = $packagePath
        ManifestPath      = $manifestPath
        ChecksumPath      = $checksumPath
        SHA256            = $hash
        StagingPath       = $stagingRoot
    }
}

New-JwProjectBuild `
    -RepositoryRoot $RepositoryRoot `
    -Project $Project `
    -OutputRoot $OutputRoot
