<#PSScriptInfo
.VERSION 1.1.3
.GUID 777f62f2-236d-4aff-9fe1-eaf88d1e864a
.AUTHOR Giovanni Solone
.TAGS powershell freefilesync download tools
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/gioxx/Nebula.Scripts/blob/main/Utility/Download-FreeFileSync.ps1
#>

#Requires -Version 7.0

<#
.SYNOPSIS
Checks for available FreeFileSync updates for Microsoft Windows and update it if available.

.DESCRIPTION
This script checks for available FreeFileSync updates for Microsoft Windows and update it if available.

.EXAMPLE
.\Download-FreeFileSync.ps1
This command will check for available FreeFileSync updates and update it if available.

.NOTES
Modification History:
v1.1.3 (2026-10-09): Verify the downloaded file is a Windows executable before running it, stop with a non-zero exit code on errors, and match the setup link more strictly.
v1.1.2 (2026-03-26): Fixed PROJECTURI in the script metadata to point to the correct GitHub repository and file.
v1.1.1 (2026-03-19): Wait for the installer process to exit and remove the setup automatically when possible.
v1.1.0 (2026-03-19): Download setup to the system temp folder and remove it only after user confirmation.
v1.0.0 (2025-12-04): Initial release.
#>

$FFS_URL = "https://freefilesync.org/download.php" # Define the URL of the download page
$baseUrl = "https://freefilesync.org"

try {
    $Response = Invoke-WebRequest -Uri $FFS_URL -ErrorAction Stop
}
catch {
    Write-Error "Unable to load the FreeFileSync download page: $($_.Exception.Message)"
    exit 1
}

# Use regex to find the download link for the Windows version ([^"]* keeps the match inside a single href attribute)
$regex = 'href="([^"]*FreeFileSync_[^"]*_Windows_Setup\.exe)"'
$regexMatch = [regex]::Match($Response.Content, $regex)

if (-not $regexMatch.Success) {
    Write-Error "Download link not found on the FreeFileSync download page."
    exit 1
}

$downloadLink = $regexMatch.Groups[1].Value
$fullDownloadLink = if ($downloadLink -match '^https?://') { $downloadLink } else { $baseUrl + $downloadLink }

Write-Output "Latest version link: $downloadLink"
Write-Output "Full download link:  $fullDownloadLink"

$tempPath = [System.IO.Path]::GetTempPath()
$outputFile = Join-Path -Path $tempPath -ChildPath "FreeFileSync_Windows_Setup.exe"

try {
    Invoke-WebRequest -Uri $fullDownloadLink -OutFile $outputFile -ErrorAction Stop
}
catch {
    Write-Error "Download failed: $($_.Exception.Message)"
    exit 1
}

# Check MZ header to verify it's a valid executable before attempting to run it
$fileHeader = Get-Content -Path $outputFile -AsByteStream -TotalCount 2
if ($fileHeader.Count -lt 2 -or $fileHeader[0] -ne 77 -or $fileHeader[1] -ne 90) {
    Write-Error "The downloaded file is not a valid executable. FreeFileSync may have returned an HTML page instead of the setup."
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
        $removeSetup = Read-Host "Have you completed the FreeFileSync installation and want to remove the setup file now? [Y/N]"
    } while ($removeSetup -notmatch '^[YyNn]$')

    if ($removeSetup -match '^[Yy]$') {
        Remove-Item -LiteralPath $outputFile -Force
        Write-Output "Setup file removed: $outputFile"
    }
    else {
        Write-Output "Setup file kept: $outputFile"
    }
}
