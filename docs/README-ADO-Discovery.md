# Get-ADOInventory.ps1 — ADO Discovery Guide

Inventories an Azure DevOps organisation — projects, repositories, and
build/release pipelines — and produces an 8-sheet Excel workbook (a
leadership showcase page plus detailed data pages) and a JSON sidecar for
executive reporting and batch migration planning to **GitHub Enterprise
Importer (GEI)** and **GitHub Actions**.

---

## 1. What It Does

```
Azure DevOps REST API --> Get-ADOInventory.ps1 --> ADO_Inventory_*.xlsx (8 sheets)
  (repos, builds,             |         |          ADO_Inventory_*.json
   releases)                  v         v
                     git-sizer (per   gh actions-importer CLI, or a
                     repo, if         heuristic YAML task scan, if
                     -RunGitSizer)    -CheckActionsImporter
```

1. Resolve the PAT and validate the ADO connection.
2. Enumerate all projects, then all repositories per project.
3. Enumerate all build (YAML/Classic) and classic Release pipelines per
   project, and map each one to the repository it builds/deploys.
4. For each repository, pull size/branch/last-commit metadata from the ADO
   REST API, pull the latest run date/result for every pipeline that targets
   it, and optionally clone it (bare) to run `git-sizer` for deep analysis.
5. Compute a "Last Used" activity signal (latest of last commit / last
   pipeline run) and classify every repository against GitHub Enterprise
   Importer limits and, optionally, GitHub Actions Importer readiness.
6. Assign each repository to a recommended migration batch.
7. Write the Excel workbook and JSON sidecar, then print a console summary.

This is the discovery step that feeds `Invoke-GHEMigration.ps1` (repo
migration) and, for repos with classic ADO release pipelines,
`Invoke-GHActionsImporterMigration.ps1` + `tools/adogap/` (pipeline
migration — see `docs/README-Actions-Importer.md` and
`docs/README-ADOGap.md`).

---

## 2. Prerequisites

| Requirement | Notes |
|---|---|
| PowerShell | 5.1 (Windows PowerShell) or PowerShell 7+ — both supported |
| ImportExcel module | Auto-installed from the PowerShell Gallery if missing |
| git | Required only for `-RunGitSizer`; must be on `PATH` |
| git-sizer | Required only for `-RunGitSizer`; auto-installed if missing (winget -> GitHub release -> brew) |
| `gh` CLI + `actions-importer` extension | Optional, used by `-CheckActionsImporter` if present; otherwise falls back to a heuristic YAML scan |
| PAT scope for pipelines | Requires **Build: Read** (and **Release: Read** if your org uses classic Release pipelines) in addition to Project/Code Read |
| Network access | To `dev.azure.com`, `vsrm.dev.azure.com`, the PowerShell Gallery, and (if auto-installing git-sizer) `api.github.com` |

## 3. Creating a PAT Token

Azure DevOps -> profile icon -> **Personal access tokens** -> **New Token**.
Under **Scopes**, choose **Custom defined** and grant, at minimum:

- **Project and Team** -> **Read**
- **Code** -> **Read** (also covers reading active pull requests)
- **Build** -> **Read** (needed for the pipeline inventory)
- **Release** -> **Read** (needed only if your org uses classic Release pipelines)

Copy the token immediately (it is not shown again). Store it securely — prefer a
`SecureString` or a secret store, never hard-code it into scripts or source control.

## 4. Quick Start

```powershell
# Basic inventory (no git-sizer)
$pat = Read-Host -AsSecureString "Enter PAT"
./scripts/Get-ADOInventory.ps1 -Organisation <ado-org> -PAT $pat

# With git-sizer deep analysis
./scripts/Get-ADOInventory.ps1 -Organisation <ado-org> -PAT $pat -RunGitSizer

# Full picture for leadership - sizing, pipelines, and Actions Importer readiness
./scripts/Get-ADOInventory.ps1 -Organisation <ado-org> -PAT $pat -RunGitSizer -CheckActionsImporter

# Fast pass, skip pipeline collection (API-only, repos only)
./scripts/Get-ADOInventory.ps1 -Organisation <ado-org> -PAT $pat -SkipPipelineInventory
```

## 5. Parameters Reference

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Organisation` | string | Yes | — | ADO org name from `dev.azure.com/{org}` |
| `-PAT` | object | Yes | — | Plain string or `SecureString` |
| `-OutputPath` | string | No | `.\ADO_Inventory_{org}_{timestamp}.xlsx` | Path for the Excel workbook |
| `-RunGitSizer` | switch | No | Off | Enables deep per-repo `git-sizer` analysis |
| `-GitSizerWorkDir` | string | No | `$env:TEMP\ADO-GitSizer-{timestamp}` | Directory for temporary bare clones |
| `-KeepClones` | switch | No | Off | Keep bare clones after analysis (debugging) |
| `-GitSizerPath` | string | No | `git-sizer` (searched on `PATH`) | Full path to the `git-sizer` binary |
| `-ExcludeEmptyRepos` | switch | No | Off | Skip repositories with 0 bytes |
| `-IncludeDisabledProjects` | switch | No | Off | Include projects whose state is not `wellFormed` |
| `-SkipPipelineInventory` | switch | No | Off | Skip build/release pipeline collection for a faster, API-lighter run |
| `-CheckActionsImporter` | switch | No | Off | Checks GitHub Actions Importer readiness for YAML build pipelines (real CLI if present, heuristic scan otherwise) |
| `-InactivityThresholdDays` | int | No | `180` | Days since last commit/pipeline run after which a repo is flagged "Stale" |

> **Note:** these param names (`-Organisation`, `-PAT`, `-OutputPath`, ...)
> replace the pre-v3 script's `-AdoOrg`/`-AdoPat`/`-OutputFolder`/etc. Update
> any saved commands or scheduled-pipeline YAML that still uses the old names.

## 6. GitHub Compatibility Checks

| # | Check | Threshold | Severity | Source |
|---|---|---|---|---|
| 1 | Repository unique blob size | >= 40 GB | Blocker | API size / git-sizer |
| 2 | Repository size approaching limit | >= 30 GB | Warning | API size |
| 3 | Individual file (blob) size | >= 400 MB | Blocker | git-sizer |
| 4 | Individual file (blob) size | >= 100 MB | Warning | git-sizer / API |
| 5 | Individual commit size | >= 2 GB | Blocker | git-sizer |
| 6 | Ref / path name length | > 255 bytes | Blocker | git-sizer |
| 7 | Version control type | TFVC | Blocker | API (GEI migrates Git only) |

Git LFS usage is flagged as a **warning** (not a blocker) — LFS objects
require a manual `git lfs push --all` after migration.

## 7. Pipeline Inventory, Activity Tracking, and Batch Planning

For every project, the script enumerates **build pipelines** (YAML and
Classic/Designer) and **classic Release pipelines**, matched to their source
repository on a best-effort basis. Unmapped release pipelines are still
recorded, tagged `Unmapped / Multiple`.

**Activity status** — `Last Used` is the more recent of a repo's last commit
date and its most recent pipeline run date:

| Status | Window |
|---|---|
| `[ACTIVE] Active` | 0-30 days |
| `[RECENT] Recent` | 31-90 days |
| `[DORMANT] Dormant` | 91 days – `-InactivityThresholdDays` |
| `[STALE] Stale` | Beyond `-InactivityThresholdDays` (default 180) |
| `[UNKNOWN]` | No commit or pipeline data could be retrieved |

**GitHub Actions Importer readiness** (`-CheckActionsImporter`) — if `gh` +
the `actions-importer` extension are installed, that's noted, but the audit
itself is not run automatically (run it separately: `gh actions-importer
audit azure-devops --output-dir ./actions-importer-audit --source-file-path
<pipeline.yml>`). Otherwise, or in addition, a heuristic scans each YAML
build pipeline's `task:` references against a common-task allowlist and
labels it `Likely Automatable (NN% recognized)` or `Needs Manual Review (NN%
recognized)`. Classic build pipelines are always `Manual - Classic
pipeline`; classic Release pipelines are always `Manual - Release pipelines
require re-implementation as GitHub Actions environments/deployment jobs`
(no direct Actions equivalent — see `docs/README-ADOGap.md`).

> This heuristic is a planning aid, not a certification. Treat "Likely
> Automatable" as "run through the real `gh actions-importer` audit next."

**Migration batches:**

| Batch | Criteria |
|---|---|
| `Batch 0 - Remediate First` | Has one or more GEI blockers |
| `Batch 1 - Pilot` | No blockers, Stale/Dormant, <= 1 build pipeline, no release pipelines, no warnings, no open PRs, < 1 GB |
| `Batch 2 - Standard` | No blockers, simple pipeline footprint, no warnings, no open PRs |
| `Batch 3 - Complex` | Has open PRs, has release pipelines, 3+ pipelines total, or open warnings |
| `Batch 4 - Forks` | Repository is a fork — confirm ownership/need before migrating |

Any repository with one or more open PRs is automatically placed in `Batch 3
- Complex`. Batch assignments are a **starting recommendation** — review and
adjust in the Migration Planner / Migration Batches sheets.

## 8. Two-Tier Analysis

| Capability | Without `-RunGitSizer` | With `-RunGitSizer` |
|---|:---:|:---:|
| Project & repository inventory, size, branch, last commit | Yes | Yes |
| TFVC / repo-size / approaching-limit checks | Yes | Yes |
| Largest individual file size & name | No | Yes |
| Largest individual commit size | No | Yes |
| Longest ref / path name | No | Yes |
| Git LFS detection | No | Yes |
| Corrupted pack-data detection | No | Yes |

## 9. git-sizer Integration

`git-sizer` scans a Git repository's full history for pathological objects —
huge blobs, huge commits, deep histories, long ref names. Auto-install order
(only if not already resolvable): `winget install --id github.git-sizer` ->
latest GitHub release ZIP -> `brew install git-sizer`. If all fail, the
script disables `-RunGitSizer` and continues with the API-only inventory
(does not fail the run).

Each repo is bare-cloned (`git clone --bare --quiet`) under
`-GitSizerWorkDir`, analysed with `git-sizer --json --no-progress`, then
deleted unless `-KeepClones` is set. **Why regex parsing, not
`ConvertFrom-Json`?** `git-sizer`'s JSON output embeds raw annotation
strings such as `^{tree}` inside string values, which breaks standard
PowerShell JSON parsers — the script extracts each numeric field with a
targeted regex instead.

Disk-space guidance: the script requires free space of at least
`max(512 MB, repo size × 0.75)` on the drive hosting `-GitSizerWorkDir`
before cloning; if the check itself fails, it's skipped with a warning.

## 10. Excel Workbook Layout (8 sheets)

| # | Sheet | Audience | Purpose |
|---|---|---|---|
| 1 | Leadership Summary | Executives / sponsors | Readiness %, status breakdown, pipeline footprint, batch counts |
| 2 | Project Summary | Migration engineers | One row per project, repo/pipeline totals |
| 3 | Repository Detail | Migration engineers | One row per repo — pipeline counts, Last Used, Activity Status |
| 4 | Pipeline Inventory | Migration engineers | One row per build/release pipeline: type, last run, result, Actions Importer readiness |
| 5 | GitHub Compatibility | Migration engineers | Every repo with a blocker/warning, sorted by severity |
| 6 | Migration Planner | Batch owners | Editable batch-tracking sheet (status / owner / notes) |
| 7 | Migration Batches | Batch owners / leadership | Batch definitions, per-batch totals, repo-to-batch assignment |
| 8 | Raw Data | BI / analysts | Flat, unformatted export for pivot tables / BI tools |

## 11. Interpreting Results

| GH Migration Status | Meaning |
|---|---|
| `[OK] READY` | No blockers or warnings — safe to migrate as-is |
| `[WARN] NEEDS REVIEW` | One or more warnings — review before migrating |
| `[BLOCKED] BLOCKED` | One or more blockers — must be remediated first |

| Migration Priority | Meaning |
|---|---|
| `1 - Fix Before Migration` | Has blockers; migrate last, after remediation |
| `2 - Migrate with Care` | >= 5 GB, no blockers; plan extra time |
| `3 - Standard (Large)` | >= 1 GB, no blockers |
| `4 - Standard Migration` | Under 1 GB, no blockers; migrate first |

## 12. Remediation Guide

Blocked/warn repos: follow
[`ADO-to-GitHub_Migration_Remediation_Plan.md`](ADO-to-GitHub_Migration_Remediation_Plan.md)
(git filter-repo purge procedure, tiering, LFS guidance).

| Issue | Recommended remediation |
|---|---|
| TFVC project | Convert to Git in ADO (or migrate history with `git-tfs`) before using GEI |
| Repository >= 40 GB | Split the repository, or use `git filter-repo` to remove large/unused history |
| File >= 400 MB (blocker) / >= 100 MB (warning) | Move to Git LFS, or remove from history with `git filter-repo` |
| Commit >= 2 GB | Identify the offending commit with `git-sizer`/`git verify-pack` and rewrite history |
| Ref/path name > 255 bytes | Rename the branch/tag or shorten deeply nested folder paths |
| Git LFS objects | Not carried by GEI automatically — run `git lfs push --all <destination>` manually after migration |

## 13. JSON Export

`ADO_Inventory_{org}_{timestamp}.json` shares the Excel file's base name.
Top-level fields: `Organisation, GeneratedAt, GitSizerAnalysis,
ActionsImporterChecked, PipelineInventoryRun, TotalProjects, TotalRepos,
TotalBytes, TotalSizeFormatted, TotalMigrationBlockers,
TotalMigrationWarnings, TotalBuildPipelines, TotalReleasePipelines,
MigrationReadyPercent, Projects[], Repositories[], Pipelines[],
CompatibilityIssues[], MigrationBatches[]`.

**CI/CD gate example** (fail a pipeline if any blockers exist):

```powershell
$report = Get-Content .\ADO_Inventory_contoso_20260704_120000.json -Raw | ConvertFrom-Json
if ($report.TotalMigrationBlockers -gt 0) {
    Write-Error "Migration blocked: $($report.TotalMigrationBlockers) repositories have unresolved blockers."
    exit 1
}
```

## 14. Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| Script exits with "Could not connect..." (exit 1) | Invalid/expired PAT, or missing Project Read scope | Regenerate the PAT with Project Read + Code Read scopes |
| `-RunGitSizer` silently disabled | `git` or `git-sizer` not found and auto-install failed | Install Git and `git-sizer` manually, or pass `-GitSizerPath` |
| `git clone failed` warnings in the compatibility sheet | PAT lacks Code:Read scope, or repo is empty | Check PAT scopes; confirm the repo has at least one commit |
| "[CORRUPTED REPO]" failures | Corrupted pack data in the ADO-hosted repository | Run `git fsck` against the source repo; contact your ADO admin |
| Excel file fails to open / looks empty | A previous run's file was locked or partially written | Close any open copy of the workbook before re-running |
| "Could not fetch build/release definitions" warnings | PAT lacks Build:Read (and/or Release:Read) scope | Regenerate the PAT with the missing scope |
| Release pipeline shows `Repository Name = Unmapped / Multiple` | Could not automatically trace the release artifact to a single repo | Expected for complex release pipelines; check manually in ADO |
| Actions Importer readiness stuck on "Not checked" | `-CheckActionsImporter` was not passed | Re-run with `-CheckActionsImporter` |
| Disk-space warning during git-sizer analysis | `-GitSizerWorkDir` drive is nearly full | Point `-GitSizerWorkDir` at a drive with more free space |

## 15. Security Considerations

- The PAT is only ever held in memory for the duration of the run; prefer
  passing it as a `SecureString`.
- Never commit a PAT to source control or embed it in a script.
- Grant the PAT the minimum scopes required and set a short expiration
  window for one-off migration audits.
- Bare clones for `git-sizer` are deleted immediately after analysis unless
  `-KeepClones` is set — treat retained clones as sensitive.
- The generated workbook/JSON contain repository names, URLs, and (if used)
  description text from ADO — handle with the same sensitivity as the source
  repositories. This repo is Internal — do not share these outputs externally.
