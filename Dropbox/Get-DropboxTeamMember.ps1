<#PSScriptInfo
.VERSION 1.0.0
.GUID 7f64782b-37be-46e7-b66b-4a4c4c318021
.AUTHOR Giovanni Solone
.TAGS powershell dropbox dropboxbusiness team members memberid dbmid
.LICENSEURI https://opensource.org/licenses/MIT
.PROJECTURI https://github.com/gioxx/Nebula.Scripts/blob/main/Dropbox/Get-DropboxTeamMember.ps1
#>

#Requires -Version 7.0

<#
.SYNOPSIS
Retrieves Dropbox Business team members and their team member IDs (dbmid).

.DESCRIPTION
This script searches Dropbox Business team members by e-mail address or display name, or lists all members.
It follows pagination automatically using the Dropbox Team API and returns one object per member
(Name, Email, MemberID, Status), so the output can be piped to other commands.
Requires a Dropbox team-scoped access token with the members.read permission.
No external modules are required.

.PARAMETER Email
Exact e-mail address of a team member (case-insensitive).

.PARAMETER Name
Partial display name to search (case-insensitive).

.PARAMETER All
Returns every member of the team.

.PARAMETER AccessToken
Dropbox team access token as a SecureString. If omitted, the script prompts for it securely.

.EXAMPLE
.\Get-DropboxTeamMember.ps1 -Email 'alice@contoso.com'
Returns the team member with the given e-mail address.

.EXAMPLE
.\Get-DropboxTeamMember.ps1 -Name 'Alice'
Returns all team members whose display name contains "Alice".

.EXAMPLE
$token = Read-Host 'Dropbox team access token' -AsSecureString
.\Get-DropboxTeamMember.ps1 -All -AccessToken $token
Lists every team member, reusing a token already stored in a SecureString.

.EXAMPLE
.\Get-DropboxTeamMember.ps1 -Email 'alice@contoso.com' | Select-Object -ExpandProperty MemberID
Returns only the team member ID (dbmid:...) of the given user.

.NOTES
Dropbox API reference: https://www.dropbox.com/developers/documentation/http/teams

Modification History:
v1.0.0 (2026-10-09): Initial release.
#>

[CmdletBinding(DefaultParameterSetName = 'Email')]
param (
    [Parameter(Mandatory = $true, ParameterSetName = 'Email')]
    [ValidateNotNullOrEmpty()]
    [string] $Email,

    [Parameter(Mandatory = $true, ParameterSetName = 'Name')]
    [ValidateNotNullOrEmpty()]
    [string] $Name,

    [Parameter(Mandatory = $true, ParameterSetName = 'All')]
    [switch] $All,

    [Parameter()]
    [ValidateNotNull()]
    [securestring] $AccessToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('AccessToken')) {
    $AccessToken = Read-Host 'Dropbox team access token' -AsSecureString
}

# Convert the secret only for the HTTP Authorization header; never log it.
$plainToken = [System.Net.NetworkCredential]::new('', $AccessToken).Password
if ([string]::IsNullOrWhiteSpace($plainToken)) {
    throw 'The Dropbox access token must not be empty.'
}

$headers = @{
    Authorization  = "Bearer $plainToken"
    'Content-Type' = 'application/json'
}
$plainToken = $null

function Invoke-DropboxTeamApi {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Endpoint,

        [Parameter(Mandatory = $true)]
        [object] $Payload
    )

    $uri = "https://api.dropboxapi.com/2/$Endpoint"
    try {
        Invoke-RestMethod -Method Post -Uri $uri -Headers $headers `
            -Body ($Payload | ConvertTo-Json -Depth 8 -Compress) -ErrorAction Stop
    }
    catch {
        $statusCode = $null
        if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        # Dropbox returns a JSON body with an error_summary field on API errors.
        $apiError = $_.Exception.Message
        if ($_.ErrorDetails) {
            $apiError = $_.ErrorDetails.Message
            try {
                $errorBody = $apiError | ConvertFrom-Json -ErrorAction Stop
                if ($errorBody.PSObject.Properties['error_summary']) { $apiError = $errorBody.error_summary }
            }
            catch {
                # Not JSON (e.g. plain-text 400 response): keep the raw message.
            }
        }

        $hint = switch ($statusCode) {
            401 { 'Check whether the access token is valid and not expired.' }
            403 { 'Check that the app is team-scoped and has the members.read permission.' }
            429 { 'Dropbox rate limit reached. Retry after the indicated delay.' }
            default { 'Check the Dropbox API response and network connectivity.' }
        }
        throw "Dropbox API request failed (HTTP $statusCode) at $Endpoint. $hint $apiError"
    }
}

try {
    $page = Invoke-DropboxTeamApi -Endpoint 'team/members/list' -Payload @{ limit = 100 }
    while ($true) {
        foreach ($member in $page.members) {
            $memberProfile = $member.profile
            if ($null -eq $memberProfile) { continue }

            $displayName = [string]$memberProfile.name.display_name
            $memberEmail = [string]$memberProfile.email
            $isMatch = switch ($PSCmdlet.ParameterSetName) {
                'Email' { $memberEmail.Equals($Email, [System.StringComparison]::OrdinalIgnoreCase) }
                'Name' { $displayName.Contains($Name, [System.StringComparison]::OrdinalIgnoreCase) }
                'All' { $true }
            }

            if ($isMatch) {
                [PSCustomObject]@{
                    Name     = $displayName
                    Email    = $memberEmail
                    MemberID = [string]$memberProfile.team_member_id
                    Status   = [string]$memberProfile.status.'.tag'
                }

                # E-mail addresses are unique within a team: no need to read further pages.
                if ($PSCmdlet.ParameterSetName -eq 'Email') { return }
            }
        }

        if (-not $page.has_more) { break }
        if ([string]::IsNullOrWhiteSpace([string]$page.cursor)) {
            throw 'Dropbox reported additional pages but returned no cursor.'
        }
        $page = Invoke-DropboxTeamApi -Endpoint 'team/members/list/continue' `
            -Payload @{ cursor = $page.cursor }
    }
}
finally {
    # Clear local references; the runtime controls actual memory lifetime.
    # Remove-Variable instead of assigning $null: [ValidateNotNull()] still applies to the parameter variable.
    $headers.Remove('Authorization')
    Remove-Variable -Name AccessToken -ErrorAction SilentlyContinue
}
