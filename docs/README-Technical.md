# Technical Reference — Invoke-GHEMigration.ps1 (v2.7.0)

## 1. What the Script Migrates

| Data | Migrated | Notes |
|---|---|---|
| Commit history | ✅ | Full history, all reachable commits |
| Branches | ✅ | All `refs/heads/*`; verified in Phase 5 |
| Tags | ✅ | Annotated and lightweight; verified in Phase 5 |
| Git LFS objects | ✅ | **Automatic**, with optional verify/fallback-push — see section 2 |
| Wiki | ❌ | ADO wikis are separate repos — migrate manually if needed |
| Pipelines | ❌ | Stay in ADO; rewired via 4_Rewire-Pipeline.ps1, or converted to GitHub Actions via `Invoke-GHActionsImporterMigration.ps1` (+ `tools/adogap/` for classic release pipelines) |
| Work items / boards | ❌ | Out of scope |
| PR history | ⚠️ partial | Migrated as read-only history attributed to mannequins |

## 2. LFS — What Actually Happens

`gh ado2gh migrate-repo` migrates LFS objects **automatically** — there is no
LFS flag on the `ado2gh` command itself. The `NeedsLfs` column in the audit
CSV is a size-based heuristic (`SizeMB > 500 → RECOMMENDED`).

The script's own `-IncludeLfs` switch enables **Phase 5b — LFS
VERIFICATION**: for every successfully migrated repo flagged
`NeedsLfs = RECOMMENDED`, it shallow-clones the GitHub repo and runs `git lfs
ls-files` to confirm objects actually landed (`Invoke-LfsVerification`). Any
repo with missing/failed LFS objects triggers an interactive prompt (skipped
non-interactively/in CI) offering a **fallback push**
(`Invoke-LfsFallbackPush`): full clone from ADO → `git lfs fetch --all` →
push to the GitHub remote. Disk-space headroom (2.5× the LFS-flagged repos'
total size) is estimated during Phase 3 and checked again before the
fallback push. Skip the whole phase with `-SkipLfsVerification` even when
`-IncludeLfs` is set. Post-migration, you can always verify manually with
`git lfs ls-files` in a fresh clone.

## 3. Prerequisites

| Tool | Min | Check | Install |
|---|---|---|---|
| PowerShell | 7.0 | `$PSVersionTable` | `winget install Microsoft.PowerShell` |
| git | 2.38 | `git --version` | `winget install Git.Git` / `brew install git` |
| gh CLI | 2.30 | `gh --version` | `winget install GitHub.cli` / `brew install gh` |
| gh-ado2gh | 2.x | `gh extension list` | `gh extension install github/gh-ado2gh` |
| az CLI | 2.50 | `az version` | see Microsoft docs |
| az azure-devops | latest | `az extension list` | `az extension add --name azure-devops` |
| jq | 1.6 | `jq --version` | `winget install jqlang.jq` / `brew install jq` |

`Resolve-LocalTools` falls back to `bin/gh.exe` and `bin/jq.exe` (then the
script folder) when the tools are not on PATH — useful on locked-down agents.

## 4. Credentials — Setup and Priority

1. **CLI parameter** — `-AdoPat` / `-GitHubPat` as `SecureString`
2. **Environment variable** — `$env:ADO_PAT` / `$env:GH_PAT`
3. **Config file** — `AdoPat` / `GitHubPat` in migration.config.json (ephemeral CI only; ignored when 1 or 2 present)
4. **Interactive prompt** — `Read-Host -AsSecureString`

`Resolve-Credentials` exports plain values to `ADO_PAT`, `GH_PAT`, `GH_TOKEN`
(required for gh CLI internal auth), and `AZURE_DEVOPS_EXT_PAT` for child
processes. No value is ever written to a log, report, or CSV.

## 5. Migration Modes

| Mode | Source of repo list | Behavior |
|---|---|---|
| `All` | ADO REST API | Every repo in the project, disabled repos excluded, name→name mapping |
| `Single` | `-RepoName` | One repo; metadata enriched from ADO when reachable |
| `Selected` | `-RepoListFile` CSV | Columns `AdoRepo,GitHubRepo,Lfs`, case-insensitive headers |

Both the `-ResumeFromState` filter (drop repos in `Completed[]`) and the
`-SkipExistingRepos` filter (drop repos already on GitHub) apply after mode
resolution.

## 6. All Parameters

See the [Parameter Reference table in README.md](../README.md#parameter-reference) —
kept in one place to avoid drift.

## 7. Phase-by-Phase Walkthrough

1. **VALIDATION** — resolves tools (`bin/` fallback)/credentials, checks
   versions and the ado2gh and azure-devops extensions, then runs
   `Test-GitHubPatPermissions`: a `createMigrationSource` GraphQL mutation
   that fails fast when the PAT lacks the `workflow` scope.
2. **DISCOVERY** — `Resolve-RepoList` builds the queue per mode, applies the
   resume filter (`Restore-MigrationState`) and idempotency filter, counts
   skips.
3. **AUDIT** — per repo: active PR count, branch + tag count, GitHub
   existence, size risk tier (`BLOCKED` active PRs, `CRITICAL` >10 GB,
   `XLARGE` >5 GB, `LARGE` >1 GB), `NeedsLfs` heuristic, and (if
   LFS-recommended repos exist and `-SkipLfsVerification` is not set) an
   estimated disk-space requirement for Phase 5b. Exports CSVs and the HTML
   dashboard, then gates on active PRs.
4. **MIGRATION** — waves of `WaveSize` repos; each wave runs up to
   `ConcurrentJobs` self-contained runspace workers executing
   `gh ado2gh migrate-repo`. Each success downloads the GEI migration log and,
   unless `-SkipPerRepoValidation`, runs `Invoke-PerRepoValidation`
   (HEAD-SHA + branch + tag comparison) immediately. State is persisted after
   every wave.
5. **VERIFICATION** — `Invoke-RepoVerification` compares ADO branch/tag
   counts (REST) with GitHub branch/tag counts (`gh api ... --paginate`);
   logs PASS/WARN, exports CSV.
5b. **LFS VERIFICATION** (only if `-IncludeLfs`, unless
   `-SkipLfsVerification`) — see section 2.
6. **POST-CONFIG** — renames the default branch when `-DefaultBranch` differs,
   applies branch protection (file or built-in default), grants team push,
   applies `-CustomProperties` / `-SetAdoMetadata` GitHub custom properties,
   and downloads the `gh ado2gh download-logs` diagnostic bundle per repo.
7. **PIPELINE GUIDE** — writes the checkout-update YAML snippet (using
   `-ServiceConnectionName`), the `Update-DevRemote.ps1` developer script,
   and logs mannequin instructions.
8. **REPORT** — HTML report with stats cards and per-repo rows (including
   branch and tag ADO/GH counts); final state JSON.

## 8. Output Files

| File | Format | Purpose / what to do with it |
|---|---|---|
| `migration-{RUNID}.log` | text | Full audit trail — attach to change tickets |
| `migration-report-{RUNID}.html` | HTML | Share with stakeholders; verify 100% success |
| `migration-state-{RUNID}.json` | JSON | Feed to `-ResumeFromState` after interruptions |
| `audit/audit-{RUNID}.csv` | CSV | Risk review before production run |
| `audit/audit-dashboard-{RUNID}.html` | HTML | Visual pre-migration go/no-go review |
| `audit/active-prs-{RUNID}.csv` | CSV | Send to repo owners to close PRs |
| `audit/repo-verification-{RUNID}.csv` | CSV | Investigate any `Match=False` rows (branch + tag) |
| `audit/per-repo-validation-{RUNID}.csv` | CSV | HEAD-SHA/branch/tag VERIFIED vs ISSUES_FOUND per repo |
| `audit/lfs-verification-{RUNID}.csv` | CSV | Only when `-IncludeLfs` — LFS object presence per repo |
| `migration-logs/{repo}-{RUNID}.log` | text | Per-repo GEI log — first stop for failures |
| `migration-logs/{repo}-ado2gh-diagnostics.log` | text | `gh ado2gh download-logs` diagnostic bundle |
| `pipeline-update-guide.yml` | YAML | Manual pipeline checkout update reference |
| `Update-DevRemote.ps1` | PS1 | Distribute to developers post-cutover |

## 9. Wave and Concurrency Control

A RunspacePool (`min=1, max=ConcurrentJobs`) hosts self-contained worker
scriptblocks — no module/function marshalling, everything passed as arguments.
`EndInvoke()` returns a `PSDataCollection`; the script extracts `$result[0]`
with a null guard (a fixed v2.0 bug caused false success reporting here).
`WaveDelaySeconds` exists to avoid GitHub **secondary rate limits**; GitHub
additionally enforces ~5 concurrent GEI migrations per org, so keep
`ConcurrentJobs ≤ 5`.

## 10. Active PR Handling

| Scenario | Behavior |
|---|---|
| PRs found, default, CI (non-interactive) | `throw` — run blocked with the exact repo list |
| PRs found + `-ForceWithActivePrs` | Warning per repo, migration continues |
| PRs found, interactive terminal | Prompt: `[S]kip` affected repos / `[F]orce` / `[A]bort` |

## 11. Idempotency and Resume

`-SkipExistingRepos` calls `GET /repos/{org}/{repo}` per target; existing repos
log `SKIP — {repo} already exists on GitHub`, increment `Stats.Skipped`, and
appear as yellow rows in the report. `-ResumeFromState` loads a prior state
JSON and removes `Completed[]` repos from the queue; `Failed[]` repos re-run.

## 12. Post-Migration: What the Script Does NOT Do

- **Mannequin reclaim** — manual: `generate-mannequin-csv` → edit → `reclaim-mannequin`.
- **Developer remote updates** — distribute the generated `Update-DevRemote.ps1`.
- **Pipeline reconnection** — run `4_Rewire-Pipeline.ps1`.
- **Board/work-item migration** — permanently out of scope.
- **Branch protection review** — the applied rules are a baseline; tune per repo.

## 13. Common Errors and Fixes

| Error | Fix |
|---|---|
| `GH_PAT is missing the 'workflow' scope` | Add `workflow` scope to the PAT |
| `createMigrationSource ... insufficient permission` | Grant migrator role: `gh ado2gh grant-migrator-role --github-org <org> --actor <user> --actor-type USER` |
| `Repository already exists` | Rerun with `-SkipExistingRepos` |
| `Active pull requests found ... -ForceWithActivePrs was not set` | Close/abandon PRs (see active-prs CSV) or add the switch |
| `Config file ... not found` | Fix `-ConfigFile` path |
| `Repo list file ... missing required columns` | Header row must be `AdoRepo,GitHubRepo,Lfs` |
| `gh extension 'ado2gh' not installed` | `gh extension install github/gh-ado2gh` |
| `az extension 'azure-devops' missing` | `az extension add --name azure-devops` |
| `TF401019` / repo not found | Check `-AdoOrg`/`-AdoProject`/repo spelling; PAT needs Code (Read) |
| HTTP 429 during post-config | Automatic — `Invoke-WithRetry` honours `Retry-After`; raise `WaveDelaySeconds` |
| Branch count mismatch (WARN) | Usually stale ADO refs; compare `git ls-remote` on both sides |
| `git-sizer` limits not detected | The migration script cannot see per-file limits — run `Get-ADOInventory.ps1 -RunGitSizer` first |

## 14. Quick Reference — Run Commands

```powershell
# 1. Dry run, selected list
./Invoke-GHEMigration.ps1 -Mode Selected -RepoListFile ./repos.csv -AdoOrg O -AdoProject P -GitHubOrg G -DryRun
# 2. Production, selected list
./Invoke-GHEMigration.ps1 -Mode Selected -RepoListFile ./repos.csv -AdoOrg O -AdoProject P -GitHubOrg G
# 3. Single repo
./Invoke-GHEMigration.ps1 -Mode Single -RepoName app-service-1 -AdoOrg O -AdoProject P -GitHubOrg G
# 4. Everything, idempotent
./Invoke-GHEMigration.ps1 -Mode All -AdoOrg O -AdoProject P -GitHubOrg G -SkipExistingRepos
# 5. Resume an interrupted run
./Invoke-GHEMigration.ps1 -Mode All -AdoOrg O -AdoProject P -GitHubOrg G -ResumeFromState ./migration-output/migration-state-20260729-090000.json
# 6. Force through active PRs with verbose ado2gh output
./Invoke-GHEMigration.ps1 -Mode Single -RepoName app-service-2 -AdoOrg O -AdoProject P -GitHubOrg G -ForceWithActivePrs -VerboseMigration
# 7. Config-file driven (CI)
./Invoke-GHEMigration.ps1 -Mode Selected -ConfigFile ./migration.config.json -RepoListFile ./repos.csv
# 8. Audit only
./Invoke-GHEMigration.ps1 -Mode All -AdoOrg O -AdoProject P -GitHubOrg G -DryRun -SkipBranchVerification -SkipPostConfig
```
