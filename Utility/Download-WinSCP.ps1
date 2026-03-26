<#PSScriptInfo
.VERSION 1.1.0
.GUID fead021d-1d1d-483e-a78f-1329f70cc13d
.AUTHOR Giovanni Solone
.TAGS powershell winscp download tools
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/gioxx/Nebula.Scripts/blob/main/Utility/Download-WinSCP.ps1
.RELEASENOTES
v1.1.0 (2026-03-26): Switched to winscp.net tokenized download URLs, replacing SourceForge and BITS.
v1.0.0 (2026-03-19): Initial release.
#>

#Requires -Version 7.0

<#
.SYNOPSIS
Checks for available WinSCP updates for Microsoft Windows and installs the latest version.

.DESCRIPTION
This script checks the official WinSCP download page, retrieves the latest version number, extracts
the tokenized download URL directly from the download page, downloads the setup package to the system
temp folder, launches the installer, waits for it to exit, and removes the setup file automatically
when possible.

.EXAMPLE
.\Download-WinSCP.ps1
This command checks for the latest WinSCP installer, downloads it, and starts the installation.

.NOTES
[Reflection.Assembly]::LoadFile("C:\path\file.dll").ImageRuntimeVersion to check .NET version of a DLL file.
#>

$WinSCP_URL = "https://winscp.net/eng/download.php"
$Response = Invoke-WebRequest -Uri $WinSCP_URL -UseBasicParsing

$versionRegex = 'WinSCP-(\d+\.\d+\.\d+)-Setup\.exe'
$versionMatch = [regex]::Match($Response.Content, $versionRegex)

if (-not $versionMatch.Success) {
    Write-Error "Version number not found on WinSCP download page."
    exit 1
}

$version = $versionMatch.Groups[1].Value
Write-Output "Latest version found: $version"

$setupFileName = "WinSCP-$version-Setup.exe"
$downloadPageUrl = "https://winscp.net/download/$setupFileName/download"
Write-Output "Fetching download token from: $downloadPageUrl"

# Load the download page to extract the tokenized URL
$downloadPage = Invoke-WebRequest -Uri $downloadPageUrl -UseBasicParsing -SessionVariable session -MaximumRedirection 10

if ($downloadPage.Content -notmatch '/download/files/[^\s"'']+') {
    Write-Error "Could not find tokenized download URL in WinSCP download page."
    exit 1
}
$tokenizedUrl = "https://winscp.net" + $matches[0]
Write-Output "Download URL: $tokenizedUrl"

$tempPath = [System.IO.Path]::GetTempPath()
$outputFile = Join-Path -Path $tempPath -ChildPath $setupFileName

Write-Output "Downloading..."
Invoke-WebRequest -Uri $tokenizedUrl -OutFile $outputFile -UseBasicParsing -WebSession $session

# Check MZ header to verify it's a valid executable before attempting to run it
$fileHeader = Get-Content -Path $outputFile -AsByteStream -TotalCount 2
if ($fileHeader[0] -ne 77 -or $fileHeader[1] -ne 90) {
    Write-Error "The downloaded file is not a valid executable. WinSCP may have returned an HTML page instead of the binary."
    Remove-Item -LiteralPath $outputFile -Force
    exit 1
}

Write-Output "Download completed: $outputFile"
$installerProcess = Start-Process -FilePath $outputFile -PassThru

if ($null -eq $installerProcess) {
    Write-Error "Failed to start the installation process."
    exit 1
}

Write-Output "Installer started. Waiting for the setup process to exit..."
$installerProcess.WaitForExit()

try {
    Remove-Item -LiteralPath $outputFile -Force -ErrorAction Stop
    Write-Output "Setup file removed: $outputFile"
}
catch {
    Write-Warning "Automatic cleanup failed. The setup file may still be in use: $outputFile"

    do {
        $removeSetup = Read-Host "Have you completed the WinSCP installation and want to remove the setup file now? [Y/N]"
    } while ($removeSetup -notmatch '^[YyNn]$')

    if ($removeSetup -match '^[Yy]$') {
        Remove-Item -LiteralPath $outputFile -Force
        Write-Output "Setup file removed: $outputFile"
    }
    else {
        Write-Output "Setup file kept: $outputFile"
    }
}