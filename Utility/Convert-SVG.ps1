<#PSScriptInfo
.VERSION 1.0.0
.GUID b51d2447-b40d-47de-8ca5-8583db061ba4
.AUTHOR Giovanni Solone
.TAGS powershell inkscape images conversion svg png jpg
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/gioxx/Nebula.Scripts/Utility/Convert-SVG.ps1
#>

#Requires -Version 7.0

<#
.SYNOPSIS
Converts SVG files to PNG or JPG format using Inkscape.

.DESCRIPTION
This script converts SVG files to PNG or JPG format using Inkscape.
PNG format preserves transparency, while JPG format does not support transparency 
but may result in smaller file sizes with white background.

Requires Inkscape to be installed on the system.
Download from: https://inkscape.org/release/

.PARAMETER InputFile
The path to the SVG file to be converted. Must be a valid SVG file.

.PARAMETER OutputFormat  
The output format for conversion. Valid values are 'PNG' and 'JPG'. Default is 'PNG'.

.PARAMETER InkscapePath
The path to the Inkscape executable. Defaults to standard installation path.

.PARAMETER Width
The width of the output image in pixels. Default is 240.

.PARAMETER Height
The height of the output image in pixels. Default is 240.

.PARAMETER OutputFile
Optional custom output file path. If not specified, uses input filename with new extension.

.EXAMPLE
.\Convert-SVG.ps1 -InputFile "C:\path\to\image.svg"
Converts the SVG file to PNG using default settings.

.EXAMPLE  
.\Convert-SVG.ps1 -InputFile "C:\path\to\image.svg" -OutputFormat JPG
Converts the SVG file to JPG format (loses transparency).

.EXAMPLE
.\Convert-SVG.ps1 -InputFile "C:\path\to\image.svg" -Width 512 -Height 512
Converts with custom dimensions (512x512 pixels).

.EXAMPLE
.\Convert-SVG.ps1 -InputFile "image.svg" -OutputFile "custom-output.png" -InkscapePath "D:\Tools\inkscape.exe"
Converts using custom output path and Inkscape location.

.NOTES
Ensure Inkscape is installed on your system for this script to work.
Download Inkscape from: https://inkscape.org/release/

For JPG conversion, transparency is replaced with white background.
PNG format is recommended when transparency preservation is needed.

Known Issue: Inkscape may return exit code 1 even on successful conversions.
This script checks for actual file creation to determine success.

Modification History:
v1.0.0 (2024-10-02): Initial release.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
    [ValidateScript({
        if (-not (Test-Path $_ -PathType Leaf)) {
            throw "File not found: $_"
        }
        if ([System.IO.Path]::GetExtension($_) -ne '.svg') {
            throw "File must have .svg extension: $_"
        }
        return $true
    })]
    [string]$InputFile,
    [Parameter()]
    [ValidateSet('PNG', 'JPG')]
    [string]$OutputFormat = 'PNG',
    [Parameter()]
    [string]$InkscapePath = "$env:ProgramFiles\Inkscape\bin\inkscape.exe",
    [Parameter()]
    [ValidateRange(1, 8192)]
    [int]$Width = 240,
    [Parameter()]
    [ValidateRange(1, 8192)] 
    [int]$Height = 240,
    [Parameter()]
    [string]$OutputFile
)

try {
    # Check if Inkscape exists
    if (-not (Test-Path $InkscapePath)) {
        Write-Error "❌ Inkscape not found at: $InkscapePath"
        Write-Host "Please install Inkscape from: https://inkscape.org/release/" -ForegroundColor Yellow
        exit 1
    }

    # Resolve input file path
    $InputFile = Resolve-Path $InputFile -ErrorAction Stop
    Write-Verbose "Processing file: $InputFile"

    # Determine output file
    if (-not $OutputFile) {
        $extension = if ($OutputFormat -eq 'JPG') { '.jpg' } else { '.png' }
        $OutputFile = [System.IO.Path]::ChangeExtension($InputFile, $extension)
    }

    Write-Verbose "Output will be: $OutputFile"

    # Remove existing output file
    if (Test-Path $OutputFile) {
        Remove-Item $OutputFile -Force
        Write-Host "Removed existing output file"
    }

    # Prepare Inkscape arguments
    $inkscapeArgs = @(
        "--export-type=$($OutputFormat.ToLower())"
        "--export-filename=$OutputFile"
        "-w", $Width
        "-h", $Height
    )

    # Add white background for JPG (removes transparency)
    if ($OutputFormat -eq 'JPG') {
        $inkscapeArgs += '--export-background=white'
        $inkscapeArgs += '--export-background-opacity=1'
        Write-Verbose "JPG format: Adding white background to remove transparency"
    }

    $inkscapeArgs += $InputFile

    Write-Verbose "Executing: `"$InkscapePath`" $($inkscapeArgs -join ' ')"
    & "$InkscapePath" $inkscapeArgs 2>$null

    # Inkscape often returns exit code 1 even on success, so we check file creation instead
    Start-Sleep -Milliseconds 1500  # Brief pause to ensure file system operations complete

    if (Test-Path $OutputFile) {
        $outputInfo = Get-Item $OutputFile
        Write-Host "✅ Successfully converted to $OutputFormat`: $($outputInfo.FullName)" -ForegroundColor Green
        Write-Host "   File size: $([math]::Round($outputInfo.Length / 1KB, 2)) KB" -ForegroundColor Gray
        
        # Return output file path for further processing
        return $outputInfo.FullName
    } else {
        throw "Conversion failed: output file not created: $OutputFile"
    }
} catch {
    Write-Error "❌ Error converting SVG to $OutputFormat`: $($_.Exception.Message)"
    exit 1
}