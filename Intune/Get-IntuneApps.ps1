<#PSScriptInfo
.VERSION 1.0.4
.GUID 236e8d45-0d5e-4c27-becd-50b512c7e87d
.AUTHOR Giovanni Solone
.TAGS powershell intune apps windows macos ios android microsoft graph
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/gioxx/Nebula.Scripts/blob/main/Intune/Get-IntuneApps.ps1
#>

#Requires -Version 7.0

<#
.SYNOPSIS
This script retrieves and displays a list of applications from Microsoft Intune, filtering by platform if specified.
.DESCRIPTION
Connects to Microsoft Graph, retrieves all applications managed by Intune, and maps their types to more readable names.
.PARAMETER PlatformFilter
Filters by platform: Windows, macOS, iOS, Android, or All.
.PARAMETER GridView
If specified, shows the output in GridView instead of a table.
.PARAMETER ExportToCSV
If specified, exports the data to IntuneApps.csv.
.PARAMETER ExportToJSON
If specified, exports the data to IntuneApps.json.
.PARAMETER DebugFirstApp
If specified, dumps the full details of the first application for debugging purposes.
.EXAMPLE
.\Get-IntuneApps.ps1 -PlatformFilter Windows
Shows only Windows applications.
.EXAMPLE
.\Get-IntuneApps.ps1 -GridView
Shows all applications in GridView.
.NOTES
Credits:
https://github.com/andrew-s-taylor/public/blob/main/Powershell%20Scripts/Intune/get-intune-apps.ps1
https://www.powershellgallery.com/packages/get-intune-apps

Modification History:
v1.0.4 (2026-10-09): Follow @odata.nextLink so tenants with more apps than a single Graph page are fully listed. Fixed script name in examples.
v1.0.3 (2026-10-08): -GridView falls back to a console table on PowerShell 7.6.6, where Out-GridView hangs (PowerShell/PowerShell#27994).
v1.0.2 (2026-03-26): Fixed PROJECTURI in the script metadata to point to the correct GitHub repository and file.
v1.0.1 (2025-10-24): Removed deprecated cmdlets, fallback to get apps version.
v1.0.0 (2025-04-04): Initial version.
#>

param (
    [ValidateSet("Windows", "macOS", "iOS", "Android", "All")]
    [string] $PlatformFilter = "All",
    [switch] $GridView = $false,
    [switch] $ExportToCSV = $false,
    [switch] $ExportToJSON = $false,
    [switch] $DebugFirstApp = $false
)

# Connect to Microsoft Graph and retrieve all applications and their types
Connect-MgGraph -Scopes "DeviceManagementApps.Read.All" -NoWelcome
$apps = [System.Collections.Generic.List[object]]::new()
$nextUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps"
while ($nextUri) {
    $response = Invoke-MgGraphRequest -Method GET -Uri $nextUri -ErrorAction Stop
    if ($response.value) { $apps.AddRange([object[]]$response.value) }
    $nextUri = $response.'@odata.nextLink'
}

# DEBUG MODE: Dump full first app object
if ($DebugFirstApp) {
    Write-Host "`n[DEBUG] Dumping raw details of the first application:`n" -ForegroundColor Yellow
    $apps[0] | ConvertTo-Json -Depth 10 | Out-String | Write-Host
    return
}

$mappedApps = $apps | ForEach-Object {
    $type = $_.'@odata.type'
    $mapping = switch ($type) {
        "#microsoft.graph.win32LobApp" { @{ OS = "Windows"; Type = "Win32 App" } }
        "#microsoft.graph.officeSuiteApp" { @{ OS = "Windows"; Type = "Office 365 Suite" } }
        "#microsoft.graph.winGetApp" { @{ OS = "Windows"; Type = "WinGet App" } }
        "#microsoft.graph.iosStoreApp" { @{ OS = "iOS"; Type = "Store App" } }
        "#microsoft.graph.iosLobApp" { @{ OS = "iOS"; Type = "LOB App" } }
        "#microsoft.graph.iosVppApp" { @{ OS = "iOS"; Type = "VPP App" } }
        "#microsoft.graph.androidManagedStoreApp" { @{ OS = "Android"; Type = "Managed Store App" } }
        "#microsoft.graph.macOSMicrosoftDefenderApp" { @{ OS = "macOS"; Type = "Microsoft Defender" } }
        "#microsoft.graph.macOSOfficeSuiteApp" { @{ OS = "macOS"; Type = "Office 365 Suite" } }
        "#microsoft.graph.macOSPkgApp" { @{ OS = "macOS"; Type = "PKG App" } }
        "#microsoft.graph.macOsVppApp" { @{ OS = "macOS"; Type = "VPP App" } }
        default { @{ OS = "Unknown"; Type = $type } }
    }

    $bundleVersion = $null
    if ($_.includedApps -and ($_.includedApps | Measure-Object).Count -gt 0 -and $_.includedApps[0]) {
        $bundleVersion = $_.includedApps[0].bundleVersion
    }

    $version = @(
        $_.primaryBundleVersion
        $_.version
        $bundleVersion
        $_.displayVersion
        $_.productVersion
        $_.packageVersion
    ) | Where-Object { $_ } | Select-Object -First 1

    if (-not $version -and $_.fileName -and ($_.fileName -match '\d+(\.\d+){1,3}')) {
        $version = $matches[0]
    }
    if (-not $version) { $version = 'N/A' }

    [PSCustomObject]@{
        "App"       = $_.displayName
        "Id"        = $_.id
        "Type"      = $mapping.Type
        "OS"        = $mapping.OS
        "Version"   = $version
        "Publisher" = $_.publisher
    }
}

# Filter by operating system
if ($PlatformFilter -ne "All") {
    $mappedApps = $mappedApps | Where-Object { $_.OS -eq $PlatformFilter }
}

# Output results
$mappedAppsCount = ($mappedApps | Measure-Object).Count
Write-Host "`nFound $mappedAppsCount apps." -ForegroundColor Cyan

# Out-GridView never returns on PowerShell 7.6.6 (https://github.com/PowerShell/PowerShell/issues/27994)
$psVersion = $PSVersionTable.PSVersion
if ($GridView -and ('{0}.{1}.{2}' -f $psVersion.Major, $psVersion.Minor, $psVersion.Patch) -eq '7.6.6') {
    Write-Warning "Out-GridView hangs on PowerShell $psVersion (PowerShell/PowerShell#27994): showing results in the console instead."
    $GridView = $false
}

if ($GridView) {
    $mappedApps | Sort-Object OS, App | Out-GridView -Title "Intune Apps Overview ($mappedAppsCount apps found)"
}
else {
    $mappedApps | Sort-Object OS, App | Format-Table -AutoSize
}

# Export if required
if ($ExportToCSV) {
    $mappedApps | Export-Csv -Path "$PSScriptRoot\IntuneApps.csv" -NoTypeInformation -Encoding UTF8
    Write-Host "Exported to IntuneApps.csv in $PSScriptRoot"
    Start-Process "$PSScriptRoot\IntuneApps.csv"
}

if ($ExportToJSON) {
    $mappedApps | ConvertTo-Json -Depth 3 | Out-File -FilePath "$PSScriptRoot\IntuneApps.json" -Encoding UTF8
    Write-Host "Exported to IntuneApps.json in $PSScriptRoot"
    Start-Process "$PSScriptRoot\IntuneApps.json"
}