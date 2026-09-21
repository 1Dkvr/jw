<#
.SYNOPSIS
    Builds a JW Countdown release package.

.DESCRIPTION
    Validates the shared JW Countdown configuration, prepares the files required for distribution, generates the release manifest with SHA-256 hashes, and creates the versioned ZIP package used by the update system.
    The build process uses JwCountdown.config.psd1 as the single source of truth for project metadata, package naming and runtime file references.
    The generated manifest is included in the release package and is never maintained manually.

.NOTES
    Product      : JW Countdown
    Component    : Release build tool
    Created      : 26.09.01
    Developer    : 1Dkvr
    Licensor     : Hold'inCorp.
    Platform     : Microsoft Windows
    Runtime      : Windows PowerShell 5.1+
    Dependencies : System.IO.Compression, System.IO.Compression.FileSystem
    License      : Custom Non-Commercial Source-Available
    License URL  : https://github.com/1Dkvr/jw/blob/main/LICENSE.md

    Copyright © 2026 [Licensor]. All rights reserved.

    This source code is subject to the terms and conditions defined in the 'LICENSE.md' file located in the root directory of this repository or online at the URL above.
    No external module or third-party dependency is required.
    Future release tooling may add package integrity and Authenticode signature verification without changing the countdown application itself.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:OutputDirectoryName = "dist"

function ConvertTo-JWCountdownVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $match = [regex]::Match($Value, '\d+(?:\.\d+){1,3}')

    if(-not $match.Success){ throw "Invalid version: $Value" }

    return [System.Version]::Parse($match.Value)
}

function Import-JWCountdownConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){
        throw "The JW Countdown configuration file was not found: $Path"
    }

    try {
        return Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    } catch {
        throw "The JW Countdown configuration could not be loaded: $($_.Exception.Message)"
    }
}

function Find-JWCountdownConfig {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectDirectory
    )

    $configurationFiles = @(
        Get-ChildItem `
            -LiteralPath $ProjectDirectory `
            -File `
            -Filter "*.config.psd1" `
            -ErrorAction Stop
    )

    if($configurationFiles.Count -eq 0){
        throw "No configuration file matching '*.config.psd1' was found."
    }

    if($configurationFiles.Count -gt 1){
        $fileNames = ($configurationFiles.Name -join ", ")
        throw "Multiple configuration files were found: $fileNames"
    }

    return $configurationFiles[0].FullName
}

function Test-JWCountdownConfiguration {
    param(
        [Parameter(Mandatory)]
        $Config
    )

    foreach($sectionName in @("Project", "GitHub", "Files", "Package", "Runtime")){
        if(-not $Config.ContainsKey($sectionName)){
            throw "The configuration is missing the '$sectionName' section."
        }
    }

    foreach($propertyName in @("Name", "Version", "Developer", "Publisher")){
        if([string]::IsNullOrWhiteSpace([string]$Config.Project.$propertyName)){
            throw "The configuration is missing Project.$propertyName."
        }
    }

    foreach($propertyName in @("Owner", "Repository", "Project", "ApiVersion")){
        if([string]::IsNullOrWhiteSpace([string]$Config.GitHub.$propertyName)){
            throw "The configuration is missing GitHub.$propertyName."
        }
    }

    foreach($propertyName in @("Config", "EntryPoint", "Application", "Launcher", "Updater", "Manifest")){
        if([string]::IsNullOrWhiteSpace([string]$Config.Files.$propertyName)){
            throw "The configuration is missing Files.$propertyName."
        }
    }

    foreach($propertyName in @("Prefix", "Extension")){
        if([string]::IsNullOrWhiteSpace([string]$Config.Package.$propertyName)){
            throw "The configuration is missing Package.$propertyName."
        }
    }

    if([string]::IsNullOrWhiteSpace([string]$Config.Runtime.ApplicationMutexName)){
        throw "The configuration is missing Runtime.ApplicationMutexName."
    }

    ConvertTo-JWCountdownVersion $Config.Project.Version | Out-Null

    if([string]$Config.Package.Extension -ne ".zip"){
        throw "The configured package extension must be '.zip'."
    }
}

function Test-JWCountdownConfigPath {
    param(
        [Parameter(Mandatory)]
        [string]$ConfigurationPath,

        [Parameter(Mandatory)]
        $Config
    )

    $configuredName = [string]$Config.Files.Config
    $actualName = [System.IO.Path]::GetFileName($ConfigurationPath)

    if(-not $actualName.Equals($configuredName, [System.StringComparison]::OrdinalIgnoreCase)){
        throw "The discovered configuration file does not match Files.Config."
    }
}

function Normalize-JWCountdownRelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if([string]::IsNullOrWhiteSpace($Path)){
        throw "An empty file path is not allowed."
    }

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

function Get-JWCountdownSourcePath {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectDirectory,

        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $normalized = Normalize-JWCountdownRelativePath $RelativePath

    $root = [System.IO.Path]::GetFullPath($ProjectDirectory).TrimEnd('\') + '\'

    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectDirectory ($normalized.Replace('/', '\'))))

    if(-not $fullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)){
        throw "The configured file is outside the project directory: $RelativePath"
    }

    return $fullPath
}

function Get-JWCountdownRuntimeFiles {
    param(
        [Parameter(Mandatory)]
        $Config
    )

    $files = New-Object System.Collections.Generic.List[string]

    foreach($property in $Config.Files.PSObject.Properties){
        if($property.Name -eq "Manifest"){ continue }

        $relativePath = Normalize-JWCountdownRelativePath ([string]$property.Value)

        if(-not $files.Contains($relativePath)){ $files.Add($relativePath) }
    }

    if($files.Count -eq 0){
        throw "No runtime files are defined in the configuration."
    }

    return $files.ToArray()
}

function Copy-JWCountdownRuntimeFiles {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectDirectory,

        [Parameter(Mandatory)]
        [string]$StageDirectory,

        [Parameter(Mandatory)]
        [string[]]$RuntimeFiles
    )

    foreach($relativePath in $RuntimeFiles){
        $sourcePath = Get-JWCountdownSourcePath `
            -ProjectDirectory $ProjectDirectory `
            -RelativePath $relativePath

        if(-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)){
            throw "Required release file was not found: $relativePath"
        }

        $destinationPath = Join-Path $StageDirectory ($relativePath.Replace('/', '\'))

        $destinationDirectory = Split-Path -Path $destinationPath -Parent

        New-Item `
            -ItemType Directory `
            -Path $destinationDirectory `
            -Force `
            -ErrorAction Stop | Out-Null

        Copy-Item `
            -LiteralPath $sourcePath `
            -Destination $destinationPath `
            -Force `
            -ErrorAction Stop
    }
}

function New-JWCountdownManifest {
    param(
        [Parameter(Mandatory)]
        [string]$StageDirectory,

        [Parameter(Mandatory)]
        $Config
    )

    $files = New-Object System.Collections.Generic.List[object]

    $stageRoot = [System.IO.Path]::GetFullPath($StageDirectory).TrimEnd('\') + '\'

    $stageFiles = @(
        Get-ChildItem `
            -LiteralPath $StageDirectory `
            -File `
            -Recurse `
            -Force `
            -ErrorAction Stop
    )

    foreach($file in $stageFiles){
        $relativePath = $file.FullName.Substring($stageRoot.Length).Replace('\', '/')

        if($relativePath -eq (Normalize-JWCountdownRelativePath $Config.Files.Manifest)){ continue }

        $hash = (
            Get-FileHash `
                -LiteralPath $file.FullName `
                -Algorithm SHA256 `
                -ErrorAction Stop
        ).Hash.ToLowerInvariant()

        $files.Add([ordered]@{
            Path   = $relativePath
            SHA256 = $hash
        })
    }

    if($files.Count -eq 0){ throw "No files were found in the release staging directory." }

    $manifest = [ordered]@{
        Product = $Config.Project.Name
        Version = $Config.Project.Version
        Files   = $files.ToArray()
    }

    $manifestPath = Join-Path `
        $StageDirectory `
        (Normalize-JWCountdownRelativePath $Config.Files.Manifest)

    $json = $manifest | ConvertTo-Json -Depth 5
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText($manifestPath, $json, $utf8NoBom)

    return $manifestPath
}

function Test-JWCountdownManifest {
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath,

        [Parameter(Mandatory)]
        [string]$StageDirectory,

        [Parameter(Mandatory)]
        $Config
    )

    if(-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)){
        throw "The generated manifest was not found."
    }

    try {
        $manifest = Get-Content `
            -LiteralPath $ManifestPath `
            -Raw `
            -ErrorAction Stop |
            ConvertFrom-Json `
            -ErrorAction Stop
    } catch {
        throw "The generated manifest could not be read: $($_.Exception.Message)"
    }

    if($manifest.Product -ne $Config.Project.Name){
        throw "The generated manifest contains an invalid product name."
    }

    if(
        (ConvertTo-JWCountdownVersion $manifest.Version) -ne
        (ConvertTo-JWCountdownVersion $Config.Project.Version)
    ){
        throw "The generated manifest contains an invalid version."
    }

    $manifestFiles = @($manifest.Files)

    if($manifestFiles.Count -eq 0){
        throw "The generated manifest does not contain any files."
    }

    $declaredPaths = @{}

    foreach($entry in $manifestFiles){
        $relativePath = Normalize-JWCountdownRelativePath $entry.Path
        $key = $relativePath.ToLowerInvariant()

        if($declaredPaths.ContainsKey($key)){
            throw "The generated manifest contains a duplicate file: $relativePath"
        }

        $declaredPaths[$key] = $true

        if($entry.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){
            throw "The generated manifest contains an invalid SHA-256 value: $relativePath"
        }

        $filePath = Join-Path $StageDirectory ($relativePath.Replace('/', '\'))

        if(-not (Test-Path -LiteralPath $filePath -PathType Leaf)){
            throw "The generated manifest references a missing file: $relativePath"
        }

        $actualHash = (
            Get-FileHash `
                -LiteralPath $filePath `
                -Algorithm SHA256 `
                -ErrorAction Stop
        ).Hash

        if($actualHash -ine $entry.SHA256){
            throw "Manifest hash verification failed: $relativePath"
        }
    }

    foreach($property in $Config.Files.PSObject.Properties){
        if($property.Name -eq "Manifest"){ continue }

        $relativePath = Normalize-JWCountdownRelativePath ([string]$property.Value)

        $key = $relativePath.ToLowerInvariant()

        if(-not $declaredPaths.ContainsKey($key)){
            throw "The generated manifest is missing the configured file: $relativePath"
        }
    }

    return $manifest
}

function New-JWCountdownPackage {
    param(
        [Parameter(Mandatory)]
        [string]$StageDirectory,

        [Parameter(Mandatory)]
        [string]$PackagePath
    )

    if(Test-Path -LiteralPath $PackagePath){
        Remove-Item -LiteralPath $PackagePath -Force -ErrorAction Stop
    }

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $StageDirectory,
        $PackagePath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    if(-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)){
        throw "The release package was not created."
    }
}

function Test-JWCountdownPackage {
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        $Config
    )

    $zip = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    $expectedFiles = @{}

    try {
        foreach($property in $Config.Files.PSObject.Properties){
            $relativePath = Normalize-JWCountdownRelativePath ([string]$property.Value)

            $expectedFiles[$relativePath.ToLowerInvariant()] = $relativePath
        }

        $manifestPath = Normalize-JWCountdownRelativePath (
            [string]$Config.Files.Manifest
        )

        $expectedFiles[$manifestPath.ToLowerInvariant()] = $manifestPath

        $actualFiles = @{}

        foreach($entry in $zip.Entries){
            if($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')){ continue }

            $relativePath = Normalize-JWCountdownRelativePath $entry.FullName
            $key = $relativePath.ToLowerInvariant()

            if($actualFiles.ContainsKey($key)){
                throw "The release package contains a duplicate file: $relativePath"
            }

            $actualFiles[$key] = $relativePath
        }

        foreach($expected in $expectedFiles.GetEnumerator()){
            if(-not $actualFiles.ContainsKey($expected.Key)){
                throw "The release package is missing: $($expected.Value)"
            }
        }

        foreach($actual in $actualFiles.GetEnumerator()){
            if(-not $expectedFiles.ContainsKey($actual.Key)){
                throw "The release package contains an unexpected file: $($actual.Value)"
            }
        }
    } finally {
        $zip.Dispose()
    }
}

$projectDirectory = $PSScriptRoot
$configurationPath = $null
$workingDirectory = $null

try {
    Write-Host "Building JW Countdown release..."

    $configurationPath = Find-JWCountdownConfig -ProjectDirectory $projectDirectory

    $config = Import-JWCountdownConfig -Path $configurationPath

    Test-JWCountdownConfiguration -Config $config

    Test-JWCountdownConfigPath -ConfigurationPath $configurationPath -Config $config

    $version = ConvertTo-JWCountdownVersion $config.Project.Version

    $versionString = $version.ToString()

    $runtimeFiles = Get-JWCountdownRuntimeFiles -Config $config

    $outputDirectory = Join-Path $projectDirectory $script:OutputDirectoryName

    New-Item `
        -ItemType Directory `
        -Path $outputDirectory `
        -Force `
        -ErrorAction Stop | Out-Null

    $packageName = "$($config.Package.Prefix)-$versionString$($config.Package.Extension)"

    $packagePath = Join-Path $outputDirectory $packageName

    $buildId = [guid]::NewGuid().ToString("N")

    $workingDirectory = Join-Path $env:TEMP "JWCountdownBuild-$buildId"

    $stageDirectory = Join-Path $workingDirectory "package"

    New-Item `
        -ItemType Directory `
        -Path $stageDirectory `
        -Force `
        -ErrorAction Stop | Out-Null

    try {
        Write-Host "Preparing release files..."

        Copy-JWCountdownRuntimeFiles `
            -ProjectDirectory $projectDirectory `
            -StageDirectory $stageDirectory `
            -RuntimeFiles $runtimeFiles

        Write-Host "Generating release manifest..."

        $manifestPath = New-JWCountdownManifest -StageDirectory $stageDirectory -Config $config

        Write-Host "Validating release manifest..."

        Test-JWCountdownManifest `
            -ManifestPath $manifestPath `
            -StageDirectory $stageDirectory `
            -Config $config | Out-Null

        Write-Host "Creating release package..."

        New-JWCountdownPackage -StageDirectory $stageDirectory -PackagePath $packagePath

        Write-Host "Validating release package..."

        Test-JWCountdownPackage -PackagePath $packagePath -Config $config

        $packageHash = (
            Get-FileHash `
                -LiteralPath $packagePath `
                -Algorithm SHA256 `
                -ErrorAction Stop
        ).Hash.ToLowerInvariant()

        $packageSize = (Get-Item -LiteralPath $packagePath -ErrorAction Stop).Length

        Write-Host ""
        Write-Host "Release package created successfully."
        Write-Host "Version : $versionString"
        Write-Host "Package : $packagePath"
        Write-Host "Size    : $packageSize bytes"
        Write-Host "SHA-256 : $packageHash"
    } finally {
        if($workingDirectory -and (Test-Path -LiteralPath $workingDirectory)){
            Remove-Item `
                -LiteralPath $workingDirectory `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
} catch {
    Write-Error "Release build failed: $($_.Exception.Message)"
    exit 1
}

exit 0
