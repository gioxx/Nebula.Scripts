<#
.SYNOPSIS
    Remediation script for OneStart AI (malicious persistence)
.DESCRIPTION
    This script removes OneStart AI artifacts from the system. 
    It terminates any related processes, deletes scheduled tasks, 
    removes registry keys and startup entries, and cleans up files 
    from user profiles. Run elevated. Supports -WhatIf for dry runs.
.EXAMPLE
    .\OneStart-Remediate.ps1 -WhatIf
.NOTES
    Author: Giovanni Solone
    Date: 2025-08-19

    Credits:
    - https://github.com/cbl508/OneStart.ai_Removal
    - https://www.reddit.com/r/24hoursupport/comments/1hrdk7s/hp_computers_keep_installing_onestart_ai_browser/
    - https://www.reddit.com/r/crowdstrike/comments/1id39cp/onestartai_remover/
    
    Modification History:
    - 2025-08-20: Fixes for string parsing (::), PS 5.1 compatibility, and ShouldProcess on Remove-TaskSafe.
    - 2025-08-19: Initial version for OneStart AI remediation.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$Quiet,
    [string]$LogPath = "$env:ProgramData\Logs\OneStart_Cleanup.log",
    [switch]$Aggressive
)

function Write-Log {
    param([string]$Text)
    if ($Quiet) { return }
    try {
        # Ensure log directory exists
        $dir = Split-Path -Parent $LogPath
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -Path $LogPath -Value "[$((Get-Date).ToString('s'))] $Text" -ErrorAction SilentlyContinue
        Write-Output $Text
    } catch {
        # Intentionally swallow logging failures
    }
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
        # Try to release COM objects (best-effort)
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

$ProcessNames = @('DBar')
$ScheduledTaskNames = @('OneStart Chromium', 'OneStart Updater')
$ScheduledTaskPatterns = @('*OneStart*', '*OneStart*Updater*', '*DBar*')
$RunValueNames = @('OneStartBar', 'OneStartBarUpdate', 'OneStartUpdate')
$RegProductKeysRel = @('Software\OneStart.ai')

# --- Kill known processes
foreach ($name in $ProcessNames) {
    $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
    foreach ($p in ($procs | Sort-Object Id -Descending)) {
        if ($PSCmdlet.ShouldProcess("$($p.ProcessName) (PID $($p.Id))", 'Stop-Process -Force')) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                Write-Log "Stopped process $($p.ProcessName) PID $($p.Id)."
            } catch {
                Write-Log "Failed to stop $($p.ProcessName) PID $($p.Id): $($_.Exception.Message)"
            }
        }
    }
}

Start-Sleep -Seconds 2

# --- Remove startup shortcuts per-user
foreach ($root in (Get-UserProfileRoots)) {
    $glob = 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\*.lnk'
    $probe = Join-Path -Path $root.FullName -ChildPath $glob
    foreach ($hit in (Resolve-Path $probe -ErrorAction SilentlyContinue)) {
        $meta = Get-ShortcutMeta -Path $hit.Path
        $target = if ($meta -and $meta.TargetPath) { $meta.TargetPath } else { '' }
        $lnkArgs = if ($meta -and $meta.Arguments) { $meta.Arguments } else { '' }
        $text = "$($hit.Path) $target $lnkArgs"

        if (Test-OneStartMatch -Text $text) {
            if ($PSCmdlet.ShouldProcess($hit.Path, 'Remove-Item -Force')) {
                try {
                    Remove-Item -Path $hit.Path -Force -ErrorAction Stop
                    Write-Log "Removed startup shortcut $($hit.Path)"
                }
                catch {
                    Write-Log "Failed to remove shortcut $($hit.Path): $($_.Exception.Message)"
                }
            }
        }
    }
}

# --- Remove HKU software keys and Run values
foreach ($hku in (Get-HkuHives)) {
    $base = "Registry::$($hku.PSChildName)"

    foreach ($rel in $RegProductKeysRel) {
        $key = Join-Path $base $rel
        if (Test-Path $key) {
            if ($PSCmdlet.ShouldProcess($key, 'Remove-Item -Recurse -Force')) {
                try {
                    Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
                    Write-Log "Removed registry key $key"
                } catch {
                    Write-Log ("Failed to remove key {0}: {1}" -f $key, $_.Exception.Message)
                }
            }
        }
    }

    $runKey = Join-Path $base 'Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path $runKey) {
        foreach ($name in $RunValueNames) {
            if (Get-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue) {
                # Use braced variables to avoid :: parsing issues
                if ($PSCmdlet.ShouldProcess("$($runKey)::$($name)", 'Remove-ItemProperty')) {
                    try {
                        Remove-ItemProperty -Path $runKey -Name $name -ErrorAction Stop
                        Write-Log "Removed Run value $name from $runKey"
                    } catch {
                        Write-Log "Failed to remove Run value $name from $($runKey): $($_.Exception.Message)"
                    }
                }
            }
        }
    }
}

# --- Helper to remove scheduled tasks safely (supports WhatIf)
function Remove-TaskSafe {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [Microsoft.Management.Infrastructure.CimInstance]$Task
    )
    $tn = $Task.TaskName
    $tp = $Task.TaskPath

    if ($PSCmdlet.ShouldProcess("$tp$tn", 'Unregister-ScheduledTask')) {
        try {
            Unregister-ScheduledTask -TaskName $tn -TaskPath $tp -Confirm:$false -ErrorAction Stop
            Write-Log "Unregistered scheduled task: $tp$tn"
            return
        }
        catch {
            Write-Log "Unregister-ScheduledTask failed for $tp$($tn): $($_.Exception.Message)"
        }
    }

    try {
        $full = "$tp$tn"
        Start-Process -FilePath schtasks.exe -ArgumentList @('/Delete', '/TN', $full, '/F') -NoNewWindow -Wait
        Write-Log "schtasks.exe deleted: $full"
        return
    }
    catch {
        Write-Log "schtasks.exe delete failed for $tp$($tn): $($_.Exception.Message)"
    }

    try {
        $tasksRoot = Join-Path $env:SystemRoot 'System32\Tasks'
        $taskFile = $tp.TrimStart('\').TrimEnd('\')
        if ($taskFile) {
            $taskFile = Join-Path $tasksRoot $taskFile
        }
        else {
            $taskFile = $tasksRoot
        }
        $taskFile = Join-Path $taskFile $tn
        if (Test-Path $taskFile) {
            if ($PSCmdlet.ShouldProcess($taskFile, 'Remove-Item')) {
                Remove-Item -Path $taskFile -Force -ErrorAction Stop
                Write-Log "Removed task file: $taskFile"
            }
        }
    }
    catch {
        Write-Log "Failed to remove task file for $tp$($tn): $($_.Exception.Message)"
    }
}

# --- Remove known-named tasks using Remove-TaskSafe (handles TaskPath)
$allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue
if ($allTasks) {
    foreach ($known in $ScheduledTaskNames) {
        foreach ($t in ($allTasks | Where-Object { $_.TaskName -eq $known })) {
            Remove-TaskSafe -Task $t
        }
    }
}

# --- Aggressive pattern-based removal (optional)
if ($Aggressive -and $allTasks) {
    foreach ($pat in $ScheduledTaskPatterns) {
        foreach ($t in ($allTasks | Where-Object { $_.TaskName -like $pat -or $_.TaskPath -like $pat })) {
            Remove-TaskSafe -Task $t
        }
    }
}

# --- Always do a final sweep for brand markers (covers TaskPath cases)
if (-not $allTasks) { $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue }
if ($allTasks) {
    $match = $allTasks | Where-Object {
        $_.TaskName -match '(?i)OneStart' -or $_.TaskPath -match '(?i)OneStart' -or $_.TaskName -match '(?i)DBar'
    }
    foreach ($t in $match) { Remove-TaskSafe -Task $t }
}

# --- Remove per-user folders
foreach ($root in (Get-UserProfileRoots)) {
    $folders = @(
        (Join-Path -Path $root.FullName -ChildPath 'AppData\Roaming\OneStart'),
        (Join-Path -Path $root.FullName -ChildPath 'AppData\Local\OneStart.ai'),
        (Join-Path -Path $root.FullName -ChildPath 'AppData\Local\OneStart')
    )

    foreach ($f in $folders) {
        if ($null -ne $f -and (Test-Path $f)) {
            if ($PSCmdlet.ShouldProcess($f, 'Remove-Item -Recurse -Force')) {
                try {
                    Remove-Item -Path $f -Recurse -Force -ErrorAction Stop
                    Write-Log "Deleted folder $f"
                }
                catch {
                    Write-Log "Failed to delete folder $($f): $($_.Exception.Message)"
                }
            }
        }
    }
}

Write-Log 'Remediation completed.'
