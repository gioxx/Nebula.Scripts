# Work in Progress, not yet ready for general use. Use with caution and test on non-critical data first.

<#
.SYNOPSIS
    Purview Compliance Search preview + confirmed purge for items older than a cutoff date in a mailbox.

.DESCRIPTION
    - Creates (or reuses) a Compliance Search targeting a single mailbox, matching items older than CutoffDate.
    - Runs the search and shows estimated item counts.
    - Creates or reuses a Preview action (no deletion) and waits for completion.
    - Requires explicit confirmation before performing Purge (unless -SkipConfirmation is used).
    - Purge is executed in a loop because Purge actions are limited per mailbox per run.

.REQUIREMENTS
    - ExchangeOnlineManagement module
    - Purview / Security & Compliance PowerShell connectivity via Connect-IPPSSession
    - Appropriate Purview permissions (eDiscovery/Compliance search & purge roles)

.NOTES
    - SoftDelete moves items to Recoverable Items.
    - HardDelete is more aggressive but can still be constrained by holds/retention.
    - Purge actions do not remove unindexed items; counts may show "UnindexedItems".
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Mailbox,

    [datetime]$CutoffDate = [datetime]"2025-01-01",

    [ValidateSet("SoftDelete", "HardDelete")]
    [string]$PurgeType = "SoftDelete",

    [switch]$SkipPreview,

    [switch]$SkipConfirmation,

    [string]$ExistingSearchName,

    [switch]$AutoResumeLatest
)

$ErrorActionPreference = "Stop"

# -------------------------
# Helpers (Purview)
# -------------------------
function Wait-ComplianceSearchCompleted {
    param([Parameter(Mandatory = $true)][string]$Name)

    while ($true) {
        $s = Get-ComplianceSearch -Identity $Name
        if ($s.Status -eq "Completed") { return $s }
        Start-Sleep -Seconds 10
    }
}

function Wait-ComplianceSearchActionCompleted {
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [int]$MaxRetries = 60,
        [int]$SleepSeconds = 5
    )

    $attempt = 0
    while ($true) {
        $attempt++

        try {
            $a = Get-ComplianceSearchAction -Identity $Identity
            if ($a.Status -in @("Completed", "PartiallyCompleted", "Failed")) { return $a }
        }
        catch {
            # Transient backend / propagation errors are common right after action creation.
            # We retry a limited number of times, then rethrow.
            if ($attempt -ge $MaxRetries) {
                throw
            }
        }

        Start-Sleep -Seconds $SleepSeconds
    }
}

function New-UniqueName {
    param([Parameter(Mandatory = $true)][string]$Prefix)
    return ($Prefix + "_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
}

function Test-GetLatestSearchForMailbox {
    param(
        [Parameter(Mandatory = $true)][string]$Mailbox,
        [Parameter(Mandatory = $true)][string]$NamePrefix
    )

    # Best effort: Get-ComplianceSearch returns a list; we filter by name prefix and mailbox presence.
    $all = @(Get-ComplianceSearch)
    if (-not $all -or $all.Count -eq 0) { return $null }

    $candidates = $all | Where-Object {
        $_.Name -like "$NamePrefix*" -and (
            # ExchangeLocation can be string or array depending on environment; best effort
            ($_.ExchangeLocation -eq $Mailbox) -or
            ($_.ExchangeLocation -is [System.Array] -and ($_.ExchangeLocation -contains $Mailbox)) -or
            ($_.ExchangeLocation -isnot [System.Array] -and ($_.ExchangeLocation -match [Regex]::Escape($Mailbox)))
        )
    }

    if (-not $candidates -or $candidates.Count -eq 0) { return $null }

    # Prefer CreatedTime/WhenCreated if present; otherwise fall back to Name (timestamp in name).
    $sorted = $candidates | Sort-Object `
    @{ Expression = { $_.CreatedTime }; Descending = $true }, `
    @{ Expression = { $_.WhenCreated }; Descending = $true }, `
    @{ Expression = { $_.Name }; Descending = $true }

    return $sorted[0].Name
}

function Test-GetCompletedPreviewActionForSearch {
    param([Parameter(Mandatory = $true)][string]$SearchName)

    # Returns the most recent Completed Preview action for the given search, if any.
    $actions = @()

    try {
        $actions = @(Get-ComplianceSearchAction -SearchName $SearchName)
    }
    catch {
        return $null
    }

    if (-not $actions -or $actions.Count -eq 0) { return $null }

    $previewActions = $actions | Where-Object {
        # Action type can show up in Name/Action/Type depending on tenant; best effort matching
        ($_.Action -eq "Preview") -or ($_.Name -match "Preview") -or ($_.Identity -match "Preview")
    }

    if (-not $previewActions -or $previewActions.Count -eq 0) { return $null }

    $completed = $previewActions | Where-Object { $_.Status -eq "Completed" }
    if (-not $completed -or $completed.Count -eq 0) { return $null }

    $sorted = $completed | Sort-Object `
    @{ Expression = { $_.CreatedTime }; Descending = $true }, `
    @{ Expression = { $_.WhenCreated }; Descending = $true }, `
    @{ Expression = { $_.Identity }; Descending = $true }

    return $sorted[0]
}

# -------------------------
# Connect
# -------------------------
Import-Module ExchangeOnlineManagement -ErrorAction Stop

Connect-ExchangeOnline | Out-Null
Connect-IPPSSession -EnableSearchOnlySession | Out-Null

# -------------------------
# Build query
# -------------------------
$cutoffStr = $CutoffDate.ToString("MM/dd/yyyy")
$query = "(Received<$cutoffStr) OR (Sent<$cutoffStr)"

Write-Host "Mailbox: $Mailbox" -ForegroundColor Cyan
Write-Host "Cutoff:  $($CutoffDate.ToString('yyyy-MM-dd')) (items older than this will match)" -ForegroundColor Cyan
Write-Host "Query:   $query" -ForegroundColor Cyan

# -------------------------
# Resolve search name (existing / autoresume / new)
# -------------------------
$searchPrefix = "Purge_PreCutoff_"

if ($ExistingSearchName) {
    $searchName = $ExistingSearchName
    Write-Host "Search:  $searchName (existing)" -ForegroundColor Cyan
}
elseif ($AutoResumeLatest) {
    $latest = Test-GetLatestSearchForMailbox -Mailbox $Mailbox -NamePrefix $searchPrefix
    if ($latest) {
        $searchName = $latest
        Write-Host "Search:  $searchName (auto-resumed latest)" -ForegroundColor Cyan
    }
    else {
        $searchName = New-UniqueName -Prefix $searchPrefix.TrimEnd("_")
        Write-Host "Search:  $searchName (new; no previous found to resume)" -ForegroundColor Yellow
    }
}
else {
    $searchName = New-UniqueName -Prefix $searchPrefix.TrimEnd("_")
    Write-Host "Search:  $searchName (new)" -ForegroundColor Cyan
}

Write-Host ""

# -------------------------
# Create or run search
# -------------------------
$existingSearch = Get-ComplianceSearch -Identity $searchName -ErrorAction SilentlyContinue

if ($existingSearch) {
    Start-ComplianceSearch -Identity $searchName | Out-Null
    $s = Wait-ComplianceSearchCompleted -Name $searchName
}
else {
    # Only create if this is not meant to be an existing search.
    if ($ExistingSearchName) {
        Write-Host "Search '$searchName' not found. Aborting." -ForegroundColor Red
        return
    }

    New-ComplianceSearch -Name $searchName -ExchangeLocation $Mailbox -ContentMatchQuery $query | Out-Null
    Start-ComplianceSearch -Identity $searchName | Out-Null
    $s = Wait-ComplianceSearchCompleted -Name $searchName
}

# Display estimates
Write-Host "Search completed." -ForegroundColor Green
Write-Host ("Estimated items found: {0}" -f $s.Items) -ForegroundColor Yellow
if ($null -ne $s.UnindexedItems) {
    Write-Host ("Estimated unindexed items: {0}" -f $s.UnindexedItems) -ForegroundColor Yellow
}
Write-Host ""

if ([int]$s.Items -le 0) {
    Write-Host "No matching items. Nothing to do." -ForegroundColor Green
    return
}

# -------------------------
# Preview action (optional, smart reuse)
# -------------------------
$previewAction = $null
$previewResult = $null

if (-not $SkipPreview) {

    # If resuming an existing search, prefer reusing the latest Completed preview action.
    $existingPreview = Test-GetCompletedPreviewActionForSearch -SearchName $searchName
    if ($existingPreview) {
        $previewAction = $existingPreview
        Write-Host "Reusing existing Preview action (Completed): $($previewAction.Identity)" -ForegroundColor Cyan
        $previewResult = $previewAction
        Write-Host ""
    }
    else {
        Write-Host "Creating Preview action (no deletion)..." -ForegroundColor Cyan

        $previewAction = New-ComplianceSearchAction -SearchName $searchName -Preview -Force -Confirm:$false

        # Give the service a moment to register the action before polling.
        Start-Sleep -Seconds 15

        $previewResult = Wait-ComplianceSearchActionCompleted -Identity $previewAction.Identity

        Write-Host ("Preview action status: {0}" -f $previewResult.Status) -ForegroundColor Green

        if ($previewResult.Results) {
            Write-Host "Preview action results summary:" -ForegroundColor Cyan
            Write-Host $previewResult.Results
            Write-Host ""
        }
        else {
            Write-Host "Preview created. For item-level review, open the search in the Purview portal and use Preview/Export." -ForegroundColor Yellow
            Write-Host ""
        }
    }
}
else {
    Write-Host "Preview skipped by parameter." -ForegroundColor Yellow
    Write-Host ""
}

# -------------------------
# Purview hints
# -------------------------
$purviewHome = "https://purview.microsoft.com"

Write-Host ""
Write-Host "Purview portal:" -ForegroundColor Cyan
Write-Host "  $purviewHome" -ForegroundColor Cyan
Write-Host ""
Write-Host "Find the search by name:" -ForegroundColor Yellow
Write-Host "  Search name: $searchName" -ForegroundColor Yellow

if (-not $SkipPreview -and $null -ne $previewAction -and $previewAction.Identity) {
    Write-Host "  Preview action id: $($previewAction.Identity)" -ForegroundColor Yellow
}
else {
    Write-Host "  Preview action id: (preview not created / skipped)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Suggested path in Purview:" -ForegroundColor Cyan
Write-Host "  eDiscovery -> Content search -> open '$searchName' -> Preview / Export" -ForegroundColor Cyan
Write-Host ""

# -------------------------
# Confirmation gate
# -------------------------
if (-not $SkipConfirmation) {
    Write-Host "About to PURGE items older than $($CutoffDate.ToString('yyyy-MM-dd')) from: $Mailbox" -ForegroundColor Red
    Write-Host "PurgeType: $PurgeType" -ForegroundColor Red
    Write-Host ""
    $confirm = Read-Host "Type YES to proceed with deletion (anything else will abort)"

    if ($confirm -ne "YES") {
        Write-Host "Aborted. No deletion performed." -ForegroundColor Green
        return
    }
}
else {
    Write-Host "Confirmation skipped by parameter. Proceeding with deletion..." -ForegroundColor Yellow
}

# -------------------------
# Purge loop
# -------------------------
Write-Host ""
Write-Host "Starting purge loop..." -ForegroundColor Cyan

$iteration = 0
while ($true) {
    $iteration++

    Start-ComplianceSearch -Identity $searchName | Out-Null
    $s = Wait-ComplianceSearchCompleted -Name $searchName

    if ([int]$s.Items -le 0) {
        Write-Host "Done. No more items matching the query." -ForegroundColor Green
        break
    }

    Write-Host ("Iteration {0} - remaining estimated items: {1}" -f $iteration, $s.Items) -ForegroundColor Yellow

    $purgeAction = New-ComplianceSearchAction -SearchName $searchName -Purge -PurgeType $PurgeType -Force -Confirm:$false

    Start-Sleep -Seconds 15
    $purgeResult = Wait-ComplianceSearchActionCompleted -Identity $purgeAction.Identity

    # Give the backend some time to apply changes before re-running the search.
    Start-Sleep -Seconds 15

    Write-Host ("Purge action status: {0}" -f $purgeResult.Status) -ForegroundColor Green

    if ($purgeResult.Status -eq "Failed") {
        Write-Host "Purge action failed. Stop and review the action details in Purview / PowerShell output." -ForegroundColor Red
        break
    }
}

Write-Host "All done." -ForegroundColor Green
