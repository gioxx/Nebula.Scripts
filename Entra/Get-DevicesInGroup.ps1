<#PSScriptInfo
.VERSION 1.0.1
.GUID 50db3d8c-c711-4c50-8396-3ca68b01b27d
.AUTHOR Giovanni Solone
.TAGS powershell entra microsoft graph devices groups
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/gioxx/Nebula.Scripts/Entra/Get-DevicesInGroup.ps1
#>

#Requires -Version 7.0

<#
.SYNOPSIS
The script allows obtaining a list of devices in an Entra group.
.DESCRIPTION
This script can be used to obtain an ordered list of devices (Id, Hostname, Owner) that are within an Entra group.
Allows you to make it easier to create a report otherwise unavailable in the Intune or Enter dashboard.
It also allows the results to be exported to a CSV file for later and more convenient analysis.
.PARAMETER GroupName
The name of the Entra group to retrieve devices from.
.PARAMETER ExportCSV
When specified, the script will export the results to a CSV file.
.EXAMPLE
.\Get-DevicesInGroup.ps1 -GroupName "All Windows 11 Devices"
Runs the script interactively, allowing you to view the results.
.EXAMPLE
.\Get-DevicesInGroup.ps1 -GroupName "All Windows 11 Devices" -ExportCSV
Runs the script and exports the results to a CSV file.
.NOTES
Credits:
https://o365reports.com/2023/04/18/get-azure-ad-devices-report-using-powershell/
https://www.reddit.com/r/PowerShell/comments/1c814xa/using_graph_api_via_powershell_to_report_entra/

Modification History:
v1.0.1 (2025-07-17): Added a message to show how many devices were found in the group.
                     Added new empty lines to improve readability.
					 Results are now sorted by display name.
#>

param (
    [Parameter(Mandatory = $true)]
    [string] $GroupName,
    [switch] $ExportCSV
)

if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes "Group.Read.All", "Device.Read.All", "Directory.Read.All" -NoWelcome -ErrorAction Stop
}

try {
    $groupId = (Get-MgGroup -Filter "displayName eq '$GroupName'").Id
} catch {
    Write-Error "Group '$GroupName' not found in your tenant. $_"
    exit
}

$group = Get-MgGroup -GroupId $groupId -ErrorAction Stop
$devices = Get-MgGroupMember -GroupId $groupId -All
$results = @()
$counter = 0

Write-Host "`nGroup $groupId ($($group.DisplayName))" -ForegroundColor Yellow
Write-Host "Found $($devices.Count) devices in '$($group.DisplayName)', processing ...`n" -ForegroundColor Cyan

foreach ($device in $devices) {
    $props = $device.AdditionalProperties
    $displayName = $props.displayName
    $owners = Get-MgDeviceRegisteredOwner -DeviceId $device.Id -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty AdditionalProperties
    # $ownerUPNs = @($owners.userPrincipalName) -join ','
    $ownerUPNs = $owners | ForEach-Object {
        if ($_ -and $_["displayName"] -and $_["userPrincipalName"]) {
            "$($_["displayName"]) ($($_["userPrincipalName"]))"
        } elseif ($_["userPrincipalName"]) {
            $_["userPrincipalName"]
        } else {
            "N/A"
        }
    } 
    $ownerUPNs = $ownerUPNs -join ', '

    $results += [PSCustomObject]@{
        DeviceId    = $device.Id
        DisplayName = $displayName
        Owners      = if ($ownerUPNs) { $ownerUPNs } else { 'N/A' }
    }

    Write-Progress -Activity "Searching for devices" -Status "Retrieved $counter of $($devices.Count): $($displayName)" -PercentComplete (($counter / $devices.Count) * 100)
    $counter++
}

$results | Sort-Object -Property DisplayName | Format-Table -AutoSize

if ($ExportCSV) {
    $CSVName = $group.DisplayName -replace '[^a-zA-Z0-9]', '_'
    $CSVName = $CSVName -replace '_+', '_'
    $CSVName = $CSVName.TrimEnd('_')

    $exportPath = "Devices_$($CSVName)_$(Get-Date -Format 'yyyyMMdd').csv"

    $results | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8
    Write-Host "Exported to $exportPath" -ForegroundColor Green
}
