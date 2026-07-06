# `register-internal-gallery.ps1`

Registers the Workoho internal PowerShell gallery (a private GitHub Packages NuGet feed) for the current
user and stores a `read:packages` credential in a SecretManagement vault, so `Find-PSResource` /
`Install-PSResource` work without passing `-Credential` on every call.

Part of [workoho/setup](../README.md) — see there for the general one-liner conventions and how to pin a
version.

## Requirements

**PowerShell 7.6+ / Core** (`pwsh`) — matching the Workoho modules' own manifest requirement. Windows
PowerShell 5.1 is not supported: the script refuses to run there (exits with install guidance rather than
half-registering the feed), so run it from a `pwsh` session, not `powershell.exe`.

## Usage

**Interactive — prompts for a token:**

```powershell
& ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/workoho/setup/main/powershell/register-internal-gallery.ps1)))
```

**Non-interactive — pass a token.** Same form, with `-Token` appended:

```powershell
& ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/workoho/setup/main/powershell/register-internal-gallery.ps1))) -Token ghp_xxx
```

**From a local checkout** of workoho/setup:

```powershell
pwsh powershell/register-internal-gallery.ps1            # prompts if no token is found
pwsh powershell/register-internal-gallery.ps1 -Token ghp_xxx
```

The token is a **classic** PAT with the `read:packages` scope (fine-grained tokens are not accepted by
the GitHub NuGet registry). It is resolved in this order, first hit wins:

1. `-Token`
2. `$env:WORKOHO_PACKAGES_READ_TOKEN` (host env var / Codespaces secret)
3. a credential already stored in the target vault (reuse a previous run's token)
4. an interactive prompt (only on a real terminal, or with `-Interactive`)

So on an already-configured machine it needs no input at all.

## Windows + OneDrive

If OneDrive "Known Folder Move" is on, your `Documents` folder — and with it the per-user PowerShell
module path — is redirected into OneDrive, so a `CurrentUser` module install gets uploaded and synced
(slow and error-prone). When the script would have to install its vault modules and detects this, it
**stops** and asks you to choose rather than silently syncing modules to the cloud:

- **Machine-wide (recommended):** from a PowerShell started with **Run as administrator**, re-run with
  `-Scope AllUsers` — modules land under `%ProgramFiles%`, outside OneDrive.
- **Keep it in OneDrive anyway:** append `-Scope CurrentUser` to confirm the redirected location.

This only ever affects the *module install*. The stored credential and the repository registration live
under `%LOCALAPPDATA%` and are never touched by OneDrive — and PSResourceGet has no machine-wide
repository registration anyway (`Register-PSResourceRepository` has no `-Scope`), so the repo record is
always per-user and read back in the same user session. Registering "as admin" is therefore neither
possible nor useful. If the vault modules are already installed, nothing is written and the check is
skipped.

Because *installing the actual modules* has the same OneDrive exposure, when redirection is detected the
script's closing hint reminds you to install them with `-Scope AllUsers` from an elevated session, e.g.:

```powershell
Install-PSResource -Name Workoho.Entra.GuestGovernance -Repository WorkohoInternalPSGallery -Scope AllUsers
```

## Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-Token` | `$env:WORKOHO_PACKAGES_READ_TOKEN` | Classic `read:packages` PAT. |
| `-Username` | `$env:WORKOHO_PACKAGES_USER` or `workoho` | Username stored with the credential. |
| `-Scope` | `CurrentUser` | Where the SecretManagement vault modules install (`CurrentUser` / `AllUsers`). See Windows + OneDrive above. |
| `-RepositoryName` | `WorkohoInternalPSGallery` | Name the feed is registered under. |
| `-Uri` | `https://nuget.pkg.github.com/workoho/index.json` | The GitHub Packages NuGet feed. |
| `-Priority` | `20` | Repository priority (lower resolves first). |
| `-VaultName` | `WorkohoVault` | SecretManagement vault holding the credential. |
| `-SecretName` | `WorkohoPackagesRead` | Secret name inside the vault. |
| `-Interactive` | off | Force the token prompt even when stdin looks non-interactive. |
| `-Quiet` | off | Suppress all output; signal only via the exit code (the caller owns messaging). |

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success — feed registered or updated. |
| `2` | No read token found; nothing was registered (non-fatal — a caller can treat it as a warning). |
| `3` | Unsupported runtime (older than PowerShell 7.6, or non-Core). |
| `4` | Needs a scope decision before installing the vault modules — OneDrive-redirected `CurrentUser`, or `AllUsers` without elevation. |
| other | A real failure. |
