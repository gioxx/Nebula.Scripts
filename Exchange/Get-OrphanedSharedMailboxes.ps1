<#PSScriptInfo
.VERSION 1.0.0
.GUID 04fb0c8f-d00b-4633-9d53-402142ce2cf9
.AUTHOR Giovanni Solone
.TAGS powershell exchange exchangeonline sharedmailbox permissions audit orphaned
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/gioxx/Nebula.Scripts/blob/main/Exchange/Get-OrphanedSharedMailboxes.ps1
#>

#Requires -Version 7.0

<#
.SYNOPSIS
Audits Exchange Online shared mailboxes for missing delegated permissions.

.DESCRIPTION
This script identifies shared mailboxes without explicit FullAccess, SendAs or SendOnBehalf permissions.
It connects to Exchange Online when no active connection exists, restores the connection and retries
when a mailbox check fails, and saves each result to a CSV file as soon as it is available.
If the CSV file already exists, the script asks whether to resume the audit (only mailboxes not yet
audited are checked) or to start a new one (the existing file is archived with a timestamp, never deleted).
Each record stores the tenant ID: a report created for a different tenant is never resumed.
The script performs read-only operations on Exchange Online.

.PARAMETER ReportPath
Path to the persistent CSV audit file. Default: SharedMailboxAudit.csv in the current directory.

.PARAMETER MaxRetries
Maximum number of attempts per mailbox. Default: 3.

.PARAMETER RetryDelaySeconds
Delay in seconds between retry attempts. Default: 5.

.PARAMETER Mode
What to do when the report file already exists, without asking:
Resume continues the audit (or only shows the summary if it is already complete),
Restart archives the existing file and starts a new audit.
If omitted, the script asks interactively.

.EXAMPLE
.\Get-OrphanedSharedMailboxes.ps1
Audits all shared mailboxes and saves the results to SharedMailboxAudit.csv in the current directory.

.EXAMPLE
.\Get-OrphanedSharedMailboxes.ps1 -ReportPath 'C:\Reports\SharedMailboxAudit.csv'
Audits all shared mailboxes using the given CSV file, asking what to do if it already exists.

.EXAMPLE
.\Get-OrphanedSharedMailboxes.ps1 -ReportPath 'C:\Reports\SharedMailboxAudit.csv' -Mode Restart
Archives the existing report and starts a new audit without asking (useful for scheduled runs).

.NOTES
Requirements:
- ExchangeOnlineManagement module
- Permissions to read mailbox and recipient permissions in Exchange Online

Modification History:
v1.0.0 (2026-10-16): Initial release.
#>

[CmdletBinding()]
param(
    [string]$ReportPath = (Join-Path $PWD "SharedMailboxAudit.csv"),

    [ValidateRange(1, 10)]
    [int]$MaxRetries = 3,

    [ValidateRange(1, 120)]
    [int]$RetryDelaySeconds = 5,

    [ValidateSet("Resume", "Restart")]
    [string]$Mode
)

$ErrorActionPreference = "Stop"

# Full path, so the archive name can be built next to the report
$ReportPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath)

# ============================================================
# Exchange Online connection
# ============================================================

function Connect-ExchangeOnlineSafe {

    Write-Host "Connecting to Exchange Online..." -ForegroundColor Cyan

    Connect-ExchangeOnline `
        -ShowBanner:$false `
        -ErrorAction Stop

    Write-Host "Exchange Online connected." -ForegroundColor Green
}

function Restore-ExchangeOnlineConnection {

    # A still active session is kept: disconnecting would force a new interactive sign-in
    $Active = @(
        Get-ConnectionInformation -ErrorAction SilentlyContinue |
            Where-Object { $_.State -eq "Connected" }
    )

    if ($Active.Count -gt 0) {
        return
    }

    Write-Host "Restoring Exchange Online connection..." -ForegroundColor Yellow

    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }
    catch {
        Write-Verbose "Disconnect failed: $($_.Exception.Message)"
    }

    Connect-ExchangeOnlineSafe
}

# ============================================================
# Initialize environment
# ============================================================

if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    throw "ExchangeOnlineManagement module is not installed."
}

Import-Module ExchangeOnlineManagement -ErrorAction Stop

# Connect only when no active Exchange Online connection exists
$Connection = @(
    Get-ConnectionInformation -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq "Connected" }
)

if ($Connection.Count -eq 0) {
    Connect-ExchangeOnlineSafe
}

# Saved in each record, so a report is never resumed against a different tenant
$TenantId = [string](
    Get-ConnectionInformation |
        Where-Object { $_.State -eq "Connected" } |
        Select-Object -First 1
).TenantID

# Retrieve all shared mailboxes
Write-Host "Retrieving shared mailboxes..." -ForegroundColor Cyan

$Mailboxes = @(
    Get-EXOMailbox `
        -RecipientTypeDetails SharedMailbox `
        -ResultSize Unlimited `
        -Properties GrantSendOnBehalfTo `
        -ErrorAction Stop
)

Write-Host "Shared mailboxes found: $($Mailboxes.Count)" -ForegroundColor Cyan

# ============================================================
# Load existing audit
# ============================================================

$Completed = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

if (Test-Path $ReportPath) {

    Write-Host "Existing audit found. Loading completed records..." -ForegroundColor Cyan

    # Never resume (and append to) a CSV written by something else
    $HeaderLine = Get-Content -Path $ReportPath -TotalCount 1
    $Columns = @(
        "$HeaderLine".Split(";") | ForEach-Object { $_.Trim().Trim('"') }
    )
    $MissingColumns = @(
        "PrimarySmtpAddress", "Status" | Where-Object { $_ -notin $Columns }
    )
    if ($HeaderLine -and $MissingColumns.Count -gt 0) {
        throw "The file '$ReportPath' is not a report created by this script (missing columns: $($MissingColumns -join ', ')). Use a different -ReportPath."
    }

    $ExistingRecords = @(
        Import-Csv -Path $ReportPath -Delimiter ";" |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.PrimarySmtpAddress) -and
                $_.Status -eq "Completed"
            }
    )

    foreach ($Record in $ExistingRecords) {
        [void]$Completed.Add($Record.PrimarySmtpAddress.Trim())
    }

    if ($ExistingRecords.Count -gt 0) {

        # Reports created before the Tenant column existed have no tenant to compare
        $ReportTenants = @(
            $ExistingRecords |
                Where-Object { $_.PSObject.Properties["Tenant"] -and $_.Tenant } |
                Select-Object -ExpandProperty Tenant -Unique
        )
        $OtherTenants = @($ReportTenants | Where-Object { $_ -ne $TenantId })
        $PendingCount = @(
            $Mailboxes | Where-Object {
                -not $Completed.Contains($_.PrimarySmtpAddress.ToString().Trim())
            }
        ).Count

        if ($OtherTenants.Count -gt 0 -and $Mode -ne "Restart") {
            throw "The report '$ReportPath' belongs to a different tenant ($($OtherTenants -join ', ')). Use a different -ReportPath, or -Mode Restart to archive it and start a new audit."
        }

        if (-not $Mode) {

            if ($ReportTenants.Count -eq 0) {
                Write-Warning "The report has no tenant information: make sure it was created for tenant $TenantId."
            }

            if ($PendingCount -gt 0) {
                Write-Host "Partial audit found: $($Mailboxes.Count - $PendingCount) of $($Mailboxes.Count) mailboxes completed." -ForegroundColor Yellow
                $Answer = Read-Host "Type R to resume, N to start a new audit (the current report will be archived), anything else to abort"
            }
            else {
                Write-Host "The report already contains a completed audit." -ForegroundColor Yellow
                $Answer = Read-Host "Type N to start a new audit (the current report will be archived), S to show the existing summary, anything else to abort"
            }

            # Separate variable: $null cannot be assigned to $Mode because of its ValidateSet
            $Choice = switch ($Answer.Trim().ToUpperInvariant()) {
                "R" { if ($PendingCount -gt 0) { "Resume" } }
                "N" { "Restart" }
                "S" { if ($PendingCount -eq 0) { "Resume" } }
            }

            if (-not $Choice) {
                Write-Host "Aborted. The report was not changed." -ForegroundColor Green
                return
            }

            $Mode = $Choice
        }

        if ($Mode -eq "Restart") {
            # Archive instead of deleting, so previous results stay available for comparison
            $ArchivePath = Join-Path (Split-Path $ReportPath -Parent) (
                "{0}_{1}{2}" -f [System.IO.Path]::GetFileNameWithoutExtension($ReportPath),
                (Get-Date -Format "yyyyMMdd_HHmmss"),
                [System.IO.Path]::GetExtension($ReportPath)
            )
            Move-Item -Path $ReportPath -Destination $ArchivePath
            $Completed.Clear()
            Write-Host "Previous report archived to: $ArchivePath" -ForegroundColor Cyan
        }
    }
}

# Identify pending mailboxes
$Pending = @(
    $Mailboxes | Where-Object {
        -not $Completed.Contains(
            $_.PrimarySmtpAddress.ToString().Trim()
        )
    }
)

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " SHARED MAILBOX AUDIT" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Total mailboxes: $($Mailboxes.Count)"
Write-Host "Already completed: $($Completed.Count)"
Write-Host "Pending: $($Pending.Count)" -ForegroundColor Yellow
Write-Host "Report: $ReportPath"
Write-Host ""

# ============================================================
# Audit pending mailboxes
# ============================================================

$Index = 0

foreach ($Mailbox in $Pending) {

    $Index++
    $Identity = $Mailbox.PrimarySmtpAddress.ToString()
    $Success = $false

    Write-Progress -Activity "Auditing shared mailboxes" `
        -Status "$Index of $($Pending.Count): $Identity" `
        -PercentComplete (($Index - 1) / $Pending.Count * 100)

    for ($Attempt = 1; $Attempt -le $MaxRetries; $Attempt++) {

        try {
            # Retrieve FullAccess permissions
            $FullAccess = @(
                Get-EXOMailboxPermission `
                    -Identity $Identity `
                    -ErrorAction Stop |
                    Where-Object {
                        $_.AccessRights -contains "FullAccess" -and
                        -not $_.IsInherited -and
                        -not $_.Deny -and
                        $_.User.ToString() -ne "NT AUTHORITY\SELF"
                    }
            )

            # Retrieve SendAs permissions
            $SendAs = @(
                Get-RecipientPermission `
                    -Identity $Identity `
                    -ErrorAction Stop |
                    Where-Object {
                        $_.AccessRights -contains "SendAs" -and
                        -not $_.IsInherited -and
                        -not $_.Deny -and
                        $_.Trustee.ToString() -ne "NT AUTHORITY\SELF"
                    }
            )

            # Retrieve SendOnBehalf permissions
            $SendOnBehalf = @(
                $Mailbox.GrantSendOnBehalfTo |
                    Where-Object { $null -ne $_ }
            )

            # Determine orphan status
            $IsOrphan = (
                $FullAccess.Count -eq 0 -and
                $SendAs.Count -eq 0 -and
                $SendOnBehalf.Count -eq 0
            )

            $Record = [PSCustomObject]@{
                DisplayName        = $Mailbox.DisplayName
                PrimarySmtpAddress = $Identity
                IsOrphan           = $IsOrphan
                FullAccessCount    = $FullAccess.Count
                SendAsCount        = $SendAs.Count
                SendOnBehalfCount  = $SendOnBehalf.Count
                FullAccessUsers    = ($FullAccess.User -join "; ")
                SendAsUsers        = ($SendAs.Trustee -join "; ")
                SendOnBehalfUsers  = ($SendOnBehalf -join "; ")
                Tenant             = $TenantId
                Status             = "Completed"
            }

            # Save immediately
            $ExportParams = @{
                Path              = $ReportPath
                Delimiter         = ";"
                NoTypeInformation = $true
                Encoding          = "utf8BOM"
            }

            if (Test-Path $ReportPath) {
                $ExportParams.Append = $true
            }

            $Record | Export-Csv @ExportParams

            [void]$Completed.Add($Identity)
            $Success = $true

            if ($IsOrphan) {
                Write-Host "Orphan found: $($Mailbox.DisplayName) <$Identity>" -ForegroundColor Yellow
            }

            break
        }
        catch {
            Write-Warning "Attempt $Attempt/$MaxRetries failed for $Identity"
            Write-Warning $_.Exception.Message

            if ($Attempt -lt $MaxRetries) {

                try {
                    Restore-ExchangeOnlineConnection
                }
                catch {
                    Write-Warning "Connection recovery failed: $($_.Exception.Message)"
                }

                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }

    if (-not $Success) {
        Write-Warning "Audit interrupted at $Identity."
        Write-Warning "Run the script again to resume."
        break
    }
}

Write-Progress -Activity "Auditing shared mailboxes" -Completed

# ============================================================
# Final report
# ============================================================

$Results = @()

if (Test-Path $ReportPath) {
    $Results = @(
        Import-Csv -Path $ReportPath -Delimiter ";" |
            Where-Object {
                $_.Status -eq "Completed" -and
                -not [string]::IsNullOrWhiteSpace($_.PrimarySmtpAddress)
            } |
            Group-Object PrimarySmtpAddress |
            ForEach-Object { $_.Group[-1] }
    )
}

$Orphans = @(
    $Results | Where-Object { $_.IsOrphan -eq "True" }
)

$ExpectedAddresses = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($Mailbox in $Mailboxes) {
    [void]$ExpectedAddresses.Add(
        $Mailbox.PrimarySmtpAddress.ToString()
    )
}

$AuditedAddresses = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($Record in $Results) {
    [void]$AuditedAddresses.Add($Record.PrimarySmtpAddress)
}

$MissingCount = 0

foreach ($Address in $ExpectedAddresses) {
    if (-not $AuditedAddresses.Contains($Address)) {
        $MissingCount++
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " AUDIT SUMMARY" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

Write-Host "Total shared mailboxes: $($Mailboxes.Count)"
Write-Host "Audited mailboxes: $($AuditedAddresses.Count)"
Write-Host "Missing mailboxes: $MissingCount"
Write-Host "Orphaned mailboxes: $($Orphans.Count)" -ForegroundColor Yellow

Write-Host ""
Write-Host "ORPHANED MAILBOXES:" -ForegroundColor Yellow

$Orphans |
    Select-Object DisplayName, PrimarySmtpAddress |
    Sort-Object PrimarySmtpAddress |
    Format-Table -AutoSize

Write-Host ""
Write-Host "Report saved to: $ReportPath" -ForegroundColor Green

if ($MissingCount -eq 0) {
    Write-Host "Audit completed successfully." -ForegroundColor Green
}
else {
    Write-Warning "Audit incomplete. Run the script again to resume."
}
