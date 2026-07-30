# GitHub Policy Toolkit — Audit + Remediate

## 1. Overview

- **`Invoke-GitHubAudit.ps1`** — reads org, enterprise, and repository security
  settings and grades each against policy (PASS/FAIL/WARN), writing
  `github_audit_report.json`.
- **`Invoke-GitHubRemediate.ps1`** — consumes that report and applies fixes via
  the GitHub API, with full `ShouldProcess`/`-WhatIf` support.

Audit is read-only; remediation changes settings. Always audit → review → remediate.

## 2. Prerequisites

PowerShell 5.1+ (7 recommended), gh CLI authenticated (`gh auth login` or
`GH_TOKEN`), jq. Tool resolution order: `-ToolsPath` → script folder → current
directory → PATH (drop `gh.exe`/`jq.exe` beside the script on locked-down hosts).

## 3. PAT Scopes by Operation

| Operation | Scopes |
|---|---|
| Org-level audit | `read:org` |
| Enterprise-level audit | `read:enterprise`, `admin:org` |
| Repo-level audit | `repo` |
| Org remediation | `admin:org` |
| Repo remediation | `repo` (admin permission on the repo) |

## 4. Quick Start

```powershell
# 1. Audit
./Invoke-GitHubAudit.ps1 -OrgName <github-org> -MaxRepos 20
# 2. Review
code ./github_audit_report.json   # or open the console output
# 3. Remediate (interactive menu of failures)
./Invoke-GitHubRemediate.ps1 -OrgName <github-org> -ReportPath ./github_audit_report.json
```

## 5. Audit Output

Console: colored `[PASS]`/`[FAIL]`/`[WARN]` lines per check with actual vs
expected values. JSON schema:

```json
{
  "org": "<github-org>",
  "timestamp": "2026-07-29T...",
  "org_checks":        { "policy_name": { "status": "PASS|FAIL|WARN", "value": "...", "expected": "..." } },
  "enterprise_checks": { "...": { } },
  "repo_checks":       [ { "repo": "...", "checks": { "...": { } } } ],
  "summary":           { "total_checks": 0, "passed": 0, "failed": 0, "warnings": 0 }
}
```

## 6. Remediation Modes

| Invocation | Behavior |
|---|---|
| *(no params)* | Interactive menu of audit failures from `-ReportPath` |
| `-Policy <name>` | Apply one policy |
| `-Scope org\|repo\|all` | Apply every policy at that scope |
| `-WhatIf` | Print intended changes, zero API calls |
| `-Force` | Suppress per-change confirmation |
| `-RepoName` / `-AllRepos` | Target selection for repo-scoped policies |

## 7. Remediable Policies

| Policy | Why it matters | API call |
|---|---|---|
| `two_factor_requirement_enabled` | Account-takeover defense for all members | `PATCH /orgs/{org}` `two_factor_requirement_enabled=true` |
| `default_repository_permission` | Least privilege — no implicit read/write | `PATCH /orgs/{org}` `default_repository_permission=none` |
| `members_can_create_repositories` | Central governance of repo sprawl | `PATCH /orgs/{org}` `members_can_create_repositories=false` |
| `members_can_create_public_repositories` | Prevents accidental code exposure | `PATCH /orgs/{org}` `members_can_create_public_repositories=false` |
| `members_can_fork_private_repositories` | Keeps private code inside the org | `PATCH /orgs/{org}` `members_can_fork_private_repositories=false` |
| `dependabot_alerts` | Vulnerability visibility on new repos | `PATCH /orgs/{org}` `dependabot_alerts_enabled_for_new_repositories=true` |
| `secret_scanning` | Credential-leak detection on new repos | `PATCH /orgs/{org}` `secret_scanning_enabled_for_new_repositories=true` |
| `branch_protection` | Review gates, no force-push/delete on default branch | `PUT /repos/{org}/{repo}/branches/{branch}/protection` |
| `vulnerability_alerts` | Per-repo Dependabot alerts | `PUT /repos/{org}/{repo}/vulnerability-alerts` |
| `disable_actions` | Shrink attack surface on repos not using CI | `PUT /repos/{org}/{repo}/actions/permissions` `enabled=false` |

## 8. Troubleshooting

- **EMU enterprises:** several org-management settings are controlled at the
  enterprise/IdP layer; org-level PATCH calls may 403 or be no-ops. Expected —
  manage them in enterprise settings / Entra ID instead.
- **`insufficient permissions` on enterprise checks:** the PAT lacks
  `read:enterprise` or the account is not an enterprise admin. Run with
  `-SkipEnterprise` or use an enterprise-admin PAT.
- **2FA enforcement fails:** cannot enable while members without 2FA exist —
  GitHub lists them; off-board or get them enrolled first.
- **Secret scanning FAILs on private repos:** requires GHAS licensing for
  private repositories.
