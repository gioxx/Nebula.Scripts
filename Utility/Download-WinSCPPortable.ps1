<#PSScriptInfo
.VERSION 1.1.0
.GUID a3f9c812-5e2b-4d7a-b1f6-8c3e0d9a4b7e
.AUTHOR Giovanni Solone
.TAGS powershell winscp portable download tools
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/gioxx/Nebula.Scripts/blob/main/Utility/Download-WinSCPPortable.ps1
.RELEASENOTES
v1.1.0 (2026-05-07): Added ShowProgress and switched extraction to a temporary folder workflow for more reliable file deployment. Preserve both WinSCPnet.dll variants for Windows PowerShell 5.1 and PowerShell 7.
v1.0.0 (2026-03-26): Initial release.
#>

#Requires -Version 7.0

<#
.SYNOPSIS
Downloads the latest WinSCP Portable version (and optionally the .NET assembly / COM library) to a specified folder.

.DESCRIPTION
This script checks the official WinSCP download page, retrieves the latest version number, and downloads
the portable ZIP package directly from winscp.net by extracting the tokenized download URL from the
download page. It extracts the contents into a temporary folder and copies them to the destination
folder. Optionally, the .NET assembly / COM library ZIP can also be downloaded, preserving both
WinSCPnet.dll variants so the portable layout works with Windows PowerShell 5.1 and PowerShell 7.
If the destination folder already contains files from the same version, the download is skipped.

.PARAMETER Destination
The folder where the portable files will be extracted. Must be specified.

.PARAMETER IncludeDotNet
If specified, also downloads the .NET assembly / COM library package and extracts both WinSCPnet.dll variants.

.PARAMETER ShowProgress
If specified, displays additional progress information while downloading and extracting files.

.EXAMPLE
.\Download-WinSCPPortable.ps1 -Destination "C:\Tools\WinSCP"
Downloads the latest WinSCP portable package and extracts it to C:\Tools\WinSCP.

.EXAMPLE
.\Download-WinSCPPortable.ps1 -Destination "C:\Tools\WinSCP" -IncludeDotNet
Downloads the portable package and extracts both WinSCPnet.dll variants to C:\Tools\WinSCP.

.EXAMPLE
.\Download-WinSCPPortable.ps1 -Destination "C:\Tools\WinSCP" -IncludeDotNet -ShowProgress
Downloads the portable package and shows additional progress details while extracting files.

.NOTES
[Reflection.Assembly]::LoadFile("C:\path\file.dll").ImageRuntimeVersion to check .NET version of a DLL file.
#>

param (
    [Parameter(Mandatory = $true)]
    [string] $Destination,
    [switch] $IncludeDotNet,
    [switch] $ShowProgress
)

function Write-ProgressMessage {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if ($ShowProgress) {
        Write-Host $Message
    }
}

function Resolve-DestinationPath {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    $basePath = (Get-Location).ProviderPath
    return [System.IO.Path]::GetFullPath((Join-Path -Path $basePath -ChildPath $Path))
}

function New-DirectoryIfMissing {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function New-TempExtractionFolder {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Prefix
    )

    $tempRoot = [System.IO.Path]::GetTempPath()
    $tempFolder = Join-Path $tempRoot ("{0}_{1}" -f $Prefix, [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null
    return $tempFolder
}

function Copy-FolderContentsWithRetry {
    param (
        [Parameter(Mandatory = $true)]
        [string] $SourceFolder,

        [Parameter(Mandatory = $true)]
        [string] $DestinationFolder
    )

    $maxRetries = 3
    $attempt = 0

    while ($attempt -lt $maxRetries) {
        try {
            Copy-Item -Path (Join-Path $SourceFolder '*') -Destination $DestinationFolder -Recurse -Force -ErrorAction Stop
            return
        }
        catch {
            $attempt++
            if ($attempt -lt $maxRetries) {
                Start-Sleep -Seconds 2
            }
            else {
                throw
            }
        }
    }
}

function Copy-FileWithRetry {
    param (
        [Parameter(Mandatory = $true)]
        [string] $SourceFile,

        [Parameter(Mandatory = $true)]
        [string] $DestinationFile
    )

    New-DirectoryIfMissing -Path (Split-Path -Path $DestinationFile -Parent)

    $maxRetries = 3
    $attempt = 0

    while ($attempt -lt $maxRetries) {
        try {
            Copy-Item -LiteralPath $SourceFile -Destination $DestinationFile -Force -ErrorAction Stop
            return
        }
        catch {
            $attempt++
            if ($attempt -lt $maxRetries) {
                Write-ProgressMessage "  $([System.IO.Path]::GetFileName($DestinationFile)) is locked, retrying in 3 seconds... (attempt $attempt/$maxRetries)"
                Start-Sleep -Seconds 3
            }
            else {
                throw
            }
        }
    }
}

function Get-WinSCPVersion {
    $WinSCP_URL = "https://winscp.net/eng/download.php"
    $response = Invoke-WebRequest -Uri $WinSCP_URL -UseBasicParsing
    $versionRegex = 'WinSCP-(\d+\.\d+\.\d+)-Setup\.exe'
    $versionMatch = [regex]::Match($response.Content, $versionRegex)
    if (-not $versionMatch.Success) {
        Write-Error "Version number not found on WinSCP download page."
        exit 1
    }
    return $versionMatch.Groups[1].Value
}

function Test-AlreadyUpToDate {
    param (
        [string] $FilePath,
        [string] $Version
    )
    if (Test-Path $FilePath) {
        $fileVersion = (Get-Item $FilePath).VersionInfo.FileVersion -replace ',', '.' -replace ' ', ''
        if ($fileVersion -like "$Version*") {
            return $true
        }
    }
    return $false
}

function Get-WinSCPPackage {
    param (
        [string] $Version,
        [string] $FileName,
        [string] $DisplayName
    )
    $tempPath = [System.IO.Path]::GetTempPath()
    $zipFile = Join-Path $tempPath $FileName

    $downloadPageUrl = "https://winscp.net/download/$FileName/download"
    Write-ProgressMessage "Downloading $DisplayName..."

    # Load the download page to extract the tokenized URL
    $response = Invoke-WebRequest -Uri $downloadPageUrl -UseBasicParsing -SessionVariable session -MaximumRedirection 10

    if ($response.Content -notmatch '/download/files/[^\s"'']+') {
        Write-Error "Could not find tokenized download URL in WinSCP download page."
        exit 1
    }
    $tokenizedUrl = "https://winscp.net" + $matches[0]
    Write-ProgressMessage "Token URL: $tokenizedUrl"

    # Download the actual file using the tokenized URL and the session cookie
    Invoke-WebRequest -Uri $tokenizedUrl -OutFile $zipFile -UseBasicParsing -WebSession $session

    # Verify it's a valid ZIP (PK header: 80 75)
    $fileHeader = Get-Content -Path $zipFile -AsByteStream -TotalCount 2
    if ($fileHeader[0] -ne 80 -or $fileHeader[1] -ne 75) {
        Write-Error "The downloaded file does not appear to be a valid ZIP archive."
        Remove-Item -LiteralPath $zipFile -Force
        exit 1
    }

    return $zipFile
}

function Expand-DotNetDll {
    param (
        [string] $ZipPath,
        [string] $Destination
    )
    $tempFolder = New-TempExtractionFolder -Prefix 'WinSCP_Automation'

    function Resolve-SourceFile {
        param (
            [Parameter(Mandatory = $true)]
            [string] $BasePath,

            [Parameter(Mandatory = $true)]
            [string[]] $Candidates
        )

        foreach ($candidate in $Candidates) {
            $candidatePath = Join-Path $BasePath $candidate
            if (Test-Path -LiteralPath $candidatePath) {
                return (Get-Item -LiteralPath $candidatePath).FullName
            }
        }

        return $null
    }

    try {
        Expand-Archive -Path $ZipPath -DestinationPath $tempFolder -Force

        $rootSource = Resolve-SourceFile -BasePath $tempFolder -Candidates @(
            'WinSCPnet.dll'
            'net40\WinSCPnet.dll'
        )

        if (-not $rootSource) {
            $rootSource = Get-ChildItem -Path $tempFolder -Filter 'WinSCPnet.dll' -Recurse -File |
                Where-Object { $_.FullName -notmatch 'netstandard2\.0' } |
                Select-Object -First 1 -ExpandProperty FullName
        }

        if (-not $rootSource) {
            Write-Error "WinSCPnet.dll not found in the ZIP archive."
            exit 1
        }

        Copy-FileWithRetry -SourceFile $rootSource -DestinationFile (Join-Path $Destination 'WinSCPnet.dll')
        Write-ProgressMessage "  Extracted: WinSCPnet.dll"

        $netstandardSource = Resolve-SourceFile -BasePath $tempFolder -Candidates @(
            'netstandard2.0\WinSCPnet.dll'
        )

        if (-not $netstandardSource) {
            $netstandardSource = Get-ChildItem -Path $tempFolder -Filter 'WinSCPnet.dll' -Recurse -File |
                Where-Object { $_.FullName -match 'netstandard2\.0' } |
                Select-Object -First 1 -ExpandProperty FullName
        }

        if (-not $netstandardSource) {
            Write-Error "WinSCPnet.dll not found under netstandard2.0 in the ZIP archive."
            exit 1
        }

        Copy-FileWithRetry -SourceFile $netstandardSource -DestinationFile (Join-Path $Destination 'netstandard2.0\WinSCPnet.dll')
        Write-ProgressMessage "  Extracted: netstandard2.0\WinSCPnet.dll"
    }
    finally {
        if (Test-Path -LiteralPath $tempFolder) {
            Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Main ---

$Destination = Resolve-DestinationPath -Path $Destination

$version = Get-WinSCPVersion
Write-Output "Latest WinSCP version: $version"

# Create destination folder if it doesn't exist
if (-not (Test-Path -LiteralPath $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Write-ProgressMessage "Created destination folder: $Destination"
}

# Portable package
$exePath = Join-Path $Destination "WinSCP.exe"
if (Test-AlreadyUpToDate -FilePath $exePath -Version $version) {
    Write-Output "WinSCP $version portable is already up to date in: $Destination"
}
    else {
        $zipFile = Get-WinSCPPackage -Version $version -FileName "WinSCP-$version-Portable.zip" -DisplayName "WinSCP $version Portable"
        Write-ProgressMessage "Extracting to: $Destination"
        $tempFolder = New-TempExtractionFolder -Prefix 'WinSCP_Portable'
        try {
            Expand-Archive -Path $zipFile -DestinationPath $tempFolder -Force
            Copy-FolderContentsWithRetry -SourceFolder $tempFolder -DestinationFolder $Destination
        Write-Output "Portable package ready in: $Destination"
    }
    finally {
        if (Test-Path -LiteralPath $tempFolder) {
            Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue
    }
}

# .NET assembly / COM library (optional)
if ($IncludeDotNet) {
    $dllPath = Join-Path $Destination "WinSCPnet.dll"
    if (Test-AlreadyUpToDate -FilePath $dllPath -Version $version) {
        Write-Output "WinSCPnet.dll $version is already up to date in: $Destination"
    }
    else {
        $zipFile = Get-WinSCPPackage -Version $version -FileName "WinSCP-$version-Automation.zip" -DisplayName "WinSCP $version .NET assembly / COM library"
        Write-ProgressMessage "Extracting WinSCPnet.dll variants to: $Destination"
        Expand-DotNetDll -ZipPath $zipFile -Destination $Destination
        Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue
        Write-Output ".NET assembly ready in: $Destination"
    }
}
