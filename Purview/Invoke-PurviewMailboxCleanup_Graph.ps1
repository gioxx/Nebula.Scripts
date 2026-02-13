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
      - Preview: Graph scopes Mail.Read + User.Read.All (or equivalent app-only permissions)
      - Purge: eDiscovery/Compliance roles to run compliance searches and purge actions

    Important limitations:
      - Purge actions do not remove unindexed items.
      - Holds/retention may prevent "real" removal (items may remain discoverable).
      - SoftDelete moves items to Recoverable Items.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Mailbox,

    [datetime]$CutoffDate = [datetime]"2025-01-01",

    [int]$PreviewCount = 50,

    [switch]$PreviewOnly,

    [ValidateSet("SoftDelete", "HardDelete")]
    [string]$PurgeType = "SoftDelete"
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
    Connect-MgGraph -Scopes "Mail.Read", "User.Read.All" | Out-Null

    $cutoffIso = Format-GraphDate -DateTime $CutoffDate
    $half = [Math]::Ceiling($PreviewCount / 2)

    Write-Host "Previewing up to $PreviewCount messages (approx. $half received + $half sent) older than $($CutoffDate.ToString('yyyy-MM-dd')) for $Mailbox" -ForegroundColor Cyan

    # --- Get folders (top-level) ---
    $foldersResp = Invoke-GraphGet -Uri "/users/$Mailbox/mailFolders?`$top=200&`$select=id,displayName"
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
            $f = Invoke-GraphGet -Uri "/users/$Mailbox/mailFolders/$FolderId?`$select=displayName"
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

        $uri = "/users/$Mailbox/mailFolders/$($f.id)/messages?" +
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
    $sentUri = "/users/$Mailbox/mailFolders/sentitems/messages?" +
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

# Compliance Search query uses US-style date in many tenants (MM/dd/yyyy).
# We delete items strictly older than the cutoff date.
$cutoffStr = $CutoffDate.ToString("MM/dd/yyyy")
$query = "(Received<$cutoffStr) OR (Sent<$cutoffStr)"

$searchName = "Purge_PreCutoff_" + (Get-Date -Format "yyyyMMdd_HHmmss")

New-ComplianceSearch -Name $searchName -ExchangeLocation $Mailbox -ContentMatchQuery $query | Out-Null

function Wait-ComplianceSearchCompleted {
    param([Parameter(Mandatory = $true)][string]$Name)

    while ($true) {
        $s = Get-ComplianceSearch -Identity $Name
        if ($s.Status -eq "Completed") { return $s }
        Start-Sleep -Seconds 10
    }
}

function Wait-ComplianceSearchActionCompleted {
    param([Parameter(Mandatory = $true)][string]$ActionIdentity)

    while ($true) {
        $a = Get-ComplianceSearchAction -Identity $ActionIdentity
        if ($a.Status -in @("Completed", "PartiallyCompleted", "Failed")) { return $a }
        Start-Sleep -Seconds 10
    }
}

$iteration = 0
while ($true) {
    $iteration++
    Start-ComplianceSearch -Identity $searchName | Out-Null
    $s = Wait-ComplianceSearchCompleted -Name $searchName

    if ([int]$s.Items -le 0) {
        Write-Host "Done. No more items matching the query." -ForegroundColor Green
        break
    }

    Write-Host "Iteration $iteration - items matching query: $($s.Items)" -ForegroundColor Yellow

    $action = New-ComplianceSearchAction -SearchName $searchName -Purge -PurgeType $PurgeType -Force
    $a = Wait-ComplianceSearchActionCompleted -ActionIdentity $action.Identity

    Write-Host "Purge action status: $($a.Status)"
}
