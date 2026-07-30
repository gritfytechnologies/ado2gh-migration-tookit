# Self-Service Migration Pipeline — Setup & Usage

## 1. Architecture Overview

```
┌─────────────────────┐   ┌──────────────────────────┐   ┌───────────────┐
│ 1 Prerequisite      │──>│ 2 Readiness Check        │──>│ 3 Migration   │
│   Validation        │   │   + ManualValidation@0   │   │   (waves)     │
│ tools, PATs, config │   │   ██ APPROVAL GATE ██    │   │               │
└─────────────────────┘   └──────────────────────────┘   └───────┬───────┘
                                                                 │ dryRun=false
                             ┌──────────────────────────┐   ┌────▼──────────┐
                             │ 5 Pipeline Rewiring      │<──│ 4 Post-Migr.  │
                             │   (skippable)            │   │   Validation  │
                             └──────────────────────────┘   └───────────────┘
```

## 2. One-Time Setup

1. **Variable group:** ADO → Pipelines → Library → `+ Variable group` named
   `<ado-variable-group>`. Add secrets:
   - `GH_PAT` — scopes: `repo`, `admin:org`, `workflow`, `delete_repo`
   - `ADO_PAT` — scopes: Code (Read), Project & Team (Read), Build (Read & execute), Work Items (Read)
   Mark both as secret. **Expiry: max 90 days per your organization's PAT
   rotation policy** — set a calendar reminder.
2. Link the group to Key Vault if PATs live there.
3. Authorize the variable group for the pipeline on first run.

## 3. Register the Pipeline in ADO

1. Pipelines → **New pipeline**
2. **Azure Repos Git** → select this toolkit repository
3. **Existing Azure Pipelines YAML file**
4. Path: `/pipeline/ado2gh-self-service.yml` → Continue → **Save** (don't run yet)
5. Rename to `ADO2GH Self-Service Migration`

## 4. Input Files

**repos.csv** (Selected mode):

| Column | Description |
|---|---|
| AdoRepo | Source repo in ADO |
| GitHubRepo | Target repo name |
| Lfs | yes/no (informational) |

**migration.config.json:** `AdoOrg`, `AdoProject`, `GitHubOrg` must be real
values (placeholders fail Stage 1). PAT fields are ignored — the pipeline
always injects PATs from the variable group.

**pipelines.csv** (Stage 5):

| Column | Description |
|---|---|
| org / teamproject / repo / pipeline | ADO coordinates |
| github_org / github_repo | Target coordinates |
| serviceConnection | Real GUID — placeholders abort Stage 5 |

## 5. Pipeline Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| migrationMode | string | Selected | All / Single / Selected |
| singleRepoName | string | (blank) | Repo for Single mode |
| dryRun | boolean | **true** | Simulate only — always run true first |
| waveSize | number | 5 | Repos per wave |
| concurrentJobs | number | 3 | Parallel migrations (keep ≤ 5) |
| skipRewiring | boolean | false | Skip Stage 5 |
| useSelfHostedAgent | boolean | false | Use a self-hosted pool |
| selfHostedAgentPool | string | Default | Pool name when self-hosted |

## 6. Running the Pipeline

**First run (dry run):** Run pipeline → keep `dryRun = true` → approve the
gate → review the `migration-output` artifact (audit dashboard, dry-run log).
Stages 4–5 are skipped automatically for dry runs.

**Production run:** re-run with `dryRun = false`. Approve the gate only after
confirming the dry-run artifacts were clean. Stages 4 and 5 execute after
migration succeeds.

**Single repo:** `migrationMode = Single`, `singleRepoName = app-service-1`.

## 7. Stage Reference

| Stage | What it does | Approval |
|---|---|---|
| 1 PrerequisiteValidation | Installs gh + ado2gh, validates PATs and config | none |
| 2 MigrationReadinessCheck | Counts active PRs + running builds; ManualValidation gate | **Manual (24h timeout, auto-reject)** |
| 3 Migration | Runs Invoke-GHEMigration.ps1; writes repos_with_status.csv via GitHub API | none |
| 4 PostMigrationValidation | Verifies repos, default branch, protection (dryRun=false only) | none |
| 5 PipelineRewiring | Runs 4_Rewire-Pipeline.ps1 (dryRun=false, skipRewiring=false) | none |

## 8. Artifacts

| Artifact | Contents | Published |
|---|---|---|
| migration-output | log, HTML report, state JSON, audit CSVs/dashboard, repos_with_status.csv | Always (even on failure) |
| validation-output | post-migration verification output | Always, Stage 4 runs |
| rewiring-output | pipeline-rewiring-*.txt logs | Always, Stage 5 runs |

## 9. Credentials & Security

PATs flow: Key Vault / variable group → pipeline `env:` → script environment →
SecureString inside `Invoke-GHEMigration.ps1`. They are never echoed, never
written to artifacts, and never read from `migration.config.json` in pipeline
runs. `repos_with_status.csv` is built by querying the GitHub API — not by
parsing internal state files.

## 10. Troubleshooting

| Symptom | Fix |
|---|---|
| `GH_PAT missing from variable group` | Add the secret to `<ado-variable-group>` and authorize the group for this pipeline |
| `Could not queue... variable group not authorized` | Pipeline → Edit → run once and click Authorize, or Library → group → Pipeline permissions |
| Stage 1 fails on config placeholders | Set real `AdoOrg`/`AdoProject`/`GitHubOrg` in migration.config.json |
| Approval gate never appears | Stage 2 `WaitForApproval` uses `pool: server` — do not add an agent pool to that job |
| Gate auto-rejected | 24h timeout elapsed — re-run the pipeline |
| `workflow scope` error in Stage 3 | Regenerate GH_PAT with `workflow` scope |
| `Repository already exists` | Expected on reruns — the script runs with `-SkipExistingRepos`; check the Skipped count |
| Stage 4 skipped unexpectedly | It only runs when `dryRun=false` AND Migration succeeded |
| Stage 5 aborts on placeholders | Fill real service connection GUIDs in pipelines.csv |
| ado2gh install fails on agent | Egress to github.com blocked — use a self-hosted agent with access or pre-bake the extension |
| Hosted agent 6h timeout on large repos | Use `useSelfHostedAgent=true` (job timeout is set to 12h) |

## 11. FAQ

**Q: Can I run only the rewiring stage?**
A: Run with a repos.csv containing already-migrated repos and `dryRun=false`;
Migration skips them (`-SkipExistingRepos`) and Stage 5 rewires from
repos_with_status.csv. For ad-hoc rewiring, run `4_Rewire-Pipeline.ps1` locally.

**Q: What happens if the run is cancelled mid-migration?**
A: State JSON is in the `migration-output` artifact. Resume locally with
`-ResumeFromState`, or simply re-run the pipeline — `-SkipExistingRepos` makes
reruns idempotent.

**Q: Why is dryRun default true?**
A: Toolkit safety convention: always dry-run before any real migration.

**Q: Who should approve the Stage 2 gate?**
A: The migration lead, after reviewing readiness output and prior dry-run
artifacts. Configure `notifyUsers` in the YAML with the approver group.

**Q: Do work items/boards migrate?**
A: No — Git repos only. Pipelines stay in ADO and are rewired to GitHub source.
