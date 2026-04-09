<#PSScriptInfo
.VERSION 1.0.0
.GUID 8f0d4e0c-1d7f-4b9d-9f0b-5d4c4dce0a01
.AUTHOR Giovanni Solone
.TAGS powershell rclone password security decrypt
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/gioxx/Nebula.Scripts/blob/main/Security/Get-RclonePassword.ps1
#>

#Requires -Version 7.0

<#
.SYNOPSIS
Reveals a password stored in rclone's obscured Base64URL format.

.DESCRIPTION
This script decodes an rclone-obscured password value by reversing the Base64URL
encoding and applying the AES-CTR transform used by rclone.

.PARAMETER ObscuredText
The Base64URL-encoded obscured password value.

.EXAMPLE
.\Get-RclonePassword.ps1 -ObscuredText '...'
Reveals the plain text password.

.NOTES
This script is intended for recovering access to an rclone configuration value
when you already have authorization to inspect the obscured text.

Credits:
- https://forum.rclone.org/t/get-password-and-salt-from-config/14788
- https://forum.rclone.org/t/how-to-retrieve-a-crypt-password-from-a-config-file/20051
- https://go.dev/play/p/IcRYDip3PnE
#>

[CmdletBinding()]
param(
    [Parameter(
        Mandatory = $true,
        Position = 0,
        ValueFromPipeline = $true,
        ValueFromPipelineByPropertyName = $true,
        HelpMessage = "Provide the Base64URL-encoded obscured text."
    )]
    [Alias("Text", "CipherText", "InputText", "EncryptedText")]
    [ValidateNotNullOrEmpty()]
    [string]$ObscuredText
)

begin {
    Set-StrictMode -Version Latest

    # AES-256 key used by rclone to obscure the password value.
    [byte[]]$script:RcloneKey = @(
        0x9c, 0x93, 0x5b, 0x48, 0x73, 0x0a, 0x55, 0x4d,
        0x6b, 0xfd, 0x7c, 0x63, 0xc8, 0x86, 0xa9, 0x2b,
        0xd3, 0x90, 0x19, 0x8e, 0xb8, 0x12, 0x8a, 0xfb,
        0xf4, 0xde, 0x16, 0x2b, 0x8b, 0x95, 0xf6, 0x38
    )

    function ConvertFrom-Base64UrlRaw {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$InputString
        )

        $base64 = $InputString.Replace('-', '+').Replace('_', '/')

        switch ($base64.Length % 4) {
            0 { }
            2 { $base64 += '==' }
            3 { $base64 += '=' }
            1 { throw "Invalid Base64URL string length." }
        }

        [Convert]::FromBase64String($base64)
    }

    function Invoke-RcloneAesCtrTransform {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [byte[]]$InputBytes,

            [Parameter(Mandatory = $true)]
            [byte[]]$Key,

            [Parameter(Mandatory = $true)]
            [byte[]]$InitializationVector
        )

        if ($InitializationVector.Length -ne 16) {
            throw "InitializationVector must be 16 bytes long."
        }

        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Mode = [System.Security.Cryptography.CipherMode]::ECB
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::None
        $aes.Key = $Key

        $encryptor = $aes.CreateEncryptor()

        try {
            $output = New-Object byte[] $InputBytes.Length
            $counter = New-Object byte[] 16
            [Array]::Copy($InitializationVector, $counter, 16)

            $blockSize = 16
            $offset = 0

            while ($offset -lt $InputBytes.Length) {
                $keystreamBlock = New-Object byte[] 16
                [void]$encryptor.TransformBlock($counter, 0, 16, $keystreamBlock, 0)

                $remaining = $InputBytes.Length - $offset
                $chunkSize = [Math]::Min($blockSize, $remaining)

                for ($i = 0; $i -lt $chunkSize; $i++) {
                    $output[$offset + $i] = $InputBytes[$offset + $i] -bxor $keystreamBlock[$i]
                }

                # Increment the counter as a big-endian 128-bit integer.
                for ($j = 15; $j -ge 0; $j--) {
                    $counter[$j]++
                    if ($counter[$j] -ne 0) {
                        break
                    }
                }

                $offset += $chunkSize
            }

            return $output
        }
        finally {
            if ($null -ne $encryptor) {
                $encryptor.Dispose()
            }

            if ($null -ne $aes) {
                $aes.Dispose()
            }
        }
    }

    function Get-RclonePassword {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$Text
        )

        try {
            $ciphertext = ConvertFrom-Base64UrlRaw -InputString $Text
        }
        catch {
            throw "Base64 decode failed while revealing the password. $($_.Exception.Message)"
        }

        if ($ciphertext.Length -lt 16) {
            throw "Input is too short. The value does not contain a valid IV."
        }

        $iv = New-Object byte[] 16
        [Array]::Copy($ciphertext, 0, $iv, 0, 16)

        $bufferLength = $ciphertext.Length - 16
        $buffer = New-Object byte[] $bufferLength
        [Array]::Copy($ciphertext, 16, $buffer, 0, $bufferLength)

        try {
            $plainBytes = Invoke-RcloneAesCtrTransform -InputBytes $buffer -Key $script:RcloneKey -InitializationVector $iv
            [System.Text.Encoding]::UTF8.GetString($plainBytes)
        }
        catch {
            throw "Decrypt failed while revealing the password. $($_.Exception.Message)"
        }
    }
}

process {
    try {
        Get-RclonePassword -Text $ObscuredText
    }
    catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                "RevealFailed",
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $ObscuredText
            )
        )
    }
}
