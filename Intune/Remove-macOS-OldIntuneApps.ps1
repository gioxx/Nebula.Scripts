<#PSScriptInfo
.VERSION 1.0.0
.GUID d2ace103-adeb-47be-80cd-2180db770ece
.AUTHOR Giovanni Solone
.TAGS powershell intune macos apps microsoft graph cleanup duplicates
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/gioxx/Nebula.Scripts/Intune/Remove-macOS-OldIntuneApps.ps1
#>

# Requires -Version 7.0

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
		id          = $app.Id
		displayName = $app.DisplayName
		isAssigned  = $app.IsAssigned
		fileName    = $fileName
		Version     = $bundleVersion
	}
}

# Show a full table of all macOS apps
$appsInfo | Format-Table -AutoSize

# Group apps by name to identify duplicates
$duplicateApps = $appsInfo | Group-Object -Property displayName | Where-Object { $_.Count -gt 1 }

# Exit if no duplicates were found
if (-not $duplicateApps) {
	Write-Host "No duplicate apps found." -ForegroundColor Green
	return
}

# Display groups with more than one version
$duplicateApps | Sort-Object -Property Count -Descending | Format-Table -AutoSize

# Identify older versions (excluding latest per group)
$oldVersions = foreach ($group in $duplicateApps) {
	$ordered = $group.Group | Sort-Object -Property Version -Descending
	$ordered | Select-Object -Skip 1
}

# Show older versions
if ($oldVersions) {
	Write-Host "`n--- Old versions found ---" -ForegroundColor Yellow
	$oldVersions | Sort-Object displayName, Version | Format-Table displayName, Version, isAssigned, fileName, id -AutoSize
} else {
	Write-Host "No old versions found." -ForegroundColor Green
}

# Highlight old versions that are still assigned
$stillAssigned = $oldVersions | Where-Object { $_.isAssigned -eq $true }

if ($stillAssigned) {
	Write-Host "`n--- WARNING: Old versions still assigned ---" -ForegroundColor Red
	$stillAssigned | Sort-Object displayName, Version | Format-Table displayName, Version, fileName, id -AutoSize
} else {
	Write-Host "All old versions are unassigned. Safe to remove (please use the -RemoveIfUnassigned switch)." -ForegroundColor Green
}

# Move assignments from old versions to the newest version
foreach ($group in $duplicateApps) {
	# Sort the group by version descending
	$ordered = $group.Group | Sort-Object -Property Version -Descending
	$newestApp = $ordered[0]
	$oldApps = $ordered | Select-Object -Skip 1

	foreach ($oldApp in $oldApps) {
		# Skip apps that are not still assigned
		if (-not ($stillAssigned | Where-Object { $_.id -eq $oldApp.id })) {
			continue
		}

		# Get assignments from the old version
		$assignments = Get-MgBetaDeviceAppManagementMobileAppAssignment -MobileAppId $oldApp.id

		if (-not $assignments) {
			Write-Host "`nNo assignments found for $($oldApp.displayName) [$($oldApp.Version)]"
			continue
		}

		Write-Host "`n==== SIMULATION ====" -ForegroundColor Yellow
		Write-Host "App name     : $($oldApp.displayName)"
		Write-Host "Old version  : $($oldApp.Version)"
		Write-Host "New version  : $($newestApp.Version)"
		Write-Host "Assignments to move:" -ForegroundColor Gray
		$assignments | Format-Table id, intent, @{Name = "Target"; Expression = { $_.target.groupId } }, -AutoSize

		# Ask user confirmation
		$choice = Read-Host "Do you want to move these assignments to the newer version? [y/n] (default: y)"

		if ([string]::IsNullOrWhiteSpace($choice) -or $choice.ToLower() -eq "y") {
			foreach ($assignment in $assignments) {
				# Build new assignment body
				$newAssignment = @{
					target = $assignment.target
					intent = $assignment.intent
				}

				# Create new assignment
				New-MgBetaDeviceAppManagementMobileAppAssignment -MobileAppId $newestApp.id -BodyParameter $newAssignment

				# Remove old assignment
				Remove-MgBetaDeviceAppManagementMobileAppAssignment -MobileAppId $oldApp.id -MobileAppAssignmentId $assignment.id

				Write-Host "Moved assignment $($assignment.id) to version $($newestApp.Version)" -ForegroundColor Green
			}
		} else {
			Write-Host "Skipped reassignment for $($oldApp.displayName) [$($oldApp.Version)]" -ForegroundColor DarkGray
		}
	}
}

# Remove old versions if unassigned and switch is enabled
if ($RemoveIfUnassigned -and (-not $stillAssigned)) {
	foreach ($app in $oldVersions) {
		Write-Host "`n==== SIMULATION: REMOVE $($app.displayName) [$($app.Version)] ====" -ForegroundColor Yellow
		Write-Host "App ID   : $($app.id)"
		Write-Host "File     : $($app.fileName)"

		if (-not $Force) {
			$confirm = Read-Host "Confirm removal of this app? [y/n] (default: n)"
			if ($confirm.ToLower() -ne "y") {
				Write-Host "Skipped removal for $($app.displayName) [$($app.Version)]" -ForegroundColor DarkGray
				continue
			}
		}

		# Perform actual removal
		Remove-MgBetaDeviceAppManagementMobileApp -MobileAppId $app.id
		Write-Host "Removed app $($app.displayName) [$($app.Version)]" -ForegroundColor Green
	}
} elseif ($RemoveIfUnassigned -and $stillAssigned) {
	Write-Host "`nRemoval blocked: some old versions are still assigned. Nothing will be removed." -ForegroundColor Red
}
