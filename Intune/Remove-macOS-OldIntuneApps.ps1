<#PSScriptInfo
.VERSION 1.0.1
.GUID d2ace103-adeb-47be-80cd-2180db770ece
.AUTHOR Giovanni Solone
.TAGS powershell intune macos apps microsoft graph cleanup duplicates
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/gioxx/Nebula.Scripts/Intune/Remove-macOS-OldIntuneApps.ps1
#>

#Requires -Version 7.0

<#
.SYNOPSIS
Script to manage macOS apps in Microsoft Graph, focusing on duplicates and old versions.
.DESCRIPTION
This script retrieves all macOS apps from Microsoft Graph, identifies duplicates based on display name,
and allows for moving assignments from old versions to the latest version. It also provides an option to remove
old versions if they are unassigned.
.PARAMETER RemoveIfUnassigned
When specified, the script will remove old versions of apps that are unassigned.
.PARAMETER Force
When specified, the script will not prompt for confirmation before removing apps.
.EXAMPLE
.\Remove-macOS-OldIntuneApps.ps1
Runs the script interactively, allowing you to review duplicates and move assignments.
.EXAMPLE
.\Remove-macOS-OldIntuneApps.ps1 -RemoveIfUnassigned -Force
Removes old versions of macOS apps that are unassigned without prompting for confirmation.
.NOTES
Modification History:
v1.0.1 (2025-07-16): Changed 'SIMULATION' to 'CONFIRMATION REQUEST' for better readability in the removal process.
					 Changed some text and comments in the script for better clarity and consistency.
#>

param (
	[switch]$RemoveIfUnassigned,
	[switch]$Force
)

Import-Module Microsoft.Graph.Beta.Devices.CorporateManagement
Connect-MgGraph -NoWelcome

# Retrieve all macOS apps matching specific types and availability
$macOSApps = Get-MgBetaDeviceAppManagementMobileApp -Filter `
	"(isof('microsoft.graph.macOSDmgApp') or isof('microsoft.graph.macOSPkgApp') or isof('microsoft.graph.macOSLobApp') or isof('microsoft.graph.macOSMicrosoftEdgeApp') or isof('microsoft.graph.macOSMicrosoftDefenderApp') or isof('microsoft.graph.macOSOfficeSuiteApp') or isof('microsoft.graph.macOsVppApp') or isof('microsoft.graph.webApp') or isof('microsoft.graph.macOSWebClip')) `
    and (microsoft.graph.managedApp/appAvailability eq null or microsoft.graph.managedApp/appAvailability eq 'lineOfBusiness' or isAssigned eq true)" `
	-Sort "displayName asc"

# Extract key properties including values from AdditionalProperties
$appsInfo = foreach ($app in $macOSApps) {
	$fileName = $null
	$bundleVersion = $null

	if ($app.AdditionalProperties.ContainsKey("fileName")) {
		$fileName = $app.AdditionalProperties["fileName"]
	}

	if ($app.AdditionalProperties.ContainsKey("primaryBundleVersion")) {
		$bundleVersion = $app.AdditionalProperties["primaryBundleVersion"]
	}

	[PSCustomObject]@{
		ID			= $app.Id
		DisplayName	= $app.DisplayName
		Assigned	= $app.IsAssigned
		FileName	= $fileName
		Version		= $bundleVersion
	}
}

$appsInfo | Format-Table -AutoSize # Show a full table of all macOS apps
$duplicateApps = $appsInfo | Group-Object -Property DisplayName | Where-Object { $_.Count -gt 1 } # Group apps by name to identify duplicates

# Exit if no duplicates were found
if (-not $duplicateApps) {
	Write-Host "No duplicate apps found." -ForegroundColor Green
	return
}

$duplicateApps | Sort-Object -Property Count -Descending | Format-Table -AutoSize # Display groups with more than one version
$oldVersions = foreach ($group in $duplicateApps) {
	# Identify older versions (excluding latest per group)
	$ordered = $group.Group | Sort-Object -Property Version -Descending
	$ordered | Select-Object -Skip 1
}

if ($oldVersions) {
	# Show older versions
	Write-Host "`n--- Old versions found ---" -ForegroundColor Yellow
	$oldVersions | Sort-Object DisplayName, Version | Format-Table DisplayName, Version, Assigned, FileName, id -AutoSize
} else {
	Write-Host "No old versions found." -ForegroundColor Green
}

$stillAssigned = $oldVersions | Where-Object { $_.Assigned -eq $true } # Highlight old versions that are still assigned

if ($stillAssigned) {
	Write-Host "`n--- WARNING: Old versions still assigned ---" -ForegroundColor Red
	$stillAssigned | Sort-Object DisplayName, Version | Format-Table DisplayName, Version, FileName, id -AutoSize
} else {
	Write-Host "All old versions are unassigned. Safe to remove (please start again this script and use the -RemoveIfUnassigned switch)." -ForegroundColor Green
}

foreach ($group in $duplicateApps) {
	# Move assignments from old versions to the newest version
	$ordered = $group.Group | Sort-Object -Property Version -Descending
	$newestApp = $ordered[0]
	$oldApps = $ordered | Select-Object -Skip 1

	foreach ($oldApp in $oldApps) {
		if (-not ($stillAssigned | Where-Object { $_.id -eq $oldApp.id })) {
			continue # Skip apps that are not still assigned
		}

		$assignments = Get-MgBetaDeviceAppManagementMobileAppAssignment -MobileAppId $oldApp.id # Get assignments from the old version
		if (-not $assignments) {
			Write-Host "`nNo assignments found for $($oldApp.displayName) [$($oldApp.Version)]"
			continue
		}

		Write-Host "`n==== CONFIRMATION REQUEST ====" -ForegroundColor Yellow
		Write-Host "App name     : $($oldApp.displayName)"
		Write-Host "Old version  : $($oldApp.Version)"
		Write-Host "New version  : $($newestApp.Version)"
		Write-Host "Assignments to move:" -ForegroundColor Gray
		$assignments | Format-Table id, intent, @{Name = "Target"; Expression = { $_.target.groupId } } -AutoSize

		$choice = Read-Host "`nDo you want to move these assignments to the newer version? [y/n] (default: y)" # Ask for user confirmation

		if ([string]::IsNullOrWhiteSpace($choice) -or $choice.ToLower() -eq "y") {
			foreach ($assignment in $assignments) {
				# Build new assignment body
				$newAssignment = @{
					target = $assignment.target
					intent = $assignment.intent
				}
				
				New-MgBetaDeviceAppManagementMobileAppAssignment -MobileAppId $newestApp.id -BodyParameter $newAssignment # Create new assignment
				Remove-MgBetaDeviceAppManagementMobileAppAssignment -MobileAppId $oldApp.id -MobileAppAssignmentId $assignment.id # Remove old assignment
				
				Write-Host "Moved assignment $($assignment.id) to version $($newestApp.Version)" -ForegroundColor Green
			}
		} else {
			Write-Host "Skipped reassignment for $($oldApp.displayName) $($oldApp.Version)" -ForegroundColor DarkGray
		}
	}
}

if ($RemoveIfUnassigned -and (-not $stillAssigned)) {
	# Remove old versions if unassigned and switch is enabled
	foreach ($app in $oldVersions) {
		Write-Host "`n==== CONFIRMATION REQUEST : Remove $($app.displayName) $($app.Version) ====" -ForegroundColor Yellow
		Write-Host "App ID   : $($app.id)"
		Write-Host "File     : $($app.fileName)"

		if (-not $Force) {
			$confirm = Read-Host "`nConfirm removal of this app? [y/n] (default: n)"
			if ($confirm.ToLower() -ne "y") {
				Write-Host "Skipped removal for $($app.displayName) $($app.Version)" -ForegroundColor DarkGray
				continue
			}
		}

		Remove-MgBetaDeviceAppManagementMobileApp -MobileAppId $app.id # Perform actual removal
		Write-Host "Successfully removed $($app.displayName) version $($app.Version) from Intune" -ForegroundColor Green
	}
} elseif ($RemoveIfUnassigned -and $stillAssigned) {
	Write-Host "`nRemoval blocked: some old versions are still assigned. Nothing will be removed." -ForegroundColor Red
}
