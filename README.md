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

Each script has a guide next to it (same name, `.md`) with usage, parameters, and caveats.

| Script | Guide | What it does |
| --- | --- | --- |
| [`powershell/register-internal-gallery.ps1`](powershell/register-internal-gallery.ps1) | [Guide](powershell/register-internal-gallery.md) | Registers the Workoho internal PowerShell gallery (private GitHub Packages feed) and stores a `read:packages` credential in a SecretManagement vault. |

Quick start (interactive — prompts for a token):

```powershell
& ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/workoho/setup/main/powershell/register-internal-gallery.ps1)))
```

## Which ref to reference

- **Humans / ad-hoc runs:** use `main` (as in the quick start above) — always the latest version.
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
