# 4_Rewire-Pipeline.ps1 — Usage Guide

## 1. What It Does

After a repo migrates to GitHub, its ADO build pipelines still point at the old
Azure Repos source. This script repoints them via:

```powershell
gh ado2gh rewire-pipeline `
    --ado-org               <org> `
    --ado-team-project      <project> `
    --ado-pipeline          <pipeline-name> `
    --github-org            <github-org> `
    --github-repo           <github-repo> `
    --service-connection-id <guid>
```

The pipeline definition itself (stages, tasks, triggers) is untouched — only
its repository source changes to GitHub via the service connection.

## 2. Prerequisites

| Requirement | Notes |
|---|---|
| PowerShell 7.0+ | Cross-platform |
| gh CLI 2.30+ | Authenticated (`GH_PAT`/`GH_TOKEN`) |
| gh-ado2gh extension | `gh extension install github/gh-ado2gh` |
| GitHub Pipelines App | Installed on the target GitHub org (section 8) |
| GitHub service connection | Created in the ADO project (section 9) |
| `ADO_PAT` | Build (Read & execute) scope |
| `GH_PAT` | repo + workflow scopes |

## 3. pipelines.csv Format

| Column | Required | Description |
|---|---|---|
| `org` | yes | ADO organization |
| `teamproject` | yes | ADO project |
| `repo` | yes | ADO repo the pipeline builds |
| `pipeline` | yes | Exact pipeline name (leading `\` is trimmed) |
| `github_org` | yes | Target GitHub org |
| `github_repo` | yes | Target GitHub repo |
| `serviceConnection` | yes | Service connection GUID — no placeholders |
| `url` | no | Informational link to the pipeline |

```csv
org,teamproject,repo,pipeline,github_org,github_repo,serviceConnection
<ado-org>,<ado-project>,app-service-1,app-service-1-CI,<github-org>,app-service-1,<service-connection-guid>
```

## 4. repos_with_status.csv Format

Generated post-migration (by the self-service pipeline via the GitHub API).

| Column | Description |
|---|---|
| `RepoName` | Repository name |
| `MigrationStatus` | `Success` rows gate rewiring |

Only pipelines whose repo has `MigrationStatus = Success` are rewired. Use
`-SkipStatusCheck` when running ad-hoc without the status file (e.g. you
verified migration manually).

## 5. Usage Examples

```powershell
# Everything in pipelines.csv (gated by status file)
./4_Rewire-Pipeline.ps1

# Only specific repos
./4_Rewire-Pipeline.ps1 -SelectedRepos app-service-1,app-service-2

# Only specific pipelines
./4_Rewire-Pipeline.ps1 -SelectedPipelines 'app-service-1-CI'

# Preview without changing anything
./4_Rewire-Pipeline.ps1 -DryRun

# Inline single-repo mode (no CSVs needed)
./4_Rewire-Pipeline.ps1 -AdoOrg <ado-org> -AdoProject <ado-project> `
    -RepoName app-service-1 -GitHubOrg <github-org> -GitHubRepo app-service-1 `
    -ServiceConnectionId 11112222-3333-4444-5555-666677778888
```

## 6. Placeholder Validation

The script **aborts the entire run** if any `serviceConnection` value is
`your-service-connection-id`, `placeholder`, `TODO`, `TBD`, `xxx`, or empty.
This prevents partially rewiring pipelines against a nonexistent connection.

## 7. Output

Colored end-of-run summary: Succeeded / Failed / Skipped (filter) / Already
rewired / Dry-run skipped counts, plus the log file path:
`pipeline-rewiring-{timestamp}.txt` in `-LogDirectory` (default: cwd).
Exit code 1 when any rewire failed.

## 8. Setting Up the GitHub Pipelines App

1. In ADO: Project Settings → Service connections → New → **GitHub**.
2. Choose **Azure Pipelines app** (OAuth/App flow, not PAT) and authorize.
3. On GitHub: Settings → Applications → **Azure Pipelines** → grant access to
   the target org (or specific repos).
4. Org owners approve the installation if third-party app policy requires it.

## 9. Getting the Service Connection GUID

ADO → Project Settings → Service connections → open the GitHub connection →
the GUID is the `resourceId` in the page URL:
`.../_settings/adminservices?resourceId=<GUID>`.

## 10. Troubleshooting

| Symptom | Fix |
|---|---|
| `No service connection found` | GUID wrong or connection lives in a different project — recopy from the URL |
| `rewire-pipeline is not a command` | gh-ado2gh outdated — `gh extension upgrade ado2gh` |
| Pipeline still builds from ADO | Definition may have hardcoded `repository` resources — inspect the YAML; also confirm you rewired the right pipeline (names must match exactly, including folders) |
| `pipeline not found` | Pipeline name includes a folder path — use the exact display name; leading `\` is trimmed automatically |
| Auth errors | Re-export `ADO_PAT`/`GH_PAT`; GH_TOKEN is set automatically by the script |
