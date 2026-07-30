# Invoke-GHActionsImporterMigration.ps1 — Usage Guide

Migrates Azure DevOps **build** and/or **release** pipelines (classic or
YAML) to GitHub Actions workflows using `gh actions-importer`, with
selectable repo scope, rate-limit-aware retries, resumable state, and an
HTML dashboard.

Companion to `Get-ADOInventory.ps1` (source inventory) and
`Invoke-GHEMigration.ps1` (repo history migration via `gh ado2gh`). This
script handles the **pipeline logic conversion** step — a separate concern
from moving repo history. It requires **PowerShell 7.2+** (uses
`ForEach-Object -Parallel` for real concurrency control).

For repos with **classic ADO release pipelines**, `gh actions-importer`
alone drops approvals, deployment gates, service-connection auth, and
variable-group secrets — see `docs/README-ADOGap.md` (`tools/adogap/`) for
the companion gap-filler that closes that specific hole. Build (YAML/CI)
pipelines generally do not need `adogap`.

---

## 1. Prerequisites

`Test-Prerequisites` inside the script checks all of these at startup and
fails fast with a clear list if anything is missing.

| # | Requirement | Check | Fix |
|---|---|---|---|
| 1 | PowerShell 7.2+ | `$PSVersionTable.PSVersion` | `winget install Microsoft.PowerShell` |
| 2 | GitHub CLI (`gh`) | `gh --version` | https://cli.github.com |
| 3 | `gh-actions-importer` extension | `gh extension list` | `gh extension install github/gh-actions-importer` |
| 4 | Docker installed & running | `docker info` | Start Docker Desktop / `systemctl start docker` |
| 5 | GitHub PAT (classic) with `workflow` scope | — | Create at github.com/settings/tokens |
| 6 | Azure DevOps PAT with scopes below | — | Create at dev.azure.com -> User settings -> PATs |
| 7 | Env vars set (via `gh actions-importer configure` or `.env.local`) | — | See §2 |
| 8 | Network access to `api.github.com` and `dev.azure.com` | — | Check firewall/proxy |
| 9 | 2GB+ free disk space | — | Audit/dry-run/migrate artifacts accumulate under `-OutputDir` |
| 10 | Valid JSON inventory file | — | Output of `Get-ADOInventory.ps1` (schema in §3) |

**Azure DevOps PAT scopes required:** Agent Pools (Read), Build (Read), Code
(Read), Release (Read), Service Connections (Read), Task Groups (Read),
Variable Groups (Read).

## 2. One-time setup

```powershell
gh extension install github/gh-actions-importer
gh actions-importer update

# Configure credentials interactively (writes to .env.local)
gh actions-importer configure
```

This prompts for and stores `GITHUB_ACCESS_TOKEN` (classic PAT, `workflow`
scope), `GITHUB_INSTANCE_URL`, `AZURE_DEVOPS_ACCESS_TOKEN`,
`AZURE_DEVOPS_ORGANIZATION`, `AZURE_DEVOPS_INSTANCE_URL`. Load `.env.local`
into your session before running the script (same pattern as
`Invoke-GHEMigration.ps1`'s credential resolution):

```powershell
Get-Content .env.local | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($matches[1], $matches[2])
    }
}
```

## 3. Inventory file schema

The script expects the JSON produced by `Get-ADOInventory.ps1` to contain a
`Repositories` array with at least:

```json
{
  "Repositories": [
    {
      "RepoName": "payments-api",
      "ProjectName": "PaymentsPlatform",
      "BuildPipelineIds": [42, 43],
      "ReleasePipelineIds": [17]
    }
  ]
}
```

## 4. Parameter Reference

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-InventoryPath` | string | Yes | — | Path to the `Get-ADOInventory.ps1` JSON output |
| `-GitHubTargetUrlTemplate` | string | Yes | — | e.g. `https://github.com/<github-org>/{RepoName}` |
| `-SelectionMode` | `All`\|`Single`\|`Count`\|`List` | No | `All` | Repo scope for this run |
| `-SingleRepoName` | string | `Single` mode | — | Exactly one repo |
| `-RepoCount` | int (1-100000) | `Count` mode | — | First N repos, inventory order |
| `-RepoList` | string[] | `List` mode | — | Explicit named repo set |
| `-PipelineType` | `Build`\|`Release`\|`Both` | No | `Both` | Which pipeline types to convert |
| `-Migrate` | switch | No | off | Opts in to opening PRs against the target repo (default is dry-run) |
| `-MaxConcurrency` | int (1-10) | No | 3 | Parallel `ForEach-Object -Parallel` workers — keep 2-4 |
| `-MaxRetries` | int (0-15) | No | 5 | Retry attempts on rate-limit/transient failures |
| `-InitialBackoffSeconds` | int (1-300) | No | 15 | Base for exponential backoff |
| `-OutputDir` | string | No | `.\ghai-output` | Logs, artifacts, reports, state root |
| `-StateFilePath` | string | No | `<OutputDir>\state\migration-state.json` | Resume state file |
| `-Resume` | switch | No | off | Skip pipelines already `Succeeded` in the state file |
| `-SkipPreflightChecks` | switch | No | off | Skip `Test-Prerequisites` (not recommended) |
| `-PerPipelineTimeoutSeconds` | int (60-3600) | No | 600 | Hard timeout per pipeline conversion job |

## 5. Usage

**Default = dry run.** No PRs, no writes to GitHub. Converted YAML is
written to disk under `-OutputDir` for review. Pass `-Migrate` to open PRs.

```powershell
# Dry-run everything (safe default) — build + release, all repos
./scripts/Invoke-GHActionsImporterMigration.ps1 `
    -InventoryPath ./inventory/ado-inventory.json `
    -GitHubTargetUrlTemplate "https://github.com/<github-org>/{RepoName}"

# Dry-run build pipelines only, first 10 repos, higher concurrency
./scripts/Invoke-GHActionsImporterMigration.ps1 `
    -InventoryPath ./inventory/ado-inventory.json `
    -SelectionMode Count -RepoCount 10 `
    -PipelineType Build -MaxConcurrency 4 `
    -GitHubTargetUrlTemplate "https://github.com/<github-org>/{RepoName}"

# Single repo, for real — opens PRs
./scripts/Invoke-GHActionsImporterMigration.ps1 `
    -InventoryPath ./inventory/ado-inventory.json `
    -SelectionMode Single -SingleRepoName "app-service-1" -PipelineType Both `
    -Migrate `
    -GitHubTargetUrlTemplate "https://github.com/<github-org>/{RepoName}"

# Full production run with resume support (safe to re-run after a failure —
# only retries pipelines not already marked Succeeded)
./scripts/Invoke-GHActionsImporterMigration.ps1 `
    -InventoryPath ./inventory/ado-inventory.json `
    -SelectionMode All -Migrate -Resume `
    -GitHubTargetUrlTemplate "https://github.com/<github-org>/{RepoName}"

# Preview exactly what would run without executing anything
./scripts/Invoke-GHActionsImporterMigration.ps1 `
    -InventoryPath ./inventory/ado-inventory.json -Migrate -WhatIf `
    -GitHubTargetUrlTemplate "https://github.com/<github-org>/{RepoName}"
```

## 6. Rate limiting & reliability design

ADO and GitHub both throttle API traffic, and `gh actions-importer` gives no
typed rate-limit exception — throttling shows up as ADO's `TF400733`, an
HTTP `429`, GitHub secondary/abuse-detection responses, or an unhelpful
`503`. Three layers of defense:

1. **Floor spacing** — a minimum gap (default 2s) between *any* two `gh
   actions-importer` invocations across all parallel threads, via a global
   lock, regardless of concurrency setting.
2. **Signal detection** — pattern-matches command output against known
   ADO/GitHub throttling signatures after every call.
3. **Exponential backoff with full jitter** — retries up to `-MaxRetries`
   times, waiting `base × 2^(attempt-1)` seconds plus jitter, capped at 5
   minutes, before marking that pipeline `Failed` and moving on (it does not
   abort the whole run).

**Concurrency guidance:** keep `-MaxConcurrency` at 2–4. Each unit of work
spins up its own Docker container and makes multiple ADO + GitHub API
calls — higher concurrency is the most common cause of secondary rate
limiting in practice, not a throughput win.

## 7. Resumability, logging, and reporting

- **State file** — every pipeline's last outcome is recorded; pass `-Resume`
  to skip anything already `Succeeded` on a re-run (safe after a partial
  failure or Ctrl+C).
- **Logs** — human-readable (`logs\actions-importer-<runid>.log`) and
  structured JSON-lines (`logs\actions-importer-<runid>.jsonl`) for
  Splunk/ELK/Sentinel ingestion. Both thread-safe across parallel runspaces
  via a named mutex.
- **Per-pipeline artifacts** — raw `gh actions-importer` output and
  converted YAML kept under `artifacts\<repo>\<Build|Release>-<id>\` for
  review before merging any PR.
- **Reports** — `reports\` gets a CSV (`migration-results-<runid>.csv`) and
  an HTML dashboard (`migration-dashboard-<runid>.html`) — same visual
  pattern as the dashboard in `Invoke-GHEMigration.ps1`.
- **Exit codes** — `0` all succeeded, `1` one or more pipelines failed
  (check the report), `2` fatal error before any work started. Useful for
  CI/CD gating.

## 8. Known limitations (inherited from `gh actions-importer`)

Not bugs in this wrapper — upstream limitations of the importer itself, and
they show up in the "Manual steps" section of any PR it opens:

- Pre-/post-deployment **gates/approvals** are not converted — rebuild as
  GitHub Environments with required reviewers (or use `adogap scaffold`).
- **Service connections** (OIDC, PATs, GitHub Apps) must be recreated
  manually.
- **Self-hosted agent pools** need manual runner-label mapping.
- **Variable groups** convert to references only — actual secret values must
  be created in GitHub manually.
- Some **resource triggers** and `schedules`/`on.workflow_run` triggers are
  unsupported.

Run `gh actions-importer audit azure-devops` first to get a full picture of
Successful / Partially successful / Unsupported pipelines before committing
to a full `-Migrate` run. For classic release pipelines specifically, follow
up with `tools/adogap/` (`docs/README-ADOGap.md`) so approvals/gates/secrets
aren't silently dropped.
