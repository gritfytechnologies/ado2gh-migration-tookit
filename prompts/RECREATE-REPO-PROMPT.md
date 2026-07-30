# AI Recreation Prompt — GitHub Enterprise Migration Toolkit

**Purpose:** This file holds the canonical AI recreation prompt for the
`github-enterprise-migration-toolkit` repository. Pasting the prompt into any
capable AI (Claude Sonnet 4.5+, GitHub Copilot Workspace, GPT-4o) recreates the
repository from scratch — every script, every doc, every config, complete logic.

**Repo:** `<github-org>/github-enterprise-migration-toolkit`
**Classification:** Internal — Platform Engineering

---

> **NOTE:** Paste the full canonical recreation prompt (the version used to
> generate this repository, with the `═══ BEGIN PROMPT ═══` / `═══ END PROMPT ═══`
> markers and all 25 file specifications) below this line. Keep this file in
> sync whenever the toolkit changes: any new script, parameter, bug fix, or
> doc section must be reflected in the corresponding File-N section of the
> prompt, and the version number bumped alongside `$Script:VERSION`.

## How to Use This Prompt

1. Open a new AI conversation (Claude Sonnet 4.5+, Copilot Workspace, or GPT-4o)
2. Paste everything between `═══ BEGIN PROMPT ═══` and `═══ END PROMPT ═══`
3. If the AI truncates, follow up: *"Continue from [File N] — full implementation required"*
4. After generation: replace all `<placeholder>` values, run `Invoke-GHEMigration.ps1 -DryRun`
5. Validate project standards: `#Requires -Version 7.0`, `Set-StrictMode`, `$ErrorActionPreference`

## Validation Checklist After Generation

- [ ] `#Requires -Version 7.0` at top of every `.ps1` file
- [ ] `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` in every script
- [ ] `[SecureString]` for `AdoPat`, `GitHubPat` in `Invoke-GHEMigration.ps1`
- [ ] `$adoArgs` used (not `$args`) in `Build-AdoArgs` / `Build-GeiArgs`
- [ ] `$apiArgs` used (not `$args`) in `Invoke-GitHubApi`
- [ ] RunspacePool used for concurrency (not `Start-Job` / `Wait-Job`)
- [ ] `EndInvoke()` result extracted via `$result[0]` with null guard
- [ ] `& $Script:GhCmd api` used (not bare `gh api`) in all GitHub API calls
- [ ] `$env:GH_TOKEN` set alongside `$env:GH_PAT` in `Resolve-Credentials`
- [ ] `Skipped` counter present in `$Script:Stats` alongside Total/Succeeded/Failed/Warnings
- [ ] `SkipExistingRepos` and `VerboseMigration` switches present
- [ ] `Invoke-WithRetry` helper function implemented
- [ ] `Test-GitHubPatPermissions` implemented (tests createMigrationSource GraphQL mutation)
- [ ] HTML audit dashboard generated in `audit/audit-dashboard-{RunId}.html`
- [ ] PAT values never appear in any log output
- [ ] All 25 files generated
