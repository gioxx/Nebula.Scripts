<#PSScriptInfo
.VERSION 1.0.0
.GUID a3f9c812-5e2b-4d7a-b1f6-8c3e0d9a4b7e
.AUTHOR Giovanni Solone
.TAGS powershell winscp portable download tools
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/gioxx/Nebula.Scripts/blob/main/Utility/Download-WinSCPPortable.ps1
.RELEASENOTES
v1.0.0 (2026-03-26): Initial release.
#>

#Requires -Version 7.0

<#
.SYNOPSIS
Downloads the latest WinSCP Portable version (and optionally the .NET assembly / COM library) to a specified folder.

.DESCRIPTION
This script checks the official WinSCP download page, retrieves the latest version number, and downloads
the portable ZIP package directly from winscp.net by extracting the tokenized download URL from the
download page. It extracts the contents directly into the destination folder. Optionally, the .NET
assembly / COM library ZIP can also be downloaded, extracting only WinSCPnet.dll from the selected
target framework folder (net40 by default, or netstandard2.0 if specified). If the destination folder
already contains files from the same version, the download is skipped.

.PARAMETER Destination
The folder where the portable files will be extracted. Must be specified.

.PARAMETER IncludeDotNet
If specified, also downloads the .NET assembly / COM library package and extracts only WinSCPnet.dll.

.PARAMETER DotNetTarget
The target framework folder to extract WinSCPnet.dll from. Accepted values: net40, netstandard2.0.
Defaults to net40.

.EXAMPLE
.\Download-WinSCPPortable.ps1 -Destination "C:\Tools\WinSCP"
Downloads the latest WinSCP portable package and extracts it to C:\Tools\WinSCP.

.EXAMPLE
.\Download-WinSCPPortable.ps1 -Destination "C:\Tools\WinSCP" -IncludeDotNet
Downloads the portable package and extracts WinSCPnet.dll from net40 to C:\Tools\WinSCP.

.EXAMPLE
.\Download-WinSCPPortable.ps1 -Destination "C:\Tools\WinSCP" -IncludeDotNet -DotNetTarget netstandard2.0
Downloads the portable package and extracts WinSCPnet.dll from netstandard2.0 to C:\Tools\WinSCP.

.NOTES
[Reflection.Assembly]::LoadFile("C:\path\file.dll").ImageRuntimeVersion to check .NET version of a DLL file.
#>

param (
    [Parameter(Mandatory = $true)]
    [string] $Destination,
    [switch] $IncludeDotNet,
    [ValidateSet("net40", "netstandard2.0")]
    [string] $DotNetTarget = "net40"
)

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
    Write-Host "Downloading $DisplayName..."

    # Load the download page to extract the tokenized URL
    $response = Invoke-WebRequest -Uri $downloadPageUrl -UseBasicParsing -SessionVariable session -MaximumRedirection 10

    if ($response.Content -notmatch '/download/files/[^\s"'']+') {
        Write-Error "Could not find tokenized download URL in WinSCP download page."
        exit 1
    }
    $tokenizedUrl = "https://winscp.net" + $matches[0]
    Write-Host "Token URL: $tokenizedUrl"

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

function Expand-PortableZip {
    param (
        [string] $ZipPath,
        [string] $Destination
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    $entries = $zip.Entries | Where-Object { -not $_.FullName.EndsWith('/') }

    # Read all entries into memory first, then close the ZIP before writing to disk
    $fileData = @()
    foreach ($entry in $entries) {
        $ms = [System.IO.MemoryStream]::new()
        $entryStream = $entry.Open()
        $entryStream.CopyTo($ms)
        $entryStream.Close()
        $fileData += @{ Name = (Split-Path $entry.FullName -Leaf); Bytes = $ms.ToArray() }
        $ms.Close()
    }
    $zip.Dispose()

    foreach ($file in $fileData) {
        $targetFile = Join-Path $Destination $file.Name
        [System.IO.File]::WriteAllBytes($targetFile, $file.Bytes)
        Write-Host "  Extracted: $($file.Name)"
    }
}

function Expand-DotNetDll {
    param (
        [string] $ZipPath,
        [string] $Destination,
        [string] $DotNetTarget
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)

    $entryPath = "$DotNetTarget/WinSCPnet.dll"
    $entry = $zip.Entries | Where-Object { $_.FullName -eq $entryPath } | Select-Object -First 1

    if ($null -eq $entry) {
        $zip.Dispose()
        Write-Error "WinSCPnet.dll not found in '$DotNetTarget' inside the ZIP archive."
        exit 1
    }

    # Read into memory first, then close ZIP before writing to disk
    $ms = [System.IO.MemoryStream]::new()
    $entryStream = $entry.Open()
    $entryStream.CopyTo($ms)
    $entryStream.Close()
    $zip.Dispose()

    $targetFile = Join-Path $Destination "WinSCPnet.dll"

    # Retry up to 3 times if the file is locked
    $maxRetries = 3
    $attempt = 0
    $success = $false
    while (-not $success -and $attempt -lt $maxRetries) {
        try {
            [System.IO.File]::WriteAllBytes($targetFile, $ms.ToArray())
            $success = $true
        }
        catch {
            $attempt++
            if ($attempt -lt $maxRetries) {
                Write-Host "  WinSCPnet.dll is locked, retrying in 3 seconds... (attempt $attempt/$maxRetries)"
                Start-Sleep -Seconds 3
            }
            else {
                $ms.Close()
                Write-Error "Could not write WinSCPnet.dll after $maxRetries attempts. The file may be in use by another process: $targetFile"
                exit 1
            }
        }
    }

    $ms.Close()
    Write-Host "  Extracted: WinSCPnet.dll (from $DotNetTarget)"
}

# --- Main ---

$version = Get-WinSCPVersion
Write-Output "Latest WinSCP version: $version"

# Create destination folder if it doesn't exist
if (-not (Test-Path $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Write-Output "Created destination folder: $Destination"
}

# Portable package
$exePath = Join-Path $Destination "WinSCP.exe"
if (Test-AlreadyUpToDate -FilePath $exePath -Version $version) {
    Write-Output "WinSCP $version portable is already up to date in: $Destination"
}
else {
    $zipFile = Get-WinSCPPackage -Version $version -FileName "WinSCP-$version-Portable.zip" -DisplayName "WinSCP $version Portable"
    Write-Output "Extracting to: $Destination"
    Expand-PortableZip -ZipPath $zipFile -Destination $Destination
    Remove-Item -LiteralPath $zipFile -Force
    Write-Output "Portable package ready in: $Destination"
}

# .NET assembly / COM library (optional)
if ($IncludeDotNet) {
    $dllPath = Join-Path $Destination "WinSCPnet.dll"
    if (Test-AlreadyUpToDate -FilePath $dllPath -Version $version) {
        Write-Output "WinSCPnet.dll $version is already up to date in: $Destination"
    }
    else {
        $zipFile = Get-WinSCPPackage -Version $version -FileName "WinSCP-$version-Automation.zip" -DisplayName "WinSCP $version .NET assembly / COM library"
        Write-Output "Extracting WinSCPnet.dll from $DotNetTarget to: $Destination"
        Expand-DotNetDll -ZipPath $zipFile -Destination $Destination -DotNetTarget $DotNetTarget
        Remove-Item -LiteralPath $zipFile -Force
        Write-Output ".NET assembly ready in: $Destination"
    }
}