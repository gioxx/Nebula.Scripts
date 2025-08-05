<#
.SYNOPSIS
    Detection script for Microsoft 365 Copilot App (Microsoft.MicrosoftOfficeHub)
.DESCRIPTION
    This script detects whether the Microsoft.MicrosoftOfficeHub app (commonly associated with Microsoft 365 Copilot) is installed for any user on the system.
    If the application is found, the device is considered non-compliant, and remediation will be triggered by Intune.
.EXAMPLE
    .\M365CopilotApp_Detection.ps1
.NOTES
    Author: Giovanni Solone
    Date: 2025-08-05
    
    Modification History:
    - 2025-08-05: Initial version.
#>

# Check if the Microsoft.MicrosoftOfficeHub app is installed for any user
$M365CopilotApp = Get-AppxPackage -AllUsers | Where-Object { $_.Name -eq "Microsoft.MicrosoftOfficeHub" }

if ($M365CopilotApp) {
    Write-Output "MicrosoftOfficeHub is installed."
    exit 1  # non-compliant (MicrosoftOfficeHub is installed, Remediation needed)
} else {
    Write-Output "MicrosoftOfficeHub is not installed."
    exit 0  # compliant (MicrosoftOfficeHub is not installed, no Remediation needed)
}
