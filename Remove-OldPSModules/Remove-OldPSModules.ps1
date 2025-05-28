
<#PSScriptInfo

.VERSION 1.0.0

.GUID 887af808-3b0a-4945-b7c7-7589f7bc7953

.AUTHOR Giovanni Solone

.COMPANYNAME

.COPYRIGHT

.TAGS powershell modules cleanup

.LICENSEURI https://opensource.org/licenses/MIT

.PROJECTURI https://github.com/gioxx/Nebula.Scripts/Remove-OldPSModules

.ICONURI

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS

.EXTERNALSCRIPTDEPENDENCIES

.RELEASENOTES


.PRIVATEDATA

#>

<#
.SYNOPSIS
    Cleans up duplicate PowerShell modules by removing older versions.
.DESCRIPTION
    This script identifies PowerShell modules that have multiple versions installed
    and removes all but the latest version for each module. It uses the PSResourceGet
    module to manage PowerShell resources.
    This script requires PowerShell 7.0 or later and the PSResourceGet module.
    It will attempt to install the PSResourceGet module if it is not already available.
.NOTES
    Author: Giovanni Solone (gioxx.org)
    Date: 2025-05-28

    This script is available on GitHub at: https://github.com/gioxx/Nebula.Scripts/Remove-OldPSModules

    Modification History:
    - 2025-05-28: Initial creation
#>

# Requires -Version 7.0

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
