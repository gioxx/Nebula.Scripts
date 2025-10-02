<#PSScriptInfo
.VERSION 1.1.0
.GUID 887af808-3b0a-4945-b7c7-7589f7bc7953
.AUTHOR Giovanni Solone
.TAGS powershell modules cleanup
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/gioxx/Nebula.Scripts/Management/Remove-OldPSModules.ps1
#>

#Requires -Version 7.0

<#
.SYNOPSIS
Removes old versions of installed PowerShell modules, keeping only the latest.
.DESCRIPTION
This script identifies all installed PowerShell modules and removes all but the latest version of each module. It uses the `PSResourceGet` module to manage PowerShell resources.
.EXAMPLE
.\Remove-OldPSModules.ps1
Runs the script and removes outdated module versions.
#>

# Ensure PSResourceGet is available
try {
    Import-Module Microsoft.PowerShell.PSResourceGet -ErrorAction Stop
} catch {
    try {
        Install-Module Microsoft.PowerShell.PSResourceGet -Force -Scope CurrentUser -AllowClobber
        Import-Module Microsoft.PowerShell.PSResourceGet -ErrorAction Stop
    } catch {
        Write-Error "Failed to install or import PSResourceGet module. $_"
        exit 1
    }
}

# Get only actually installed resources
$resources = Get-InstalledPSResource | Group-Object Name

if ($resources.Count -eq 0) {
    Write-Host "No installed PowerShell resources found."
    exit 0
} else {
    Write-Host "Found $($resources.Count) installed PowerShell resources."

    $removedAny = $false  # Track whether any removal has occurred

    foreach ($group in $resources) {
        $versions = $group.Group | Sort-Object Version -Descending
        $toRemove = $versions | Select-Object -Skip 1

        foreach ($resource in $toRemove) {
            try {
                $scope = if ($resource.InstalledScope) { $resource.InstalledScope } else { 'CurrentUser' }

                Uninstall-PSResource -Name $resource.Name -Version $resource.Version -Scope $scope -ErrorAction Stop
                Write-Host "✅ Removed $($resource.Name) v$($resource.Version)"
                $removedAny = $true
            } catch {
                Write-Warning "⚠️ Could not remove $($resource.Name) v$($resource.Version): $_"
            }
        }
    }

    if (-not $removedAny) {
        Write-Host "✔️ No duplicate module versions found. Nothing to uninstall."
    }
}
