<#PSScriptInfo
.VERSION 1.0.3
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
v1.0.3 (2026-03-19)
	Changed Graph module validation to require only a minimum supported version (2.35.0) instead of forcing the latest PSGallery release.
	Kept update discovery messaging when newer versions are available, but allow continuing when installed modules already meet the minimum requirement.
v1.0.2 (2026-03-02)
	Removed explicit Beta module import to prevent Microsoft.Graph.Authentication assembly conflicts after module updates.
	Switched to stable Mg cmdlets and added -All pagination where needed.
	Added startup check for required stable Graph cmdlets with install/update prompt when missing or outdated.
	Replaced server-side OData `isof(...)` filter with client-side filtering to avoid BadRequest errors on stable endpoint.
	Added hard-stop behavior if app retrieval from Graph fails.
	Improved macOS app type detection for stable cmdlets and removed over-restrictive availability filter.
v1.0.1 (2025-07-16):
	Changed 'SIMULATION' to 'CONFIRMATION REQUEST' for better readability in the removal process.
    Changed some text and comments in the script for better clarity and consistency.
#>

param (
	[switch]$RemoveIfUnassigned,
	[switch]$Force
)

function Test-RequiredGraphCmdlets {
	$minimumSupportedVersion = [version]'2.35.0'
	$modulesToManage = @(
		'Microsoft.Graph.Authentication',
		'Microsoft.Graph.Devices.CorporateManagement'
	)

	$requiredCmdlets = @(
		'Connect-MgGraph',
		'Invoke-MgGraphRequest',
		'Get-MgDeviceAppManagementMobileApp',
		'Get-MgDeviceAppManagementMobileAppAssignment',
		'New-MgDeviceAppManagementMobileAppAssignment',
		'Remove-MgDeviceAppManagementMobileAppAssignment',
		'Remove-MgDeviceAppManagementMobileApp'
	)

	$missingCmdlets = $requiredCmdlets | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) }

	$missingModules = @()
	$modulesBelowMinimum = @()
	$modulesWithAvailableUpdates = @()

	foreach ($moduleName in $modulesToManage) {
		$installedModule = Get-Module -ListAvailable -Name $moduleName |
			Sort-Object -Property Version -Descending |
			Select-Object -First 1

		if (-not $installedModule) {
			$missingModules += $moduleName
			continue
		}

		if ([version]$installedModule.Version -lt $minimumSupportedVersion) {
			$modulesBelowMinimum += [PSCustomObject]@{
				Name = $moduleName
				InstalledVersion = $installedModule.Version
				MinimumVersion = $minimumSupportedVersion
			}
		}

		try {
			$galleryModule = Find-Module -Name $moduleName -Repository PSGallery -ErrorAction Stop
			if ([version]$galleryModule.Version -gt [version]$installedModule.Version) {
				$modulesWithAvailableUpdates += [PSCustomObject]@{
					Name = $moduleName
					InstalledVersion = $installedModule.Version
					LatestVersion = $galleryModule.Version
				}
			}
		}
		catch {
			Write-Host "Unable to check latest version for $moduleName from PSGallery. Continuing with local version." -ForegroundColor DarkYellow
		}
	}

	$requiresInstallOrUpdate = ($missingCmdlets -or $missingModules -or $modulesBelowMinimum)

	if (-not $requiresInstallOrUpdate -and -not $modulesWithAvailableUpdates) {
		return
	}

	if ($missingCmdlets) {
		Write-Host "Missing Microsoft Graph cmdlets detected:" -ForegroundColor Yellow
		$missingCmdlets | ForEach-Object { Write-Host "- $_" -ForegroundColor Yellow }
	}

	if ($missingModules) {
		Write-Host "`nMissing Microsoft Graph modules detected:" -ForegroundColor Yellow
		$missingModules | ForEach-Object { Write-Host "- $_" -ForegroundColor Yellow }
	}

	if ($modulesBelowMinimum) {
		Write-Host "`nMicrosoft Graph modules below minimum supported version $minimumSupportedVersion detected:" -ForegroundColor Yellow
		$modulesBelowMinimum | Format-Table Name, InstalledVersion, MinimumVersion -AutoSize
	}

	if ($modulesWithAvailableUpdates) {
		Write-Host "`nMicrosoft Graph module updates are available:" -ForegroundColor Yellow
		$modulesWithAvailableUpdates | Format-Table Name, InstalledVersion, LatestVersion -AutoSize
	}

	if (-not $requiresInstallOrUpdate) {
		return
	}

	$choice = Read-Host "`nInstall/update required Microsoft Graph modules now? [y/n] (default: y)"
	if (-not [string]::IsNullOrWhiteSpace($choice) -and $choice.Trim().ToLower() -ne 'y') {
		throw "Cannot continue without required Microsoft Graph modules or minimum supported versions."
	}

	foreach ($moduleName in $missingModules) {
		Write-Host "Installing module $moduleName..." -ForegroundColor Cyan
		Install-Module -Name $moduleName -Scope CurrentUser -Repository PSGallery -AllowClobber -Force -ErrorAction Stop
	}

	foreach ($moduleInfo in $modulesBelowMinimum) {
		Write-Host "Updating module $($moduleInfo.Name) from $($moduleInfo.InstalledVersion) to at least $($moduleInfo.MinimumVersion)..." -ForegroundColor Cyan
		Update-Module -Name $moduleInfo.Name -Scope CurrentUser -Force -ErrorAction Stop
	}

	$stillMissing = $requiredCmdlets | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) }
	if ($stillMissing) {
		throw "Required Graph cmdlets are still unavailable after install/update. Try a new PowerShell session."
	}

	$stillBelowMinimum = foreach ($moduleName in $modulesToManage) {
		$installedModule = Get-Module -ListAvailable -Name $moduleName |
			Sort-Object -Property Version -Descending |
			Select-Object -First 1

		if ($installedModule -and [version]$installedModule.Version -lt $minimumSupportedVersion) {
			[PSCustomObject]@{
				Name = $moduleName
				InstalledVersion = $installedModule.Version
				MinimumVersion = $minimumSupportedVersion
			}
		}
	}

	if ($stillBelowMinimum) {
		$stillBelowMinimum | Format-Table Name, InstalledVersion, MinimumVersion -AutoSize
		throw "Microsoft Graph modules are still below the minimum supported version after update."
	}
}

Test-RequiredGraphCmdlets
Connect-MgGraph -Scopes "DeviceManagementApps.ReadWrite.All" -NoWelcome

# Retrieve all apps from beta endpoint (same family used by Intune UI), then filter client-side.
function Get-GraphCollection {
	param (
		[Parameter(Mandatory = $true)]
		[string]$Uri
	)

	$items = @()
	$nextUri = $Uri

	while ($nextUri) {
		$response = Invoke-MgGraphRequest -Method GET -Uri $nextUri -ErrorAction Stop
		if ($response.value) {
			$items += @($response.value)
		}
		$nextUri = $response.'@odata.nextLink'
	}

	return $items
}

function Get-AppPropertyValue {
	param (
		[Parameter(Mandatory = $true)]
		$App,
		[Parameter(Mandatory = $true)]
		[string]$Name
	)

	# Handle hashtable/dictionary payloads returned by Invoke-MgGraphRequest.
	if ($App -is [System.Collections.IDictionary]) {
		if ($App.Contains($Name)) {
			return $App[$Name]
		}

		foreach ($key in $App.Keys) {
			if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
				return $App[$key]
			}
		}
	}

	if ($App.PSObject.Properties.Name -contains $Name -and $null -ne $App.$Name) {
		return $App.$Name
	}

	if ($App.AdditionalProperties -and $App.AdditionalProperties -is [System.Collections.IDictionary]) {
		if ($App.AdditionalProperties.Contains($Name)) {
			return $App.AdditionalProperties[$Name]
		}
		foreach ($key in $App.AdditionalProperties.Keys) {
			if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
				return $App.AdditionalProperties[$key]
			}
		}
	}

	return $null
}

function Get-AppODataType {
	param (
		[Parameter(Mandatory = $true)]
		$App
	)

	$typeCandidates = @(
		'@odata.type',
		'odataType',
		'OdataType'
	)

	foreach ($typeName in $typeCandidates) {
		$typeValue = Get-AppPropertyValue -App $App -Name $typeName
		if ($typeValue) {
			return [string]$typeValue
		}
	}

	return ''
}

function Get-AssignmentSignature {
	param (
		[Parameter(Mandatory = $true)]
		$Assignment
	)

	$intent = [string]$Assignment.intent
	$target = $Assignment.target
	$targetType = if ($target.'@odata.type') { [string]$target.'@odata.type' } else { '' }
	$groupId = if ($target.groupId) { [string]$target.groupId } else { '' }
	$collectionId = if ($target.deviceAndAppManagementAssignmentFilterId) { [string]$target.deviceAndAppManagementAssignmentFilterId } else { '' }
	$filterType = if ($target.deviceAndAppManagementAssignmentFilterType) { [string]$target.deviceAndAppManagementAssignmentFilterType } else { '' }

	return "$intent|$targetType|$groupId|$collectionId|$filterType"
}

function Test-IsVppAppType {
	param (
		[Parameter(Mandatory = $true)]
		[string]$ODataType
	)

	return ($ODataType -match 'microsoft\.graph\.macOsVppApp')
}

try {
	$allApps = Get-GraphCollection -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=200"
}
catch {
	throw "Unable to retrieve Intune apps from Microsoft Graph. Details: $($_.Exception.Message)"
}

$macOSApps = $allApps | Where-Object {
	$odataType = Get-AppODataType -App $_
	$odataType -match 'microsoft\.graph\.macOS' -or
	$odataType -match 'microsoft\.graph\.macOs' -or
	$odataType -match 'microsoft\.graph\.webApp'
} | Sort-Object -Property DisplayName

Write-Host ("Total Intune apps read: {0}" -f @($allApps).Count) -ForegroundColor DarkGray
Write-Host ("macOS apps filtered: {0}" -f @($macOSApps).Count) -ForegroundColor DarkGray
if (-not $macOSApps) {
	$detectedTypes = $allApps |
		ForEach-Object { Get-AppODataType -App $_ } |
		Where-Object { $_ } |
		Sort-Object -Unique
	Write-Host "Detected app types from Graph (debug):" -ForegroundColor DarkYellow
	$detectedTypes | Select-Object -First 30 | ForEach-Object { Write-Host "- $_" -ForegroundColor DarkYellow }
}

# Extract key properties including values from AdditionalProperties
$appsInfo = foreach ($app in $macOSApps) {
	$fileName = Get-AppPropertyValue -App $app -Name 'fileName'
	$odataType = Get-AppODataType -App $app
	$bundleVersion = @(
		(Get-AppPropertyValue -App $app -Name 'primaryBundleVersion'),
		(Get-AppPropertyValue -App $app -Name 'version'),
		(Get-AppPropertyValue -App $app -Name 'displayVersion'),
		(Get-AppPropertyValue -App $app -Name 'productVersion'),
		(Get-AppPropertyValue -App $app -Name 'packageVersion')
	) | Where-Object { $_ } | Select-Object -First 1

	[PSCustomObject]@{
		ID			= (Get-AppPropertyValue -App $app -Name 'id')
		DisplayName	= (Get-AppPropertyValue -App $app -Name 'displayName')
		Assigned	= (Get-AppPropertyValue -App $app -Name 'isAssigned')
		FileName	= $fileName
		Version		= $bundleVersion
		ODataType	= $odataType
		IsVpp		= (Test-IsVppAppType -ODataType $odataType)
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
$oldVersionsAll = foreach ($group in $duplicateApps) {
	# Identify older versions (excluding latest per group)
	$ordered = $group.Group | Sort-Object -Property Version -Descending
	$ordered | Select-Object -Skip 1
}

$excludedOldVersions = $oldVersionsAll | Where-Object { $_.IsVpp -eq $true }
$oldVersions = $oldVersionsAll | Where-Object { $_.IsVpp -ne $true }

if ($excludedOldVersions) {
	Write-Host "`nSkipping VPP app versions from cleanup:" -ForegroundColor DarkYellow
	$excludedOldVersions | Sort-Object DisplayName, Version | Format-Table DisplayName, Version, Assigned, FileName, id -AutoSize
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
	$newestAssignments = @(Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $newestApp.id -All)
	$newestAssignmentSignatures = @{}
	foreach ($existingAssignment in $newestAssignments) {
		$newestAssignmentSignatures[(Get-AssignmentSignature -Assignment $existingAssignment)] = $true
	}

	foreach ($oldApp in $oldApps) {
		if (-not ($stillAssigned | Where-Object { $_.id -eq $oldApp.id })) {
			continue # Skip apps that are not still assigned
		}

		$assignments = Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $oldApp.id -All # Get assignments from the old version
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
				$assignmentSignature = Get-AssignmentSignature -Assignment $assignment
				if ($newestAssignmentSignatures.ContainsKey($assignmentSignature)) {
					Write-Host "Assignment already exists on newest version, skipping create: $($assignment.id)" -ForegroundColor DarkGray
					try {
						Remove-MgDeviceAppManagementMobileAppAssignment -MobileAppId $oldApp.id -MobileAppAssignmentId $assignment.id -ErrorAction Stop
						Write-Host "Removed duplicate assignment $($assignment.id) from old version $($oldApp.Version)" -ForegroundColor Green
					}
					catch {
						Write-Host "Failed to remove duplicate assignment $($assignment.id) from old version: $($_.Exception.Message)" -ForegroundColor Red
					}
					continue
				}

				# Build new assignment body
				$newAssignment = @{
					target = $assignment.target
					intent = $assignment.intent
				}

				try {
					New-MgDeviceAppManagementMobileAppAssignment -MobileAppId $newestApp.id -BodyParameter $newAssignment -ErrorAction Stop | Out-Null
					$newestAssignmentSignatures[$assignmentSignature] = $true
				}
				catch {
					Write-Host "Failed to create assignment $($assignment.id) on newest version: $($_.Exception.Message)" -ForegroundColor Red
					continue
				}

				try {
					Remove-MgDeviceAppManagementMobileAppAssignment -MobileAppId $oldApp.id -MobileAppAssignmentId $assignment.id -ErrorAction Stop
					Write-Host "Moved assignment $($assignment.id) to version $($newestApp.Version)" -ForegroundColor Green
				}
				catch {
					Write-Host "Created assignment on newest app, but failed to remove old one $($assignment.id): $($_.Exception.Message)" -ForegroundColor Red
				}
			}
		} else {
			Write-Host "Skipped reassignment for $($oldApp.displayName) $($oldApp.Version)" -ForegroundColor DarkGray
		}
	}
}

# Re-evaluate old versions assignment status after potential moves.
$stillAssigned = foreach ($app in $oldVersions) {
	try {
		if ((Get-MgDeviceAppManagementMobileAppAssignment -MobileAppId $app.id -All)) {
			$app
		}
	}
	catch {
		Write-Host "Failed to verify assignments for app $($app.DisplayName) [$($app.id)]: $($_.Exception.Message)" -ForegroundColor DarkYellow
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

		try {
			Remove-MgDeviceAppManagementMobileApp -MobileAppId $app.id -ErrorAction Stop # Perform actual removal
			Write-Host "Successfully removed $($app.displayName) version $($app.Version) from Intune" -ForegroundColor Green
		}
		catch {
			Write-Host "Failed to remove $($app.displayName) version $($app.Version): $($_.Exception.Message)" -ForegroundColor Red
		}
	}
} elseif ($RemoveIfUnassigned -and $stillAssigned) {
	Write-Host "`nRemoval blocked: some old versions are still assigned. Nothing will be removed." -ForegroundColor Red
}
