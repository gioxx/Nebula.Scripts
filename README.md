# Nebula.Scripts

🛰️ **Nebula.Scripts** is a collection of PowerShell scripts authored and maintained by [Gioxx](https://github.com/gioxx), designed to automate or simplify common administrative and development tasks. These scripts are individually published on the [PowerShell Gallery](https://www.powershellgallery.com/) for easy discovery and installation.

---

## 📦 Available Scripts

| Script Name            | Description                                                      | Gallery Link |
|------------------------|------------------------------------------------------------------|--------------|
| `Remove-OldPSModules`  | Removes all but the latest installed version of each PS module. | [View on PSGallery](https://www.powershellgallery.com/packages/Remove-OldPSModules) |

More scripts will be added over time.

---

## 🚀 Getting Started

You can install a script directly from the PowerShell Gallery:

```powershell
Install-Script -Name Remove-OldPSModules -Scope CurrentUser -Force
```

Then run it:

```powershell
Remove-OldPSModules.ps1
```

Make sure your [Execution Policy](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies) allows script execution.

---

### 🆕 Creating a new script for PowerShell Gallery

Use `New-ScriptFileInfo` to generate a script with the correct metadata header required by the Gallery:

```powershell
New-ScriptFileInfo `
  -Path .\MyScript.ps1 `
  -Version '1.0.0' `
  -Author 'Your Name' `
  -Description 'Describe what this script does.' `
  -LicenseUri 'https://opensource.org/licenses/MIT' `
  -ProjectUri 'hhttps://github.com/<your-repo>' `
  -Tags 'powershell', 'scripts', 'utilities'
```

This will create a `.ps1` file pre-filled with a `#PSScriptInfo` header block. After that, you should manually add:

```powershell
# Requires -Version 7.0

<#
.SYNOPSIS
Brief summary of what the script does.
.DESCRIPTION
More detailed explanation of its purpose and usage.
.EXAMPLE
.\MyScript.ps1
Demonstrates typical usage.
#>
```

📝 Make sure to avoid having both a `.DESCRIPTION` in `#PSScriptInfo` **and** in the help block at the same time, or you'll get a publishing error.


## 📦 PowerShell Gallery - Publishing Reference

### Requirements

- PowerShell 7.0 or later
- PowerShellGet v3+ (`Install-Module PowerShellGet -Force`)
- Valid [NuGet API key](https://www.powershellgallery.com/account/apikeys)

### ✅ Publishing a Script

Ensure your script includes a valid `.PSScriptInfo` block and comment-based help:

```powershell
<#PSScriptInfo
.VERSION 1.0.0
.GUID <your-guid-here>
.AUTHOR Your Name
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/<your-repo>
.TAGS powershell scripts utilities
#>

# Requires -Version 7.0

<#
.SYNOPSIS
One-line summary.
.DESCRIPTION
Detailed explanation of what the script does.
.EXAMPLE
.\YourScript.ps1
Runs the script.
#>
```

Then run:

```powershell
Publish-PSResource -Path .\YourScript.ps1 -Repository PSGallery -ApiKey '<your-api-key>' -Verbose
```

---

## 📄 License

All scripts in this repository are licensed under the [MIT License](https://opensource.org/licenses/MIT).

---

## 📬 Feedback and Contributions

Feedback, suggestions, and pull requests are welcome!  
Feel free to [open an issue](https://github.com/gioxx/Nebula.Scripts/issues) or contribute directly.