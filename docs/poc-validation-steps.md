# POC Validation Steps & Post-Migration Checklist

## Part 1 — Already Validated (POC Results)

| Test | Result |
|---|---|
| Small repo: `app-service-1` (115 MB) — migrated in 2.2 min | ✅ |
| Large repo: `app-service-4` (953 MB) — migrated in 62 min | ✅ |
| `createMigrationSource` permission flow (migrator role + PAT) | ✅ |
| `workflow` PAT scope requirement discovered and documented | ✅ |
| Branch count verification — 23 branches matched ADO ↔ GitHub | ✅ |
| Post-migration "migration in progress" banner clearing | ✅ |

## Part 2 — Remaining Tests

### Test 1 — Active PR Migration (ForceWithActivePrs)

Repo: `app-service-2` (1 active PR).

```powershell
./scripts/Invoke-GHEMigration.ps1 -Mode Single -RepoName app-service-2 `
    -AdoOrg <ado-org> -AdoProject <ado-project> -GitHubOrg <github-org> `
    -ForceWithActivePrs
```

Verify: PR history present as read-only mannequin-attributed items; all
branches exist; commit SHAs match; mannequin CSV can be generated afterwards.

### Test 2 — Idempotency (SkipExistingRepos)

Re-run Test 1's command with `-SkipExistingRepos` against the already-migrated
repo. Expected: `SKIP — app-service-2 already exists on GitHub` in the log,
exit without error, no duplicate repo, `Skipped` counter = 1.

### Test 3 — Resume from State

Start a Selected-mode run of 3+ repos, kill the process mid-wave, then:

```powershell
./scripts/Invoke-GHEMigration.ps1 -Mode Selected -RepoListFile ./repos.csv `
    -AdoOrg <ado-org> -AdoProject <ado-project> -GitHubOrg <github-org> `
    -ResumeFromState ./migration-output/migration-state-<RUNID>.json
```

Verify: Completed repos are filtered out, failed repos retried, the new state
file reflects the union of both runs.

### Test 4 — Mannequin Reclaim

```powershell
gh ado2gh generate-mannequin-csv --github-org <github-org> --output mannequins.csv
# edit: fill target-user column for each mannequin
gh ado2gh reclaim-mannequin --github-org <github-org> --csv mannequins.csv
```

Verify: commit history in a migrated repo shows the real GitHub user after the
attribution invitation is accepted.

### Test 5 — All-Mode Migration (wave test)

5 repos, `-WaveSize 2 -ConcurrentJobs 2`. Verify: 3 waves execute in order
(2+2+1), `WaveDelaySeconds` pause observed between waves in the log timestamps,
all 5 repos migrated, state saved after each wave.

### Test 6 — Pipeline Self-Service (ADO pipeline test)

Register `pipeline/ado2gh-self-service.yml` as a new ADO pipeline. Run with
`dryRun=true`. Verify: all 5 stages execute, the ManualValidation approval gate
appears in Stage 2, and artifacts publish even on early failure
(`condition: always()`).

## Part 3 — Post-Migration Verification Checklist

- [ ] Git commit count matches (use validation script)
- [ ] Default branch renamed to `main`
- [ ] Branch protection rules applied on `main`
- [ ] `<github-team>` team has push access
- [ ] ADO pipeline runs successfully against GitHub repo
- [ ] Developer can `git pull` from new GitHub remote
- [ ] No mannequins in commit history (or mannequin reclaim completed)
- [ ] `migration-output/` HTML report shows 100% success
