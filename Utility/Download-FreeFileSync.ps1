<#PSScriptInfo
.VERSION 1.1.2
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
v1.0.0 (2025-12-04): Initial release.
v1.1.0 (2026-03-19): Download setup to the system temp folder and remove it only after user confirmation.
v1.1.1 (2026-03-19): Wait for the installer process to exit and remove the setup automatically when possible.
v1.1.2 (2026-03-26): Fixed PROJECTURI in the script metadata to point to the correct GitHub repository and file.
#>

$FFS_URL = "https://freefilesync.org/download.php" # Define the URL of the download page
$Response = Invoke-WebRequest -Uri $FFS_URL

# Use regex to find the download link for the Windows version
$regex = "href=""(.*?FreeFileSync_.*?_Windows_Setup.exe)"""
$regexMatches = [regex]::Matches($Response.Content, $regex)

if ($regexMatches.Count -gt 0) {
    $downloadLink = $regexMatches[0].Groups[1].Value # Extract the first match (assuming it's the correct download link)
    $baseUrl = "https://freefilesync.org"
    $fullDownloadLink = $baseUrl + $downloadLink # Make the full URL for the download

    Write-Output "Latest version link: $downloadLink"
    Write-Output "Full download link:  $fullDownloadLink"

    $tempPath = [System.IO.Path]::GetTempPath()
    $outputFile = Join-Path -Path $tempPath -ChildPath "FreeFileSync_Windows_Setup.exe"
    Invoke-WebRequest -Uri $fullDownloadLink -OutFile $outputFile

    Write-Output "Download completed: $outputFile"
    $installerProcess = Start-Process -FilePath $outputFile -PassThru

    Write-Output "Installer started. Waiting for the setup process to exit..."
    $installerProcess.WaitForExit()

    try {
        Remove-Item -LiteralPath $outputFile -Force -ErrorAction Stop
        Write-Output "Setup file removed: $outputFile"
    } catch {
        Write-Warning "Automatic cleanup failed. The setup file may still be in use: $outputFile"

        do {
            $removeSetup = Read-Host "Have you completed the FreeFileSync installation and want to remove the setup file now? [Y/N]"
        } while ($removeSetup -notmatch '^[YyNn]$')

        if ($removeSetup -match '^[Yy]$') {
            Remove-Item -LiteralPath $outputFile -Force
            Write-Output "Setup file removed: $outputFile"
        } else {
            Write-Output "Setup file kept: $outputFile"
        }
    }
} else {
    Write-Error "Download link not found."
}
