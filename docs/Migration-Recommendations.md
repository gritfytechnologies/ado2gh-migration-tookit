# Migration Recommendations — Operational Guidance

## Section 1 — Assessment of the Migration Script

**What works well**

- Logging system: timestamped, levelled console + file logging, plus HTML
  dashboard and report for non-engineering stakeholders.
- Wave/parallel execution: RunspacePool with configurable wave size and
  concurrency, plus inter-wave delays for rate-limit safety.
- State persistence: per-wave JSON state enables clean resume after
  interruption without re-migrating completed repos.
- Pre-migration audit: active PRs, size risk, branch counts exported as CSV +
  HTML before anything is written to GitHub.
- Tool choice: `gh ado2gh` is the correct engine for ADO → GHEC (note: `gh gei`
  is GitHub-to-GitHub only).

**Bugs fixed in v2.1.0**

| Bug | Impact | Fix Applied |
|-----|--------|-------------|
| `$args` collision in `Build-GeiArgs` | Corrupt argument arrays | Renamed to `$adoArgs` |
| `$args` collision in `Invoke-GitHubApi` | Same | Renamed to `$apiArgs` |
| `EndInvoke` returned `PSDataCollection` | False success reporting | `$result[0]` with null guard |
| Bare `gh api` in PostMigrationConfig | Silent failures | `& $Script:GhCmd api` |
| Missing `@()` wrappers | Wrong wave count | Added throughout |
| `$env:GH_TOKEN` not set | Auth failures | Set alongside `$env:GH_PAT` |

**New features in v2.1.0:** `Test-GitHubPatPermissions` pre-flight check,
`Test-GitHubRepoExists` idempotency, migration log download, `workflow` scope
documentation, `VerboseMigration` switch, `Invoke-WithRetry` helper,
`SkipExistingRepos` switch, `Skipped` counter in `$Script:Stats`.

## Section 2 — Is This Ready for 100 Repos?

**Yes — with operational procedure.** The engine scales; the risk is process.

What you must do first: run under a dedicated service account; complete a full
`-DryRun`; run `Get-ADOInventory.ps1 -RunGitSizer` and review the audit; resolve
every BLOCKED repo per the remediation plan; schedule production waves during
off-hours; and hold a rollback plan (targets are freshly created — deleting a
failed target and re-running is safe).

What still needs manual work afterwards: mannequin reclaim, pipeline
reconnection (`4_Rewire-Pipeline.ps1`), developer remote updates
(`Update-DevRemote.ps1`), and a branch-protection review per repo class.

## Section 3 — Service Account Requirements

**Why:** EMU accounts carry platform restrictions that interfere with GEI
(migrator role and API behaviors), and running under a personal account creates
audit-attribution problems and PAT-expiry risk mid-program.

**Service account specification**

| Property | Value |
|---|---|
| Account type | Regular GitHub.com account (NOT EMU) |
| Username | `<service-account-username>` |
| Org role | Owner in `<github-org>` |
| PAT scopes | `repo admin:org workflow delete_repo` |
| SSO | PAT authorized for the org's SSO |
| 2FA | Enabled (hardware key or TOTP) |
| Secret storage | Azure Key Vault, referenced by the `<ado-variable-group>` variable group |

## Section 4 — Pre-Production Checklist

- [ ] Dry-run completed and log reviewed
- [ ] Audit dashboard reviewed; risk accepted for LARGE+ repos
- [ ] All BLOCKED repos remediated and re-verified with git-sizer
- [ ] Service account created per Section 3
- [ ] PATs stored in Azure Key Vault
- [ ] `<ado-variable-group>` variable group configured (GH_PAT, ADO_PAT)
- [ ] Communication sent to repo owners (freeze window, PR closure ask)
- [ ] Maintenance window scheduled
- [ ] Rollback plan defined (delete target repo + re-run procedure)
- [ ] State backup location identified for migration-state JSON files
- [ ] Mannequin CSV generation planned for immediately post-wave
- [ ] `Update-DevRemote.ps1` distribution plan ready
