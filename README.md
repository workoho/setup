# workoho/setup

Bootstrap and setup scripts for Workoho developer machines and dev containers, meant to be run
directly over the network — no clone required. This is the **single source of truth** for scripts that
would otherwise be copy-pasted into every module repository (for example, registering the internal
PowerShell gallery). A fix here reaches every repo that references it.

Scripts are grouped by shell:

| Folder        | For        | Run with                                       |
| ------------- | ---------- | ---------------------------------------------- |
| `powershell/` | PowerShell | `& ([scriptblock]::Create((iwr …)))` (pwsh)    |
| `bash/`       | POSIX sh   | `curl … \| sh` (Bash)                          |

> PowerShell scripts are invoked via `[scriptblock]::Create` rather than `iwr … | iex` on purpose:
> `Invoke-Expression` is a common AMSI/antivirus trigger, and the scriptblock form also lets you pass
> parameters.

## Scripts

### `powershell/register-internal-gallery.ps1`

Registers the Workoho internal PowerShell gallery (a private GitHub Packages NuGet feed) for the current
user and stores a `read:packages` credential in a SecretManagement vault, so `Find-PSResource` /
`Install-PSResource` work without passing `-Credential` on every call.

Requires **PowerShell 7.6+ / Core** (`pwsh`) — matching the Workoho modules' own manifest requirement.
Windows PowerShell 5.1 is not supported and the script refuses to run there (exits with install guidance
rather than half-registering the feed), so run it from a `pwsh` session, not `powershell.exe`.

**Interactive — prompts for a token:**

```powershell
& ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/workoho/setup/main/powershell/register-internal-gallery.ps1)))
```

**Non-interactive — pass a token.** Same form, with `-Token` appended:

```powershell
& ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/workoho/setup/main/powershell/register-internal-gallery.ps1))) -Token ghp_xxx
```

The token is a **classic** PAT with the `read:packages` scope (fine-grained tokens are not accepted by
the GitHub NuGet registry). The script also picks up `WORKOHO_PACKAGES_READ_TOKEN` from the environment
and reuses a credential already stored in the vault, so on a configured machine it needs no input at all.

#### Windows + OneDrive

If OneDrive "Known Folder Move" is on, your `Documents` folder — and with it the per-user PowerShell
module path — is redirected into OneDrive, so a `CurrentUser` module install gets uploaded and synced
(slow and error-prone). When the script would have to install its vault modules and detects this, it
**stops** and asks you to choose rather than silently syncing modules to the cloud:

- **Machine-wide (recommended):** from a PowerShell started with **Run as administrator**, re-run with
  `-Scope AllUsers` — modules land under `%ProgramFiles%`, outside OneDrive.
- **Keep it in OneDrive anyway:** append `-Scope CurrentUser` to confirm the redirected location.

This only ever affects the *module install*; the stored credential and the repository registration live
under `%LOCALAPPDATA%` and are never touched by OneDrive. If the vault modules are already installed,
nothing is written and the check is skipped.

Other parameters (`-Scope`, `-RepositoryName`, `-Uri`, `-Priority`, `-VaultName`, `-SecretName`,
`-Quiet`, `-Interactive`) are documented in the header of
[the script](powershell/register-internal-gallery.ps1).

## Which ref to reference

- **Humans / ad-hoc runs:** use `main` (as above) — always the latest version.
- **Automation (dev containers, CI):** pin to a **tag** so a rebuild is reproducible and an accidental
  push to `main` cannot silently change what runs on every machine. Swap `main` for the tag in the raw
  URL:

  ```text
  https://raw.githubusercontent.com/workoho/setup/v1/powershell/register-internal-gallery.ps1
  ```

  Bump the pinned tag deliberately, via a pull request, in each consuming repo. For the strictest
  supply-chain guarantee, pin to a commit SHA instead of a tag.

## Releasing

Tag the commit you want automation to pin to:

```bash
git tag v1          # or v2 for a breaking change to a script's interface
git push origin v1
```

Keep `main` as the rolling latest; introduce a new major tag (`v2`, `v3`, …) when a change would break
existing callers of a script (renamed/removed parameters, changed exit-code contract, moved path).
