<#PSScriptInfo
.VERSION 1.2.0
.GUID b51d2447-b40d-47de-8ca5-8583db061ba4
.AUTHOR Giovanni Solone
.TAGS powershell inkscape images conversion svg png jpg
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/gioxx/Nebula.Scripts/blob/main/Utility/Convert-SVG.ps1
#>

#Requires -Version 7.0

<#
.SYNOPSIS
Converts SVG files to PNG or JPG format, or PNG/JPG files to SVG format, using Inkscape or built-in .NET APIs.

.DESCRIPTION
This script converts SVG files to PNG or JPG format using Inkscape.
PNG format preserves transparency, while JPG format does not support transparency
but may result in smaller file sizes with white background.

It also supports the reverse conversion: PNG or JPG to SVG.
For PNG-to-SVG conversion, the PNG is embedded as base64 inside the SVG container,
preserving the original image pixel-perfectly (including transparency for PNG files).
This conversion uses built-in .NET APIs (no external dependencies required),
with Inkscape as fallback.

Requires Inkscape to be installed on the system (for SVG-to-raster export).
Download from: https://inkscape.org/release/

.PARAMETER InputFile
The path to the input file to be converted. Must be a valid SVG, PNG, or JPG file.

.PARAMETER OutputFormat
The output format for conversion. Valid values are 'PNG', 'JPG', and 'SVG'. Default is 'PNG'.
When InputFile is an SVG, valid targets are PNG and JPG.
When InputFile is a PNG or JPG, the only valid target is SVG.

.PARAMETER InkscapePath
The path to the Inkscape executable. If omitted, the script searches common install paths and PATH.

.PARAMETER Width
The width of the output image in pixels (only used when converting SVG to PNG/JPG). Default is 240.

.PARAMETER Height
The height of the output image in pixels (only used when converting SVG to PNG/JPG). Default is 240.

.PARAMETER OutputFile
Optional custom output file path. If not specified, uses input filename with new extension.

.PARAMETER PreferInkscapeRasterToSvg
When converting PNG/JPG to SVG, try Inkscape first instead of the built-in .NET wrapper approach.
This is useful if you want to keep the whole conversion flow inside Inkscape.

.EXAMPLE
.\Convert-SVG.ps1 -InputFile "C:\path\to\image.svg"
Converts the SVG file to PNG using default settings.

.EXAMPLE
.\Convert-SVG.ps1 -InputFile "C:\path\to\image.svg" -OutputFormat JPG
Converts the SVG file to JPG format (loses transparency).

.EXAMPLE
.\Convert-SVG.ps1 -InputFile "C:\path\to\image.svg" -Width 512 -Height 512
Converts SVG to PNG with custom dimensions (512x512 pixels).

.EXAMPLE
.\Convert-SVG.ps1 -InputFile "C:\path\to\image.png" -OutputFormat SVG
Converts a PNG to SVG with the image embedded as base64 (transparency preserved).

.EXAMPLE
.\Convert-SVG.ps1 -InputFile "image.svg" -OutputFile "custom-output.png" -InkscapePath "D:\Tools\inkscape.exe"
Converts using custom output path and Inkscape location.

.EXAMPLE
.\Convert-SVG.ps1 -InputFile "image.png" -OutputFormat SVG -PreferInkscapeRasterToSvg
Uses Inkscape first for the PNG-to-SVG conversion instead of the embedded-base64 .NET path.

.NOTES
Ensure Inkscape is installed on your system for SVG-to-raster conversions.
Download Inkscape from: https://inkscape.org/release/

For JPG conversion, transparency is replaced with white background.
PNG format is recommended when transparency preservation is needed.

For PNG/JPG-to-SVG conversion, the raster image is embedded as base64 inside the SVG.
This is not a vector tracing — the image remains pixel-based but is scalable as an SVG container.
No external dependencies are required: conversion uses built-in .NET System.Drawing APIs.

Known Issue: Inkscape may return exit code 1 even on successful conversions.
This script checks for actual file creation to determine success.

Modification History:
v1.2.0 (2026-06-11): Added PNG/JPG to SVG conversion support and a dynamic Inkscape path resolver, with optional Inkscape-first raster handling.
v1.0.1 (2026-03-26): Fixed PROJECTURI in the script metadata to point to the correct GitHub repository and file.
v1.0.0 (2024-10-02): Initial release.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
    [ValidateScript({
            if (-not (Test-Path $_ -PathType Leaf)) {
                throw "File not found: $_"
            }
            $ext = [System.IO.Path]::GetExtension($_).ToLower()
            if ($ext -notin @('.svg', '.png', '.jpg', '.jpeg')) {
                throw "File must be SVG, PNG, or JPG: $_"
            }
            return $true
        })]
    [string]$InputFile,
    [Parameter()]
    [ValidateSet('PNG', 'JPG', 'SVG')]
    [string]$OutputFormat = 'PNG',
    [Parameter()]
    [string]$InkscapePath,
    [Parameter()]
    [ValidateRange(1, 8192)]
    [int]$Width = 240,
    [Parameter()]
    [ValidateRange(1, 8192)]
    [int]$Height = 240,
    [Parameter()]
    [string]$OutputFile
    ,
    [Parameter()]
    [switch]$PreferInkscapeRasterToSvg
)

# ---------------------------------------------------------------------------
# Helper: convert raster (PNG/JPG) to SVG by embedding as base64
# Uses built-in .NET APIs only — no Python or external tools required.
# ---------------------------------------------------------------------------
function Convert-RasterToSvg {
    param(
        [string]$InputPath,
        [string]$Output,
        [switch]$PreferInkscapeRasterToSvg,
        [string]$ResolvedInkscapePath
    )

    try {
        if ($PreferInkscapeRasterToSvg -and $ResolvedInkscapePath) {
            Write-Verbose "Trying Inkscape first for raster-to-SVG..."
            $inkscapeArgs = @(
                $InputPath
                "--export-type=svg"
                "--export-filename=$Output"
            )
            & "$ResolvedInkscapePath" $inkscapeArgs 2>$null
            Start-Sleep -Milliseconds 1500
            if (Test-Path -LiteralPath $Output) {
                Write-Verbose "Inkscape conversion succeeded."
                return $true
            }
            Write-Verbose "Inkscape did not create the output; falling back to .NET wrapper."
        }

        # Read image dimensions via System.Drawing
        Add-Type -AssemblyName System.Drawing
        $img = [System.Drawing.Image]::FromFile($InputPath)
        $w = $img.Width
        $h = $img.Height
        $img.Dispose()

        # Detect MIME type from extension
        $ext = [System.IO.Path]::GetExtension($InputPath).ToLower()
        $mime = if ($ext -in @('.jpg', '.jpeg')) { 'image/jpeg' } else { 'image/png' }

        # Encode file as base64
        $bytes = [System.IO.File]::ReadAllBytes($InputPath)
        $base64 = [System.Convert]::ToBase64String($bytes)

        # Build SVG
        $svg = @"
<svg xmlns="http://www.w3.org/2000/svg"
     xmlns:xlink="http://www.w3.org/1999/xlink"
     width="$w" height="$h"
     viewBox="0 0 $w $h">
  <image width="$w" height="$h"
         href="data:$mime;base64,$base64"/>
</svg>
"@
        [System.IO.File]::WriteAllText($Output, $svg, [System.Text.Encoding]::UTF8)
        Write-Verbose ".NET conversion succeeded: ${w}x${h}"
        return $true

    }
    catch {
        Write-Warning ".NET conversion failed: $($_.Exception.Message)"

        # Fallback: Inkscape
        if ($ResolvedInkscapePath) {
            Write-Verbose "Trying Inkscape as fallback..."
            $inkscapeArgs = @(
                $InputPath
                "--export-type=svg"
                "--export-filename=$Output"
            )
            & "$ResolvedInkscapePath" $inkscapeArgs 2>$null
            Start-Sleep -Milliseconds 1500
            return (Test-Path $Output)
        }

        Write-Error "Conversion failed and Inkscape fallback is not available."
        return $false
    }
}

function Resolve-InkscapePath {
    param(
        [string]$ExplicitPath
    )

    $candidatePaths = @()

    if ($ExplicitPath) {
        $candidatePaths += $ExplicitPath
    }

    if ($env:ProgramFiles) {
        $candidatePaths += (Join-Path -Path $env:ProgramFiles -ChildPath 'Inkscape\bin\inkscape.exe')
    }

    if (${env:ProgramFiles(x86)}) {
        $candidatePaths += (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'Inkscape\bin\inkscape.exe')
    }

    foreach ($path in $candidatePaths) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }

    $cmd = Get-Command inkscape.exe -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Source -First 1
    if (-not $cmd) {
        $cmd = Get-Command inkscape -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Source -First 1
    }

    if ($cmd) {
        return $cmd
    }

    return $null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    $InputFile = (Resolve-Path -LiteralPath $InputFile -ErrorAction Stop).Path
    $ResolvedInkscapePath = Resolve-InkscapePath -ExplicitPath $InkscapePath
    $inputExt = [System.IO.Path]::GetExtension($InputFile).ToLower()
    $isRaster = $inputExt -in @('.png', '.jpg', '.jpeg')

    # Validate direction
    if ($isRaster -and $OutputFormat -ne 'SVG') {
        throw "Raster input ($inputExt) can only be converted to SVG. Use -OutputFormat SVG."
    }
    if (-not $isRaster -and $OutputFormat -eq 'SVG') {
        throw "SVG-to-SVG conversion is not supported. Use PNG or JPG as output format."
    }

    # Determine output path
    if (-not $OutputFile) {
        $extension = switch ($OutputFormat) {
            'JPG' { '.jpg' }
            'SVG' { '.svg' }
            default { '.png' }
        }
        $OutputFile = [System.IO.Path]::ChangeExtension($InputFile, $extension)
    }

    Write-Verbose "Input:  $InputFile"
    Write-Verbose "Output: $OutputFile"

    if (Test-Path $OutputFile) {
        Remove-Item $OutputFile -Force
        Write-Verbose "Removed existing output file"
    }

    # ---------------------------------------------------------------------------
    # Raster -> SVG
    # ---------------------------------------------------------------------------
    if ($isRaster) {
        Write-Host "Converting raster image to SVG (embedded base64)..." -ForegroundColor Cyan
        $ok = Convert-RasterToSvg -InputPath $InputFile -Output $OutputFile -PreferInkscapeRasterToSvg:$PreferInkscapeRasterToSvg -ResolvedInkscapePath $ResolvedInkscapePath
        if (-not $ok -or -not (Test-Path $OutputFile)) {
            throw "Conversion failed: output file not created: $OutputFile"
        }
    }
    # ---------------------------------------------------------------------------
    # SVG -> PNG / JPG  (original Inkscape path)
    # ---------------------------------------------------------------------------
    else {
        if (-not $ResolvedInkscapePath) {
            if ($InkscapePath) {
                Write-Error "Inkscape not found at: $InkscapePath"
            } else {
                Write-Error "Inkscape not found in common install paths or PATH."
            }
            Write-Host "Please install Inkscape from: https://inkscape.org/release/" -ForegroundColor Yellow
            exit 1
        }

        $inkscapeArgs = @(
            "--export-type=$($OutputFormat.ToLower())"
            "--export-filename=$OutputFile"
            "-w", $Width
            "-h", $Height
        )

        if ($OutputFormat -eq 'JPG') {
            $inkscapeArgs += '--export-background=white'
            $inkscapeArgs += '--export-background-opacity=1'
            Write-Verbose "JPG format: adding white background to remove transparency"
        }

        $inkscapeArgs += $InputFile
        Write-Verbose "Executing: `"$ResolvedInkscapePath`" $($inkscapeArgs -join ' ')"
        & "$ResolvedInkscapePath" $inkscapeArgs 2>$null

        # Inkscape often returns exit code 1 even on success
        Start-Sleep -Milliseconds 1500
    }

    # ---------------------------------------------------------------------------
    # Result
    # ---------------------------------------------------------------------------
    if (Test-Path $OutputFile) {
        $outputInfo = Get-Item $OutputFile
        Write-Host "✅ Successfully converted to $OutputFormat`: $($outputInfo.FullName)" -ForegroundColor Green
        Write-Host "   File size: $([math]::Round($outputInfo.Length / 1KB, 2)) KB" -ForegroundColor Gray
        return $outputInfo.FullName
    }
    else {
        throw "Conversion failed: output file not created: $OutputFile"
    }

}
catch {
    Write-Error "❌ Error during conversion: $($_.Exception.Message)"
    exit 1
}
