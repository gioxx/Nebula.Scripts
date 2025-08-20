<#
.SYNOPSIS
    Detection script for OneStart AI browser
.DESCRIPTION
    Detects presence of OneStart AI artifacts (processes, scheduled tasks,
    registry keys/values, startup shortcuts, and per-user folders).
    If any indicators are found, exit code 1 (non-compliant / trigger remediation in Intune).
.EXAMPLE
    .\OneStartAI_Detection.ps1
.NOTES
    Author: Giovanni Solone
    Date: 2025-08-19

    Credits:
    - https://github.com/cbl508/OneStart.ai_Removal
    - https://www.reddit.com/r/24hoursupport/comments/1hrdk7s/hp_computers_keep_installing_onestart_ai_browser/
    - https://www.reddit.com/r/crowdstrike/comments/1id39cp/onestartai_remover/

    Modification History:
    - 2025-08-20: Minor fixes.
    - 2025-08-19: Initial version for OneStart AI detection.
#>

[CmdletBinding()]
param(
    [switch]$Json,
    [string]$OutPath,
    [switch]$Quiet
)

function New-ResultObject {
    param(
        [string]$Category,
        [string]$Target,
        [string]$Signal,
        [string]$Details
    )
    [pscustomobject]@{
        Timestamp = (Get-Date).ToString('s')
        Category  = $Category
        Target    = $Target
        Signal    = $Signal
        Details   = $Details
    }
}

function Write-Info {
    param([string]$Text)
    if (-not $Quiet) { Write-Output $Text }
}

function Get-UserProfileRoots {
    <#
    .SYNOPSIS
        Enumerate non-system user profile directories.
    #>
    Get-ChildItem -Path 'C:\Users' -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -notin @('All Users', 'Default', 'Default User', 'DefaultAppPool', 'Public')
    }
}

function Get-HkuHives {
    <#
    .SYNOPSIS
        Enumerate HKU hives excluding system/builtin ones.
    #>
    Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue | Where-Object {
        $_.PSChildName -notmatch '(^S-1-5-18$)|(^S-1-5-19$)|(^S-1-5-20$)|(^\.DEFAULT$)'
    }
}

function Get-ShortcutMeta {
    <#
    .SYNOPSIS
        Read .lnk target, args, and working dir using WScript.Shell.
    #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($Path)
        $obj = [pscustomobject]@{
            TargetPath = $sc.TargetPath
            Arguments  = $sc.Arguments
            WorkingDir = $sc.WorkingDirectory
        }
        # Best-effort COM release (optional)
        try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sc) } catch {}
        try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) } catch {}
        return $obj
    } catch {
        return $null
    }
}

function Test-OneStartMatch {
    <#
    .SYNOPSIS
        Returns $true if text matches known OneStart/DBar markers.
    #>
    param([Parameter(Mandatory)][string]$Text)
    return ($Text -match '(?i)\bOneStart(?:\.ai)?\b' -or $Text -match '(?i)\bDBar\b')
}

# --- Indicators (kept aligned with remediation) ---
$ProcessNames = @('DBar')
$ScheduledTaskNames = @('OneStart Chromium', 'OneStart Updater')
$ScheduledTaskPatterns = @('*OneStart*', '*OneStart*Updater*', '*DBar*')
$RunValueNames = @('OneStartBar', 'OneStartBarUpdate', 'OneStartUpdate')
$RegProductKeysRel = @('Software\OneStart.ai')

$Results = New-Object System.Collections.Generic.List[object]

# --- Processes ---
foreach ($name in $ProcessNames) {
    $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
    foreach ($p in ($procs | Sort-Object Id)) {
        # Path can be null on 5.1; handle safely
        $pPath = $null
        try { $pPath = $p.Path } catch { $pPath = '' }
        $Results.Add((New-ResultObject -Category 'Process' -Target "$($p.ProcessName) (PID $($p.Id))" -Signal 'Found' -Details $pPath))
    }
}

# --- Startup shortcuts (.lnk) ---
foreach ($root in (Get-UserProfileRoots)) {
    $glob = 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\*.lnk'
    $probe = Join-Path -Path $root.FullName -ChildPath $glob
    foreach ($hit in (Resolve-Path $probe -ErrorAction SilentlyContinue)) {
        $meta = Get-ShortcutMeta -Path $hit.Path
        $target = if ($meta -and $meta.TargetPath) { $meta.TargetPath } else { '' }
        $lnkArgs = if ($meta -and $meta.Arguments) { $meta.Arguments } else { '' }
        $text = "$($hit.Path) $target $lnkArgs"

        if (Test-OneStartMatch -Text $text) {
            $Results.Add((New-ResultObject -Category 'StartupShortcut' -Target $hit.Path -Signal 'Found' -Details ("$target $lnkArgs").Trim()))
        }
    }
}

# --- Registry per-user (HKU) ---
foreach ($hku in (Get-HkuHives)) {
    $base = "Registry::$($hku.PSChildName)"

    foreach ($rel in $RegProductKeysRel) {
        $key = Join-Path -Path $base -ChildPath $rel
        if (Test-Path $key) {
            $Results.Add((New-ResultObject -Category 'RegistryKey' -Target $key -Signal 'Found' -Details ''))
        }
    }

    $runKey = Join-Path -Path $base -ChildPath 'Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path $runKey) {
        foreach ($name in $RunValueNames) {
            try {
                $val = (Get-ItemProperty -Path $runKey -Name $name -ErrorAction Stop).$name
                if ($null -ne $val) {
                    $Results.Add((New-ResultObject -Category 'RegistryValue' -Target "$($runKey)::$($name)" -Signal 'Found' -Details $val))
                }
            } catch {
                # ignore missing values
            }
        }
    }
}

# --- Scheduled tasks (by exact known names) ---
foreach ($tname in $ScheduledTaskNames) {
    foreach ($t in (Get-ScheduledTask -TaskName $tname -ErrorAction SilentlyContinue)) {
        $full = "$($t.TaskPath)$($t.TaskName)"
        $Results.Add((New-ResultObject -Category 'ScheduledTask' -Target $t.TaskName -Signal 'Found' -Details $full))
    }
}

# --- Scheduled tasks (pattern sweep) ---
$allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue
if ($allTasks) {
    foreach ($pat in $ScheduledTaskPatterns) {
        foreach ($t in ($allTasks | Where-Object { $_.TaskName -like $pat -or $_.TaskPath -like $pat })) {
            $full = "$($t.TaskPath)$($t.TaskName)"
            $Results.Add((New-ResultObject -Category 'ScheduledTask' -Target $t.TaskName -Signal 'Found' -Details $full))
        }
    }
}

# --- Per-user folders (aligned with remediation deletions) ---
foreach ($root in (Get-UserProfileRoots)) {
    $folders = @(
        (Join-Path -Path $root.FullName -ChildPath 'AppData\Roaming\OneStart'),
        (Join-Path -Path $root.FullName -ChildPath 'AppData\Local\OneStart.ai'),
        (Join-Path -Path $root.FullName -ChildPath 'AppData\Local\OneStart')
    )
    foreach ($f in $folders) {
        if ($null -ne $f -and (Test-Path $f)) {
            $Results.Add((New-ResultObject -Category 'File' -Target $f -Signal 'Found' -Details 'FolderExists'))
        }
    }
}

# --- Output ---
if ($Results.Count -eq 0) { Write-Info 'No OneStart indicators were found.' }

if ($Json -or $OutPath) {
    $json = $Results | ConvertTo-Json -Depth 6
    if ($OutPath) { $json | Out-File -FilePath $OutPath -Encoding UTF8 }
    $json
} else {
    $Results | Sort-Object Category, Target | Format-Table -AutoSize
}

# --- Compliance exit code (1 = non-compliant / trigger remediation) ---
$needRemediation = $Results | Where-Object {
    ($_.'Category' -in 'Process', 'ScheduledTask', 'RegistryKey', 'RegistryValue', 'File', 'StartupShortcut') -and
    (($_.Target -match '(?i)\bOneStart(?:\.ai)?\b|\bDBar\b') -or ($_.Details -match '(?i)\bOneStart(?:\.ai)?\b|\bDBar\b') -or ($_.Signal -eq 'Found'))
}

if ($needRemediation.Count -gt 0) { exit 1 } else { exit 0 }
