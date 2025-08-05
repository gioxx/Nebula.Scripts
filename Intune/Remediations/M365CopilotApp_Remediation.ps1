<#
.SYNOPSIS
    Remediation script for Microsoft 365 Copilot App (Microsoft.MicrosoftOfficeHub)
.DESCRIPTION
    This script removes the Microsoft.MicrosoftOfficeHub app (commonly associated with Microsoft 365 Copilot) for all users, 
    terminates any associated WebViewHost.exe processes running from the app's install location,
    and sets the registry key to disable Microsoft 365 Copilot via policy.
.EXAMPLE
    .\M365CopilotApp_Remediation.ps1
.NOTES
    Author: Giovanni Solone
    Date: 2025-08-05

    Modification History:
    - 2025-08-05: Initial version.
#>

# Remediate Microsoft.MicrosoftOfficeHub by removing it and disabling Copilot
$targetAppName = "Microsoft.MicrosoftOfficeHub"
$packages = Get-AppxPackage -AllUsers | Where-Object { $_.Name -eq $targetAppName }

foreach ($package in $packages) {
    $installPath = $package.InstallLocation

    # Terminate WebViewHost.exe if it's running from the OfficeHub install folder
    if ($installPath -and (Test-Path $installPath)) {
        $webViewProcesses = Get-Process -Name "WebViewHost" -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -like "$installPath\*"
        }

        foreach ($proc in $webViewProcesses) {
            try {
                Write-Output "Stopping WebViewHost.exe (PID: $($proc.Id)) from $installPath"
                Stop-Process -Id $proc.Id -Force
            } catch {
                Write-Warning "Could not stop WebViewHost.exe (PID: $($proc.Id)): $_"
            }
        }
    }

    # Try to remove the app package for all users
    $userSIDList = $package.PackageUserInformation | ForEach-Object { ($_ -split '\s+')[0] }

    foreach ($sid in $userSIDList) {
        try {
            Write-Output "Removing package $($package.PackageFullName) for user $sid"
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction SilentlyContinue
        } catch {
            Write-Warning "Failed to remove package $($package.PackageFullName) for $sid. Error: $_"
        }
    }
}

# Set registry key to disable Office Copilot
$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Office\Copilot"
$regName = "DisableCopilot"
$regValue = 1

if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

New-ItemProperty -Path $regPath -Name $regName -PropertyType DWORD -Value $regValue -Force | Out-Null
Write-Output "Registry key set: $regPath\$regName = $regValue"
