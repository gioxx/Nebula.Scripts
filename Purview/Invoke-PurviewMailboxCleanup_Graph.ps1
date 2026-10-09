# Work in Progress, not yet ready for general use. Use with caution and test on non-critical data first.

<#
.SYNOPSIS
    Preview (sample) and purge emails older than a cutoff date in an Exchange Online shared mailbox.

.DESCRIPTION
    - PreviewOnly mode:
        Uses Microsoft Graph (folder-based) to show a sample of messages older than the cutoff date.
        This avoids Graph endpoints that may fail on some shared mailboxes (e.g., "AllItems" issues).
        The sample is built from multiple folders (excluding Sent Items) + Sent Items.

    - Purge mode:
        Uses Purview (Compliance Search + Purge) to delete items older than the cutoff.
        Purge is performed in a loop because purge actions have per-mailbox deletion limits.

.NOTES
    Requirements:
      - Microsoft.Graph.Authentication module (preview)
      - ExchangeOnlineManagement module (purge)
    Permissions:
      - Preview: Graph delegated scopes Mail.Read + Mail.Read.Shared (or equivalent app-only permissions)
      - Purge: eDiscovery/Compliance roles to run compliance searches and purge actions

    Important limitations:
      - Purge actions do not remove unindexed items.
      - Holds/retention may prevent "real" removal (items may remain discoverable).
      - SoftDelete moves items to Recoverable Items.
      - The purge loop stops when the item count does not decrease for 3 consecutive iterations.

    Modification History:
    2026-10-09: Purge mode now shows the estimated item count and asks for YES confirmation (use -SkipConfirmation to bypass).
                CutoffDate is now mandatory. Query dates use a culture-independent format.
                Added timeouts to search/action polling, stop on failed purge actions, maximum iterations and stall detection.
                Fixed folder name lookup in preview ("$FolderId?" expanded an undefined variable).
                Preview uses Mail.Read.Shared, required to read shared mailboxes with delegated permissions.

.PARAMETER Mailbox
    Mailbox (address or identity) to preview and purge.

.PARAMETER CutoffDate
    Items received or sent before this date are matched. Mandatory, to avoid purging with an unintended default.

.PARAMETER PreviewCount
    Maximum number of messages shown in PreviewOnly mode. Default: 50.

.PARAMETER PreviewOnly
    Shows a sample of matching messages via Microsoft Graph. Nothing is deleted.

.PARAMETER PurgeType
    SoftDelete (default, items go to Recoverable Items) or HardDelete.

.PARAMETER SkipConfirmation
    Does not ask for the YES confirmation before purging.

.PARAMETER TimeoutMinutes
    Maximum minutes to wait for a single search run or purge action to complete. Default: 60.

.PARAMETER MaxPurgeIterations
    Maximum number of purge iterations before stopping. Default: 200.

.EXAMPLE
    .\Invoke-PurviewMailboxCleanup_Graph.ps1 -Mailbox 'shared@contoso.com' -CutoffDate '2025-01-01' -PreviewOnly
    Shows a sample of messages older than 2025-01-01. Nothing is deleted.

.EXAMPLE
    .\Invoke-PurviewMailboxCleanup_Graph.ps1 -Mailbox 'shared@contoso.com' -CutoffDate '2025-01-01'
    Runs a Compliance Search, shows the estimated item count and purges after YES confirmation.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Mailbox,

    [Parameter(Mandatory = $true)]
    [datetime]$CutoffDate,

    [ValidateRange(1, 1000)]
    [int]$PreviewCount = 50,

    [switch]$PreviewOnly,

    [ValidateSet("SoftDelete", "HardDelete")]
    [string]$PurgeType = "SoftDelete",

    [switch]$SkipConfirmation,

    [ValidateRange(1, 1440)]
    [int]$TimeoutMinutes = 60,

    [ValidateRange(1, 10000)]
    [int]$MaxPurgeIterations = 200
)

# -------------------------
# Helpers (Graph)
# -------------------------
function Format-GraphDate {
    param([Parameter(Mandatory = $true)][datetime]$DateTime)

    # Graph wants ISO 8601 UTC, e.g. 2025-01-01T00:00:00Z
    return ($DateTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))
}

function Invoke-GraphGet {
    param([Parameter(Mandatory = $true)][string]$Uri)

    $headers = @{ "ConsistencyLevel" = "eventual" }

    # Ensure we always call a versioned Graph endpoint.
    if ($Uri -notmatch '^/v1\.0/' -and $Uri -notmatch '^/beta/') {
        if ($Uri.StartsWith('/')) {
            $Uri = "/v1.0$Uri"
        }
        else {
            $Uri = "/v1.0/$Uri"
        }
    }

    return Invoke-MgGraphRequest -Method GET -Uri $Uri -Headers $headers -ErrorAction Stop
}

# -------------------------
# PREVIEW MODE (Graph, folder-based)
# -------------------------
if ($PreviewOnly) {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    # You can reduce scopes if your tenant policies allow it; this is a safe baseline for shared mailbox reads.
    # Mail.Read.Shared is required to read a shared mailbox with delegated permissions.
    Connect-MgGraph -Scopes "Mail.Read", "Mail.Read.Shared" -NoWelcome | Out-Null

    $cutoffIso = Format-GraphDate -DateTime $CutoffDate
    $mailboxPath = [uri]::EscapeDataString($Mailbox)
    $half = [Math]::Ceiling($PreviewCount / 2)

    Write-Host "Previewing up to $PreviewCount messages (approx. $half received + $half sent) older than $($CutoffDate.ToString('yyyy-MM-dd')) for $Mailbox" -ForegroundColor Cyan

    # --- Get folders (top-level) ---
    $foldersResp = Invoke-GraphGet -Uri "/users/$mailboxPath/mailFolders?`$top=200&`$select=id,displayName"
    $folders = @($foldersResp.value)

    if (-not $folders -or $folders.Count -eq 0) {
        Write-Host "No folders returned from Graph. Check mailbox existence, Graph permissions, and whether the mailbox is accessible via Graph." -ForegroundColor Yellow
        Write-Host "Preview complete. No deletion performed." -ForegroundColor Green
        return
    }

    # Avoid sampling from Sent Items in the "received" pool
    $skipFolderNames = @("Sent Items", "Posta inviata")

    # Folder name cache (best effort)
    $folderNameCache = @{}
    function Resolve-FolderName {
        param([string]$FolderId)

        if (-not $FolderId) { return "" }
        if ($folderNameCache.ContainsKey($FolderId)) { return $folderNameCache[$FolderId] }

        try {
            $f = Invoke-GraphGet -Uri "/users/$mailboxPath/mailFolders/${FolderId}?`$select=displayName"
            $folderNameCache[$FolderId] = $f.displayName
            return $f.displayName
        }
        catch {
            $folderNameCache[$FolderId] = $FolderId
            return $FolderId
        }
    }

    # --- Received sample: gather from folders until we reach $half ---
    $recv = @()
    foreach ($f in $folders) {
        if ($recv.Count -ge $half) { break }
        if ($skipFolderNames -contains $f.displayName) { continue }

        # Take a small bite per folder to build a mixed preview
        $take = [Math]::Min(10, ($half - $recv.Count))
        if ($take -le 0) { break }

        $uri = "/users/$mailboxPath/mailFolders/$($f.id)/messages?" +
        "`$filter=receivedDateTime lt $cutoffIso&" +
        "`$orderby=receivedDateTime asc&" +
        "`$top=$take&" +
        "`$select=subject,from,receivedDateTime,parentFolderId"

        try {
            $r = Invoke-GraphGet -Uri $uri
            if ($r.value) { $recv += @($r.value) }
        }
        catch {
            # Ignore folders we can't read for any reason and continue
            continue
        }
    }

    # --- Sent sample: Sent Items ---
    $sentUri = "/users/$mailboxPath/mailFolders/sentitems/messages?" +
    "`$filter=sentDateTime lt $cutoffIso&" +
    "`$orderby=sentDateTime asc&" +
    "`$top=$half&" +
    "`$select=subject,toRecipients,sentDateTime,parentFolderId"

    $sent = @()
    try {
        $sent = @((Invoke-GraphGet -Uri $sentUri).value)
    }
    catch {
        # If sentitems fails, keep going and just show received sample
        $sent = @()
    }

    # Build output
    $rows = @()

    foreach ($m in $recv) {
        $fromAddr = ""
        if ($m.from -and $m.from.emailAddress) { $fromAddr = $m.from.emailAddress.address }

        $rows += [pscustomobject]@{
            Type    = "Received"
            Date    = $m.receivedDateTime
            From    = $fromAddr
            To      = ""
            Subject = $m.subject
            Folder  = (Resolve-FolderName -FolderId $m.parentFolderId)
        }
    }

    foreach ($m in $sent) {
        $to = ""
        if ($m.toRecipients) {
            $to = ($m.toRecipients | ForEach-Object { $_.emailAddress.address }) -join "; "
        }

        $rows += [pscustomobject]@{
            Type    = "Sent"
            Date    = $m.sentDateTime
            From    = ""
            To      = $to
            Subject = $m.subject
            Folder  = (Resolve-FolderName -FolderId $m.parentFolderId)
        }
    }

    if ($rows.Count -eq 0) {
        Write-Host "No messages returned in preview sample. This can mean there are no items older than cutoff or Graph access is restricted." -ForegroundColor Yellow
    }
    else {
        $rows |
        Sort-Object Date |
        Select-Object -First $PreviewCount |
        Format-Table -AutoSize
    }

    Write-Host ""
    Write-Host "Preview complete. No deletion performed." -ForegroundColor Green
    return
}

# -------------------------
# PURGE MODE (Compliance Search + Purge)
# -------------------------
Import-Module ExchangeOnlineManagement -ErrorAction Stop

Connect-ExchangeOnline | Out-Null
Connect-IPPSSession -EnableSearchOnlySession | Out-Null

# Culture-independent ISO date: "MM/dd/yyyy" would use the local date separator (e.g. "01.31.2025" on de-DE).
# We delete items strictly older than the cutoff date.
$cutoffStr = $CutoffDate.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
$query = "(Received<$cutoffStr) OR (Sent<$cutoffStr)"

function Wait-ComplianceSearchCompleted {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutMinutes = 60
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        $s = Get-ComplianceSearch -Identity $Name
        if ($s.Status -eq "Completed") { return $s }
        if ($s.Status -in @("Stopped", "Failed")) {
            throw "Compliance search '$Name' ended with status '$($s.Status)'. Errors: $($s.Errors)"
        }
        if ((Get-Date) -gt $deadline) {
            throw "Compliance search '$Name' did not complete within $TimeoutMinutes minutes (last status: $($s.Status))."
        }
        Start-Sleep -Seconds 10
    }
}

function Wait-ComplianceSearchActionCompleted {
    param(
        [Parameter(Mandatory = $true)][string]$ActionIdentity,
        [int]$MaxRetries = 60,
        [int]$TimeoutMinutes = 60
    )

    $attempt = 0
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        $attempt++

        try {
            $a = Get-ComplianceSearchAction -Identity $ActionIdentity
            if ($a.Status -in @("Completed", "PartiallyCompleted", "Failed")) { return $a }
        }
        catch {
            # Transient backend / propagation errors are common right after action creation.
            if ($attempt -ge $MaxRetries) {
                throw
            }
        }

        if ((Get-Date) -gt $deadline) {
            throw "Compliance search action '$ActionIdentity' did not complete within $TimeoutMinutes minutes."
        }

        Start-Sleep -Seconds 10
    }
}

$searchName = "Purge_PreCutoff_" + (Get-Date -Format "yyyyMMdd_HHmmss")

Write-Host "Mailbox: $Mailbox" -ForegroundColor Cyan
Write-Host "Query:   $query" -ForegroundColor Cyan
Write-Host "Search:  $searchName" -ForegroundColor Cyan

New-ComplianceSearch -Name $searchName -ExchangeLocation $Mailbox -ContentMatchQuery $query | Out-Null
Start-ComplianceSearch -Identity $searchName | Out-Null
$s = Wait-ComplianceSearchCompleted -Name $searchName -TimeoutMinutes $TimeoutMinutes

Write-Host ("Estimated items found: {0}" -f $s.Items) -ForegroundColor Yellow
if ([int]$s.Items -le 0) {
    Write-Host "No matching items. Nothing to do." -ForegroundColor Green
    return
}

# -------------------------
# Confirmation gate
# -------------------------
if (-not $SkipConfirmation) {
    Write-Host ""
    Write-Host "About to PURGE items older than $($CutoffDate.ToString('yyyy-MM-dd')) from: $Mailbox" -ForegroundColor Red
    Write-Host "PurgeType: $PurgeType" -ForegroundColor Red
    Write-Host "Tip: run with -PreviewOnly first to see a sample of the messages." -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "Type YES to proceed with deletion (anything else will abort)"

    if ($confirm -ne "YES") {
        Write-Host "Aborted. No deletion performed. The search '$searchName' was kept for review in Purview." -ForegroundColor Green
        return
    }
}
else {
    Write-Host "Confirmation skipped by parameter. Proceeding with deletion..." -ForegroundColor Yellow
}

$iteration = 0
$previousItems = $null
$stalledIterations = 0
while ($true) {
    $iteration++

    if ($iteration -gt $MaxPurgeIterations) {
        Write-Host "Reached the maximum number of purge iterations ($MaxPurgeIterations). Stopping; re-run to continue." -ForegroundColor Yellow
        break
    }

    # The first iteration reuses the search that was just run for the estimate.
    if ($iteration -gt 1) {
        Start-ComplianceSearch -Identity $searchName | Out-Null
        $s = Wait-ComplianceSearchCompleted -Name $searchName -TimeoutMinutes $TimeoutMinutes
    }

    if ([int]$s.Items -le 0) {
        Write-Host "Done. No more items matching the query." -ForegroundColor Green
        break
    }

    Write-Host "Iteration $iteration - items matching query: $($s.Items)" -ForegroundColor Yellow

    # Items on hold/retention (or otherwise not purgeable) keep the count constant: stop instead of looping forever.
    if ($null -ne $previousItems -and [int]$s.Items -ge $previousItems) {
        $stalledIterations++
        if ($stalledIterations -ge 3) {
            Write-Host "The item count has not decreased for 3 iterations ($($s.Items) items left). Remaining items are probably on hold/retention or not purgeable. Stopping." -ForegroundColor Red
            break
        }
    }
    else {
        $stalledIterations = 0
    }
    $previousItems = [int]$s.Items

    $action = New-ComplianceSearchAction -SearchName $searchName -Purge -PurgeType $PurgeType -Force -Confirm:$false

    # Give the service a moment to register the action before polling.
    Start-Sleep -Seconds 15
    $a = Wait-ComplianceSearchActionCompleted -ActionIdentity $action.Identity -TimeoutMinutes $TimeoutMinutes

    Write-Host "Purge action status: $($a.Status)"

    if ($a.Status -eq "Failed") {
        Write-Host "Purge action failed. Stop and review the action details in Purview / PowerShell output." -ForegroundColor Red
        break
    }

    # Give the backend some time to apply changes before re-running the search.
    Start-Sleep -Seconds 15
}
