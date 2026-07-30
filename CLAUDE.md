# CLAUDE.md — GitHub Enterprise Migration Toolkit
# Read this file before any task in this repository.

## Project Identity
- Name: Enterprise GitHub Migration Toolkit
- Repo: github-enterprise-migration-toolkit (GitHub: <github-org>)
- Owner: Platform Engineering
- Version: v2.7.0 (Invoke-GHEMigration.ps1) — merges the upstream "GitHub Migration" v2.6.0 feature set (LFS verify/fallback, tag+SHA verification, custom properties, resumable state restore) while keeping this repo's toolkit-only features (Write-MannequinGuide, audit dashboard, HTML report, pipeline guide)
- Classification: Internal — do not share outputs externally

## What This Project Does
Migrates Git repositories from Azure DevOps (ADO) to GitHub Enterprise (GHE).
SCOPE: Git repos ONLY. ADO Pipelines remain in ADO and are reconnected via
GitHub Service Connections. Work items, boards, wikis are NOT touched.

## Source & Target Systems
- ADO Org:        <ado-org>
- ADO Project:     <ado-project>
- GitHub Org:      <github-org>
- GitHub Team:     <github-team>
- GH Svc Conn:     <gh-service-connection>
- ADO Var Group:   <ado-variable-group> (GH_PAT, ADO_PAT)

## Tech Stack
- Language:      PowerShell — version floor is NOT uniform across scripts/:
                 7.0 (Invoke-GHEMigration.ps1, 4_Rewire-Pipeline.ps1),
                 7.2 (Invoke-GHActionsImporterMigration.ps1 — uses ForEach-Object -Parallel),
                 5.1 (Get-ADOInventory.ps1, Invoke-GitHubAudit.ps1, Invoke-GitHubRemediate.ps1)
- Language:      Python 3.11+ (adogap gap-filler, optional — tools/adogap/, classic release pipelines only)
- Migration CLI:  GitHub Enterprise Importer (gh ado2gh extension)
- Pipeline CLI:   gh actions-importer extension (ADO Pipelines -> GitHub Actions)
- Concurrency:    RunspacePool (NOT Start-Job) for Invoke-GHEMigration.ps1
- ADO API:        Direct REST (Invoke-RestMethod + Get-AdoAuthHeader) in Invoke-GHEMigration.ps1; Azure CLI (az) with azure-devops extension elsewhere
- GitHub API:     gh CLI + REST API + GraphQL (for migration source test)
- Output format:  CSV (audit), JSON (state), HTML (report + dashboard)
- Local binary cache: bin/ (gh, jq, git-sizer) — resolved by Resolve-LocalTools before PATH lookup fails; gitignored except bin/.gitkeep

## File Map
- Invoke-GHEMigration.ps1               Main script — 13 #regions, 8 phases (+5b LFS)
- 4_Rewire-Pipeline.ps1                 ADO pipeline rewiring (gh ado2gh rewire-pipeline)
- Get-ADOInventory.ps1                  Excel workbook (8 sheets), git-sizer, GEI + Actions Importer readiness
- Invoke-GHActionsImporterMigration.ps1 ADO build/release pipelines -> GitHub Actions (gh actions-importer)
- Invoke-GitHubAudit.ps1                GitHub security audit (org/enterprise/repo)
- Invoke-GitHubRemediate.ps1            Apply GitHub policy remediations
- tools/adogap/                         Python — fills approvals/gates/service-connection/secrets gap gh actions-importer leaves for classic release pipelines
- migration.config.json        Config template — never commit PATs
- repos.csv                    AdoRepo,GitHubRepo,Lfs (Selected-mode input)
- pipelines.csv                org,teamproject,repo,pipeline,github_org,github_repo,serviceConnection
- config/branch-protection.json  Post-migration branch protection policy
- pipeline/ado2gh-self-service.yml  5-stage ADO self-service pipeline

## Script Architecture — 8 Phases (+5b)
- Phase 1: VALIDATION       — Tools, versions, credentials, PAT permission test
- Phase 2: DISCOVERY        — Repo enumeration (All/Single/Selected), resume filter (Restore-MigrationState)
- Phase 3: AUDIT            — Active PRs, size/branch/tag inventory, risk, audit HTML dashboard, LFS disk-space estimate
- Phase 4: MIGRATION        — Wave-based RunspacePool parallel execution, state persistence, per-repo SHA/branch/tag validation (Invoke-PerRepoValidation, unless -SkipPerRepoValidation)
- Phase 5: VERIFICATION     — Branch + tag count ADO ↔ GitHub per repo (Invoke-RepoVerification)
- Phase 5b: LFS VERIFICATION — Clone + `git lfs ls-files` check and interactive fallback push, only when -IncludeLfs and not -SkipLfsVerification
- Phase 6: POST-CONFIG      — Branch protection, team access, default branch rename, GitHub custom properties (-CustomProperties / -SetAdoMetadata), ado2gh diagnostic log download
- Phase 7: PIPELINE GUIDE   — YAML update snippets, Update-DevRemote.ps1, mannequin guide
- Phase 8: REPORT           — HTML migration report, final state JSON

## Critical Parameters
- -Mode                All | Single | Selected (REQUIRED)
- -AdoOrg               <ado-org> (REQUIRED)
- -AdoProject           <ado-project> (REQUIRED)
- -GitHubOrg            <github-org> (REQUIRED)
- -AdoPat               SecureString — NEVER log
- -GitHubPat            SecureString — NEVER log
- -RepoName             Single mode only
- -RepoListFile         Selected mode — path to repos.csv
- -WaveSize             Repos per wave (default 10, 0=unlimited)
- -ConcurrentJobs       RunspacePool workers 1-10 (default 3)
- -WaveDelaySeconds     Pause between waves (default 30s)
- -DryRun               Validate only, no writes — ALWAYS RUN FIRST
- -SkipExistingRepos    Skip repos already on GitHub (idempotency)
- -VerboseMigration     Pass --verbose to gh ado2gh
- -ForceWithActivePrs   Warn but do not block on active PRs
- -ResumeFromState      Path to migration-state JSON
- -ServiceConnectionName ADO GitHub service connection name (default github-app-service-connection)
- -CustomProperties     Hashtable of GitHub custom properties applied post-migration
- -SetAdoMetadata       Also stamp ado-origin-org/project/repo as custom properties
- -SkipLfsVerification  Skip Phase 5b even when -IncludeLfs is set
- -SkipPerRepoValidation Skip per-repo HEAD-SHA/branch/tag validation in Phase 4

## The 13 #region Blocks
1.  CONSTANTS & GLOBALS         $Script: scope, RUN_ID, Stats (Total/Succeeded/Failed/Skipped/Warnings), AuditResults, ValidationResults, LfsDisk*
2.  LOGGING                     Write-Log, Write-Section, Write-Step
3.  INITIALISATION              Initialize-Environment, Resolve-LocalTools (bin/), Import-ConfigFile
4.  CREDENTIAL HELPERS          Get-PlainPat, Resolve-Credentials
5.  PREREQUISITES CHECK         Test-Prerequisites, Test-GitHubPatPermissions
6.  ADO HELPERS                 Get-AdoRepos, Get-AdoActivePrs, Get-AdoBranchCount, Get-AdoTagCount, Get-AdoDefaultBranchSha
7.  GITHUB HELPERS              Invoke-GitHubApi ($apiArgs!), Test-GitHubRepoExists, Get-GitHubBranchCount/TagCount/HeadSha, Set-GitHubDefaultBranch, Set-BranchProtection, Grant-TeamAccess, Initialize-CustomPropertySchema, Set-RepoCustomProperties, Invoke-WithRetry
8.  PRE-MIGRATION AUDIT         Invoke-PreMigrationAudit → audit CSV, active-prs CSV, HTML dashboard, LFS disk-space estimate
9.  REPO LIST RESOLUTION        Resolve-RepoList (All/Single/Selected + resume filter via Restore-MigrationState + SkipExistingRepos)
10. GEI MIGRATION               Build-AdoArgs ($adoArgs!), Invoke-PerRepoValidation, Invoke-SingleMigration, Invoke-WaveMigration (RunspacePool)
11. BRANCH + TAG VERIFICATION   Invoke-RepoVerification (bulk), Invoke-BranchVerification (Phase 5 wrapper) → repo-verification CSV
12. LFS VERIFICATION            Get-AvailableDiskSpaceGB, Invoke-LfsVerification, Invoke-LfsFallbackPush, Invoke-LfsPhase (Phase 5b)
13. POST-MIGRATION CONFIG       Invoke-PostMigrationConfig, Invoke-DownloadMigrationLogs, Write-PipelineGuide, Write-MannequinGuide, Write-HtmlReport, Save-MigrationState

## Conventions — Always Follow
- NEVER echo, log, or return a PAT value — always SecureString or $env:
- ALWAYS run -DryRun before any real migration
- ALWAYS check for active PRs before migrating (audit phase does this)
- Use $adoArgs (not $args) in Build-AdoArgs — $args is a PowerShell automatic variable
- Use $apiArgs (not $args) in Invoke-GitHubApi — same reason
- EndInvoke() returns PSDataCollection — extract via $result[0] with null guard
- All gh api calls use & $Script:GhCmd api (not bare 'gh api') for path portability
- GH_TOKEN must be set alongside GH_PAT for gh CLI internal auth
