#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
    Registers the Workoho internal PowerShell gallery (a private GitHub Packages NuGet feed) and stores a
    read:packages credential in a SecretManagement vault.

.DESCRIPTION
    Registers the Workoho internal PowerShell gallery for the current user and stores a read credential in
    a SecretManagement vault, so Find-PSResource / Install-PSResource work without passing -Credential on
    every call.

    This is the central copy in the public workoho/setup repo - the single source of truth referenced by
    every Workoho module repo and by the one-liners in the examples below. It is self-contained and has no
    dependency on any particular repository's contents.

    The read token is resolved in this order, first hit wins:
      1. -Token
      2. $env:WORKOHO_PACKAGES_READ_TOKEN   (host env var / Codespaces secret; wired in devcontainer.json)
      3. a credential already stored in the target vault (reuse a previous run's token)
      4. an interactive prompt (only on a real terminal, or with -Interactive)

    The token must be a classic PAT with read:packages; the GitHub NuGet registry does not accept
    fine-grained tokens.

    On Windows with OneDrive "Known Folder Move" enabled, the per-user module folder (Documents) is
    redirected into OneDrive, so a CurrentUser module install gets uploaded and synced. The script only
    installs modules for its own vault dependencies, and refuses to do so silently there: it stops (exit
    4) and asks you to choose -Scope AllUsers (elevated) or an explicit -Scope CurrentUser. This only ever
    gates the module install; the repository registration and the SecretStore vault live under
    %LOCALAPPDATA% and are never affected by OneDrive.

.PARAMETER Token
    Classic read:packages PAT. Defaults to $env:WORKOHO_PACKAGES_READ_TOKEN. If omitted it is resolved
    from the vault or an interactive prompt (see the resolution order above).

.PARAMETER Username
    GitHub username stored alongside the token in the PSCredential. Defaults to $env:WORKOHO_PACKAGES_USER,
    then to 'workoho'.

.PARAMETER RepositoryName
    Name the feed is registered under. Defaults to 'WorkohoInternalPSGallery'.

.PARAMETER Uri
    The GitHub Packages NuGet feed. Defaults to 'https://nuget.pkg.github.com/workoho/index.json'.

.PARAMETER Priority
    PSResourceGet repository priority; a lower number resolves first. Defaults to 20.

.PARAMETER VaultName
    SecretManagement vault that holds the credential. Defaults to 'WorkohoVault'.

.PARAMETER SecretName
    Secret name inside the vault. Defaults to 'WorkohoPackagesRead'.

.PARAMETER Scope
    Where the SecretManagement vault modules install: 'CurrentUser' (default) or 'AllUsers'. AllUsers
    writes to %ProgramFiles% and needs an elevated session on Windows. See the OneDrive note above.

.PARAMETER Interactive
    Force the token prompt even when stdin looks non-interactive (redirected, CI).

.PARAMETER Quiet
    Suppress all output; signal only via the exit code, letting the caller own the messaging.

.EXAMPLE
    & ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/workoho/setup/main/powershell/register-internal-gallery.ps1)))

    Run from any machine, no clone needed; prompts for a token. The download is compiled into a
    scriptblock and invoked rather than piped to iex, because Invoke-Expression is a common AMSI/antivirus
    trigger and the scriptblock form also forwards parameters.

.EXAMPLE
    & ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/workoho/setup/main/powershell/register-internal-gallery.ps1))) -Token ghp_xxx

    Same one-liner, non-interactive: -Token is forwarded to the scriptblock.

.EXAMPLE
    pwsh powershell/register-internal-gallery.ps1 -Scope AllUsers

    From a local checkout, installing the vault modules machine-wide (needs an elevated session on
    Windows) - recommended when OneDrive redirects your per-user module folder.

.NOTES
    Requires PowerShell 7.6+ / Core (matches the Workoho module manifests). #Requires enforces that when
    the file is run directly; the script also checks at runtime because the one-liner path
    ([scriptblock]::Create / Invoke-Expression) does not honor #Requires.

    Exit codes:
      0      success - feed registered or updated
      2      no read token found; nothing registered (non-fatal - a caller may treat it as a warning)
      3      unsupported runtime (older than PowerShell 7.6, or non-Core)
      4      needs a scope decision before installing the vault modules (OneDrive-redirected CurrentUser,
             or AllUsers without elevation)
      other  a real failure

.LINK
    https://github.com/workoho/setup/blob/main/powershell/register-internal-gallery.md

.LINK
    https://github.com/workoho/setup
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'The token arrives as a plain string from an env var/param and must become a SecureString for the PSCredential.')]
param(
    # Classic read:packages PAT; falls back to the env var, the vault, then a prompt (see .DESCRIPTION).
    [string] $Token = $env:WORKOHO_PACKAGES_READ_TOKEN,

    # GitHub username stored with the token; defaults below to 'workoho' when unset.
    [string] $Username = $env:WORKOHO_PACKAGES_USER,

    # Name the feed is registered under.
    [string] $RepositoryName = 'WorkohoInternalPSGallery',

    # The GitHub Packages NuGet feed URL.
    [string] $Uri = 'https://nuget.pkg.github.com/workoho/index.json',

    # Repository priority; lower resolves first.
    [int] $Priority = 20,

    # SecretManagement vault that holds the credential.
    [string] $VaultName = 'WorkohoVault',

    # Secret name inside the vault.
    [string] $SecretName = 'WorkohoPackagesRead',

    # Where the vault modules install; AllUsers needs elevation. See the OneDrive note in .DESCRIPTION.
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string] $Scope = 'CurrentUser',

    # Force the token prompt even when stdin looks non-interactive.
    [switch] $Interactive,

    # Suppress all output; signal only via the exit code.
    [switch] $Quiet
)

# --- 0. Enforce the PowerShell 7.6+ (Core) runtime before anything else ----------------------------
# The Workoho modules and the PSResourceGet stack this uses are PowerShell 7.6+ / Core only (matches the
# module manifest's PowerShellVersion + CompatiblePSEditions). The #Requires above enforces that only
# when this runs as a .ps1 file - the recommended one-liner compiles the download into a scriptblock
# (& ([scriptblock]::Create(...))), and neither a scriptblock nor Invoke-Expression honors #Requires. So
# on Windows PowerShell 5.1 the guard would be skipped and the script would later die with a confusing
# "module not found" for PSResourceGet. Check explicitly and stop early (exit 3) with actionable
# guidance, before importing anything, so a wrong runtime never half-registers the feed.
$psv = $PSVersionTable.PSVersion
if ($PSVersionTable.PSEdition -ne 'Core' -or $psv.Major -lt 7 -or ($psv.Major -eq 7 -and $psv.Minor -lt 6)) {
    if (-not $Quiet) {
        $running = if ($PSVersionTable.PSEdition -eq 'Desktop') { "Windows PowerShell $psv" } else { "PowerShell $psv ($($PSVersionTable.PSEdition))" }
        Write-Warning "The Workoho internal PowerShell gallery requires PowerShell 7.6 or newer (Core edition); you are running $running."
        Write-Warning 'Install PowerShell 7 from https://aka.ms/powershell, then re-run this from a ''pwsh'' session.'
    }
    exit 3
}

$ErrorActionPreference = 'Stop'

# PSResourceGet ships with PowerShell 7.4+; import it up front so its cmdlets and the PSCredentialInfo
# type are available regardless of module auto-loading order.
Import-Module Microsoft.PowerShell.PSResourceGet -ErrorAction Stop

function Write-Status {
    param([string] $Message, [string] $Symbol = '[*]')
    if (-not $Quiet) { Write-Output "$Symbol $Message" }
}

$inContainer = [bool]($env:REMOTE_CONTAINERS -or $env:CODESPACES)
# Only prompt on a real terminal: if stdin is redirected (post-create, CI) never block on Read-Host.
$promptAllowed = [bool]($Interactive -or (-not $Quiet -and -not [Console]::IsInputRedirected -and -not $env:CI))

if (-not $Username) { $Username = 'workoho' }

$secretManagement = 'Microsoft.PowerShell.SecretManagement'
$secretStore = 'Microsoft.PowerShell.SecretStore'

# Detect (Windows only) whether the per-user PowerShell module folder is redirected into OneDrive via
# "Known Folder Move". This flag only concerns where *modules* get installed. The repository
# registration and the SecretStore vault live under LOCALAPPDATA and are never redirected - and
# PSResourceGet has no machine-wide repository registration anyway (Register-PSResourceRepository has no
# -Scope), so the repo record is always per-user and read back in the same user session. The flag steers
# our own vault-module install below and the closing advice for installing the actual Workoho modules.
$userDocuments = if ($IsWindows) { [Environment]::GetFolderPath('MyDocuments') } else { $null }
$moduleDirInOneDrive = $false
if ($userDocuments) {
    foreach ($root in @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer) | Where-Object { $_ }) {
        if ($userDocuments.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $moduleDirInOneDrive = $true; break }
    }
}

# --- 1. Resolve the read token, cheapest sources first --------------------------------------------
$secureToken = $null
$tokenSource = $null

if ($Token) {
    $secureToken = ConvertTo-SecureString $Token -AsPlainText -Force
    $tokenSource = 'parameter/environment'
}

# Reuse a previously stored token, but only if the vault modules are already present - never install
# them just to look. A fresh machine has no vault, so this is skipped there.
if (-not $secureToken -and (Get-Module -ListAvailable -Name $secretManagement)) {
    Import-Module $secretManagement -ErrorAction SilentlyContinue
    if (Get-SecretVault -Name $VaultName -ErrorAction SilentlyContinue) {
        $existing = Get-Secret -Name $SecretName -Vault $VaultName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        if ($existing -is [pscredential]) {
            $secureToken = $existing.Password
            $tokenSource = "vault '$VaultName'"
            if ($existing.UserName) { $Username = $existing.UserName }
            Write-Status "Reusing the read credential already stored in vault '$VaultName'."
        }
    }
}

if (-not $secureToken -and $promptAllowed) {
    $entered = Read-Host "GitHub read:packages token for $RepositoryName" -AsSecureString
    if ($entered.Length -gt 0) {
        $secureToken = $entered
        $tokenSource = 'interactive prompt'
    }
}

if (-not $secureToken) {
    Write-Status 'No read token found - feed not registered.' '[!]'
    if (-not $Quiet) {
        Write-Output ''
        Write-Output 'To enable read access, provide a classic PAT with read:packages by either:'
        Write-Output '  - setting WORKOHO_PACKAGES_READ_TOKEN on your host (or as a Codespaces secret), or'
        Write-Output '  - re-running the one-liner (it will prompt):'
        Write-Output '      & ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/workoho/setup/main/powershell/register-internal-gallery.ps1)))'
        Write-Output 'See https://github.com/workoho/setup.'
    }
    exit 2
}

# --- 2. We have a token: ensure the vault modules and a usable vault exist ------------------------
# Only the module *install* is sensitive to scope/OneDrive. Work out what is actually missing first: if
# both vault modules are already present (dev container feature, a previous run) nothing is written and
# the whole scope decision below is skipped.
$missingModules = @(($secretManagement, $secretStore) | Where-Object { -not (Get-Module -ListAvailable -Name $_) })

if ($missingModules.Count -gt 0) {
    $scopeExplicit = $PSBoundParameters.ContainsKey('Scope')
    $elevated = $false
    if ($IsWindows) {
        $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    # AllUsers writes to %ProgramFiles% and needs elevation. Enforce that on Windows; on other platforms
    # let Install-PSResource fail naturally if the user lacks permission.
    if ($Scope -eq 'AllUsers' -and $IsWindows -and -not $elevated) {
        Write-Status "-Scope AllUsers needs an elevated session to install: $($missingModules -join ', ')." '[!]'
        if (-not $Quiet) {
            Write-Output "  Start PowerShell with 'Run as administrator', then re-run the one-liner with -Scope AllUsers."
        }
        exit 4
    }

    # OneDrive "Known Folder Move" redirects the per-user module folder (Documents) into the cloud, so a
    # CurrentUser install would upload and sync the modules. Refuse to do it silently: stop and make the
    # user choose AllUsers (elevated) or an explicit -Scope CurrentUser opt-in.
    if ($moduleDirInOneDrive -and $Scope -eq 'CurrentUser' -and -not $scopeExplicit) {
        Write-Status 'Your PowerShell module folder is redirected into OneDrive - refusing to install there silently.' '[!]'
        if (-not $Quiet) {
            Write-Output "      $userDocuments\PowerShell\Modules"
            Write-Output '  Installing modules there uploads and syncs them via OneDrive (slow and error-prone). Choose one and re-run:'
            Write-Output '    - Machine-wide (recommended), from an elevated PowerShell:'
            Write-Output '        & ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/workoho/setup/main/powershell/register-internal-gallery.ps1))) -Scope AllUsers'
            Write-Output '    - Keep it in OneDrive anyway: append -Scope CurrentUser to confirm.'
        }
        exit 4
    }
}

foreach ($module in $secretManagement, $secretStore) {
    if ($missingModules -contains $module) {
        Write-Status "Installing $module ($Scope)..."
        Install-PSResource -Name $module -Repository PSGallery -TrustRepository -Scope $Scope -Quiet
    }
    Import-Module $module -ErrorAction Stop
}

if (-not (Get-SecretVault -Name $VaultName -ErrorAction SilentlyContinue)) {
    # In an isolated dev container/Codespace, initialize SecretStore for unattended use (no vault
    # password) so post-create and later commands never block on a prompt. Reset-SecretStore is the
    # only non-interactive way to set this on a brand-new store; it is safe here because the container
    # store starts empty. On a normal workstation we leave the developer's SecretStore untouched.
    if ($inContainer) {
        Reset-SecretStore -Scope CurrentUser -Authentication None -Interaction None -Force -Confirm:$false -WarningAction SilentlyContinue
    }
    Register-SecretVault -Name $VaultName -ModuleName $secretStore
    Write-Status "Registered SecretManagement vault '$VaultName'."
}

# --- 3. Store the credential and register/update the repository -----------------------------------
$credential = [pscredential]::new($Username, $secureToken)
Set-Secret -Name $SecretName -Vault $VaultName -Secret $credential
Write-Status "Stored read credential in vault '$VaultName' (from $tokenSource)."

$credentialInfo = [Microsoft.PowerShell.PSResourceGet.UtilClasses.PSCredentialInfo]::new($VaultName, $SecretName)

if (Get-PSResourceRepository -Name $RepositoryName -ErrorAction SilentlyContinue) {
    Set-PSResourceRepository -Name $RepositoryName -Uri $Uri -Trusted -Priority $Priority -CredentialInfo $credentialInfo
    Write-Status "Updated repository '$RepositoryName'." '[+]'
} else {
    Register-PSResourceRepository -Name $RepositoryName -Uri $Uri -Trusted -Priority $Priority -CredentialInfo $credentialInfo
    Write-Status "Registered repository '$RepositoryName'." '[+]'
}

if (-not $Quiet) {
    Write-Output ''
    # GitHub Packages has no wildcard search; query by exact name. -Prerelease shows preview builds.
    Write-Output "Read access is ready. Try:  Find-PSResource -Name Workoho.Entra.GuestGovernance -Repository $RepositoryName -Prerelease"

    # Reading is fine from any session, but *installing* modules is where OneDrive redirection bites: a
    # default CurrentUser install would sync the Workoho modules to the cloud. Steer that install to
    # AllUsers (elevated) when the module folder is redirected.
    if ($moduleDirInOneDrive) {
        Write-Output ''
        Write-Output '[!] Your Documents folder is redirected into OneDrive. When you install the modules, use an'
        Write-Output '    elevated PowerShell with -Scope AllUsers so they are not synced to OneDrive, e.g.:'
        Write-Output "        Install-PSResource -Name Workoho.Entra.GuestGovernance -Repository $RepositoryName -Scope AllUsers"
    }
}
