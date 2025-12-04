<#PSScriptInfo
.VERSION 1.0.0
.GUID 777f62f2-236d-4aff-9fe1-eaf88d1e864a
.AUTHOR Giovanni Solone
.TAGS powershell freefilesync download tools
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/gioxx/Nebula.Scripts/Utility/Download-FreeFileSync.ps1
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

    $outputFile = "FreeFileSync_Windows_Setup.exe"
    Invoke-WebRequest -Uri $fullDownloadLink -OutFile $outputFile

    Write-Output "Download completed: $outputFile"
    & ".\$outputFile"
} else {
    Write-Error "Download link not found."
}