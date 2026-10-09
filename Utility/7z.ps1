# Work in Progress, not yet ready for general use. Use with caution and test on non-critical data first.
# This is an evolution of my older 7z.cmd script (https://gioxx.org/2020/02/17/7-zip-compattare-piu-cartelle-con-un-doppio-clic/), rewritten from scratch with better structure, error handling, and performance optimizations.

#Requires -Version 5.1

<#
.SYNOPSIS
Compresses every subfolder of a source folder into its own .7z archive.

.DESCRIPTION
For each first-level subfolder of Source, this script creates <FolderName>.7z in Destination using 7-Zip
with maximum compression (-mx=9). Archives are written to a .tmp file first and renamed only on success,
so an interrupted run never leaves a truncated archive behind. Existing archives are skipped.
7-Zip warnings (exit code 1, e.g. files locked by another process) keep the archive and are reported.

.PARAMETER Source
Folder whose subfolders will be compressed. Defaults to the current folder.

.PARAMETER Destination
Folder where the archives are created. Created if missing. Defaults to the current folder.

.PARAMETER ExcludeDirs
Names of subfolders to skip (case-insensitive).

.PARAMETER Show7zOutput
Shows the 7-Zip console output instead of hiding it.

.EXAMPLE
.\7z.ps1 -Source 'D:\Projects' -Destination 'E:\Backup'
Creates one .7z archive in E:\Backup for every subfolder of D:\Projects.

.EXAMPLE
.\7z.ps1 -ExcludeDirs 'node_modules', '.git' -Show7zOutput
Compresses the subfolders of the current folder, skipping node_modules and .git, and shows 7-Zip output.

.NOTES
Modification History:
2026-10-09: Added comment-based help. 7-Zip exit code 1 (warnings) is no longer treated as a failure. Fixed 7z.exe lookup when ProgramFiles(x86) is not defined.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$Source = (Get-Location).Path,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$Destination = (Get-Location).Path,

  [Parameter(Mandatory = $false)]
  [string[]]$ExcludeDirs = @(),

  [Parameter(Mandatory = $false)]
  [switch]$Show7zOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-SevenZipPath {
  # ProgramFiles(x86) is not defined on 32-bit Windows: Join-Path would fail on a null path.
  $candidates = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
  Where-Object { $_ } |
  ForEach-Object { Join-Path $_ '7-Zip\7z.exe' }

  foreach ($path in $candidates) {
    if ($path -and (Test-Path -LiteralPath $path)) {
      return $path
    }
  }

  $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty Source -First 1
  if ($cmd) { return $cmd }

  throw "7z.exe not found. Install 7-Zip or add it to PATH."
}

function Get-FolderStats {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $fileCount = 0
  $totalBytes = [int64]0

  # Stream enumeration: avoids any .Count/.Sum pitfalls and is memory-friendly.
  Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $fileCount++
    $totalBytes += [int64]$_.Length
  }

  return [pscustomobject]@{
    FileCount  = $fileCount
    TotalBytes = $totalBytes
  }
}

$SevenZip = Resolve-SevenZipPath

# Resolve Source path
$Source = (Resolve-Path -LiteralPath $Source).Path

# Ensure Destination exists and resolve it
try {
  if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
    Write-Host "Destination folder does not exist. Creating: $Destination"
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  }
  $Destination = (Resolve-Path -LiteralPath $Destination).Path
}
catch {
  throw "Failed to validate or create destination folder: $Destination. $($_.Exception.Message)"
}

# Exclusions -> case-insensitive HashSet
$excludeSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($d in $ExcludeDirs) {
  if (-not [string]::IsNullOrWhiteSpace($d)) {
    [void]$excludeSet.Add($d.Trim())
  }
}

Write-Host "7-Zip       : $SevenZip"
Write-Host "Source      : $Source"
Write-Host "Destination : $Destination"
Write-Host "ExcludeDirs : " -NoNewline
if ($excludeSet.Count -gt 0) { Write-Host ($ExcludeDirs -join ', ') } else { Write-Host "(none)" }
Write-Host ""

# Build folder list (use a real List to keep behavior stable)
$folderList = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
Get-ChildItem -LiteralPath $Source -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
  if ($_ -and -not $excludeSet.Contains($_.Name)) {
    [void]$folderList.Add($_)
  }
}

$total = $folderList.Count
if ($total -eq 0) {
  Write-Host "Nothing to do. No folders found (or all excluded)."
  return
}

$done = 0

foreach ($folder in $folderList) {
  $done++

  $folderName = $folder.Name
  $archivePath = Join-Path $Destination "$folderName.7z"
  $tempArchivePath = "$archivePath.tmp"

  $percent = [int](($done / [double]$total) * 100)
  Write-Progress -Activity "Compressing folders" `
    -Status "[$done/$total] $folderName" `
    -PercentComplete $percent

  # Clean leftover temp file from previous interrupted run
  if (Test-Path -LiteralPath $tempArchivePath) {
    Write-Host "[CLEAN] Removing incomplete archive: $(Split-Path -Leaf $tempArchivePath)"
    Remove-Item -LiteralPath $tempArchivePath -Force -ErrorAction SilentlyContinue
  }

  # Skip if final archive already exists
  if (Test-Path -LiteralPath $archivePath) {
    Write-Host "[SKIP] $folderName -> already exists"
    continue
  }

  # --- Scan folder statistics ---
  Write-Host "[SCAN] Analyzing $folderName ..."
  $stats = Get-FolderStats -Path $folder.FullName

  $fileCount = [int]$stats.FileCount
  $totalBytes = [int64]$stats.TotalBytes

  $sizeMB = [math]::Round($totalBytes / 1MB, 2)
  $sizeGB = [math]::Round($totalBytes / 1GB, 2)
  $sizeString = if ($sizeGB -ge 1) { "$sizeGB GB" } else { "$sizeMB MB" }

  Write-Host "[INFO] $folderName contains $fileCount files - $sizeString"
  Write-Host "[ZIP ] $folderName -> $(Split-Path -Leaf $archivePath)"

  Push-Location $folder.FullName
  try {
    [string[]]$sevenZipArgs = @('a', '-t7z', '-mx=9', $tempArchivePath, '*')

    $elapsed = Measure-Command {
      if ($Show7zOutput) {
        & $SevenZip @sevenZipArgs
      }
      else {
        & $SevenZip @sevenZipArgs | Out-Null
      }
    }

    # 7-Zip exit codes: 0 = success, 1 = warning (e.g. some files locked, archive still created), >= 2 = fatal error.
    if ($LASTEXITCODE -le 1 -and (Test-Path -LiteralPath $tempArchivePath)) {
      if ($LASTEXITCODE -eq 1) {
        Write-Warning "7-Zip reported warnings for $folderName (exit code 1): some files may be missing from the archive. Re-run with -Show7zOutput for details."
      }
      Move-Item -LiteralPath $tempArchivePath -Destination $archivePath -Force
    }
    else {
      Write-Warning "7-Zip failed for $folderName (exit code $LASTEXITCODE)"
      if (Test-Path -LiteralPath $tempArchivePath) {
        Remove-Item -LiteralPath $tempArchivePath -Force -ErrorAction SilentlyContinue
      }
    }
  }
  finally {
    Pop-Location
  }

  $seconds = [math]::Round($elapsed.TotalSeconds, 2)
  Write-Host "[DONE] $folderName compressed in $seconds sec"
  Write-Host ""
}

Write-Progress -Activity "Compressing folders" -Completed
Write-Host ""
Write-Host "Done. Processed $total folder(s)."
