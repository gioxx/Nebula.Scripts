# Work in Progress, not yet ready for general use. Use with caution and test on non-critical data first.
# This is an evolution of my older 7z.cmd script (https://gioxx.org/2020/02/17/7-zip-compattare-piu-cartelle-con-un-doppio-clic/), rewritten from scratch with better structure, error handling, and performance optimizations.

#requires -version 5.1
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
  $candidates = @(
    Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'
  )

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

    if ($LASTEXITCODE -eq 0) {
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
