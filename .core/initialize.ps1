<#
.SYNOPSIS
    Initializes the shared JW project context.

.DESCRIPTION
    Loads the repository-wide configuration and the selected project configuration, validates the repository structure, resolves the project paths and exposes a common context object for the other JW Core scripts.
    This script contains no GitHub API logic, build logic, installation logic or update logic. Its sole responsibility is to initialize a consistent execution context for a JW project.

.PARAMETER RepositoryRoot
    Absolute path to the root of the JW repository.

.PARAMETER Project
    Name of the project directory located at the repository root.

.OUTPUTS
    PSCustomObject
    Returns an initialized JW project context.

.NOTES
    Product      : JW Core
    Component    : Project initialization
    Developer    : 1Dkvr
    Licensor     : Hold'inCorp.
    Platform     : Microsoft Windows
    Runtime      : Windows PowerShell 5.1+
    Dependencies : None
    License      : Custom Non-Commercial Source-Available
    License URL  : https://github.com/1Dkvr/jw/blob/main/LICENSE.md

    Copyright © 2019-2026 Hold'inCorp. — All rights reserved.
    Developed by 1Dkvr.
    Licensed under the Custom Non-Commercial Source-Available License.
    See `LICENSE.md` for the full license terms.

    This source code is protected by applicable copyright and other intellectual property laws. Use, reproduction, modification and redistribution are subject to the terms and conditions defined in `LICENSE.md`.

    The copyright and license notices contained in this source code must not be removed, altered or obscured without authorization.
#>

Set-StrictMode -Version Latest

function ConvertTo-JwIdentifier {
    <#
    .SYNOPSIS
        Converts a repository or project directory name to a compact PascalCase identifier.

    .DESCRIPTION
        Removes non-alphanumeric separators and converts each resulting word to
        an initial uppercase character.

        Examples:
            jw                 -> Jw
            my_project         -> MyProject

    .PARAMETER Name
        Repository or project directory name.

    .OUTPUTS
        System.String
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $parts = [System.Text.RegularExpressions.Regex]::Split($Name.Trim(), '[^A-Za-z0-9]+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if($parts.Count -eq 0){ throw "Unable to generate an identifier from '$Name'." }

    $builder = New-Object System.Text.StringBuilder

    foreach($part in $parts){
        if($part.Length -eq 1){
            [void]$builder.Append($part.ToUpperInvariant())
        } else {
            [void]$builder.Append($part.Substring(0,1).ToUpperInvariant())
            [void]$builder.Append($part.Substring(1))
        }
    }

    return $builder.ToString()
}

function Initialize-JwContext {
    <#
    .SYNOPSIS
        Initializes the execution context for a JW project.

    .PARAMETER RepositoryRoot
        Absolute path to the JW repository root.

    .PARAMETER Project
        Name of the project directory.

    .OUTPUTS
        PSCustomObject
        Initialized JW project context.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Project
    )

    try {
        $repositoryRootPath = [System.IO.Path]::GetFullPath($RepositoryRoot)
    } catch {
        throw "Invalid repository root '$RepositoryRoot'. $($_.Exception.Message)"
    }

    if(-not (Test-Path -LiteralPath $repositoryRootPath -PathType Container)){
        throw "Repository root was not found: $repositoryRootPath"
    }

    $corePath = Join-Path -Path $repositoryRootPath -ChildPath ".core"
    $globalConfigPath = Join-Path -Path $corePath -ChildPath "config.psd1"
    $projectPath = Join-Path -Path $repositoryRootPath -ChildPath $Project
    $projectConfigPath = Join-Path -Path $projectPath -ChildPath "config.psd1"

    if(-not (Test-Path -LiteralPath $corePath -PathType Container)){
        throw "JW Core directory was not found: $corePath"
    }

    if(-not (Test-Path -LiteralPath $globalConfigPath -PathType Leaf)){
        throw "Global configuration file was not found: $globalConfigPath"
    }

    if(-not (Test-Path -LiteralPath $projectPath -PathType Container)){
        throw "Project directory was not found: $projectPath"
    }

    if(-not (Test-Path -LiteralPath $projectConfigPath -PathType Leaf)){
        throw "Project configuration file was not found: $projectConfigPath"
    }

    try {
        $globalConfig = Import-PowerShellDataFile -LiteralPath $globalConfigPath -ErrorAction Stop
    } catch {
        throw "Unable to load global configuration '$globalConfigPath'. $($_.Exception.Message)"
    }

    try {
        $projectConfig = Import-PowerShellDataFile -LiteralPath $projectConfigPath -ErrorAction Stop
    } catch {
        throw "Unable to load project configuration '$projectConfigPath'. $($_.Exception.Message)"
    }

    if(-not $globalConfig.ContainsKey("GitHub")){
        throw "The global configuration does not contain a 'GitHub' section."
    }

    if(-not $globalConfig.ContainsKey("Package")){
        throw "The global configuration does not contain a 'Package' section."
    }

    if(-not $projectConfig.ContainsKey("Project")){
        throw "The project configuration does not contain a 'Project' section."
    }

    $repositoryName = [string]$globalConfig.GitHub.Repository
    $repositoryOwner = [string]$globalConfig.GitHub.Owner

    if([string]::IsNullOrWhiteSpace($repositoryName)){
        throw "GitHub.Repository is empty in the global configuration."
    }

    if([string]::IsNullOrWhiteSpace($repositoryOwner)){
        throw "GitHub.Owner is empty in the global configuration."
    }

    $projectName = [System.IO.DirectoryInfo]$projectPath
    $projectDirectoryName = $projectName.Name

    if([string]::IsNullOrWhiteSpace($projectDirectoryName)){
        throw "Unable to determine the project directory name."
    }

    $repositoryIdentifier = ConvertTo-JwIdentifier -Name $repositoryName
    $projectIdentifier = ConvertTo-JwIdentifier -Name $projectDirectoryName
    $productIdentifier = "$repositoryIdentifier$projectIdentifier"

    return [pscustomobject]@{
        RepositoryRoot        = $repositoryRootPath
        CorePath              = $corePath
        Project               = $projectDirectoryName
        ProjectPath           = $projectPath
        GlobalConfigPath      = $globalConfigPath
        ProjectConfigPath     = $projectConfigPath
        GlobalConfig          = $globalConfig
        ProjectConfig         = $projectConfig
        Repository            = $repositoryName
        RepositoryOwner       = $repositoryOwner
        RepositoryIdentifier  = $repositoryIdentifier
        ProjectIdentifier     = $projectIdentifier
        ProductIdentifier     = $productIdentifier
        PackageExtension      = [string]$globalConfig.Package.Extension
    }
}
