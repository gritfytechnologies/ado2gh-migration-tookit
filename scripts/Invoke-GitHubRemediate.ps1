#Requires -Version 5.1
<#
.SYNOPSIS
    Applies GitHub security policy remediations flagged by Invoke-GitHubAudit.ps1.

.DESCRIPTION
    Reads the audit JSON report and remediates failed policies via the GitHub
    API. Modes:

      No params            — interactive menu listing all audit failures
      -Policy {name}       — apply a single policy
      -Scope org|repo|all  — apply every policy at that scope
      -WhatIf              — print what would change, no API calls
      -Force               — suppress per-change confirmation

    All changes go through ShouldProcess, so -WhatIf/-Confirm behave natively.

.PARAMETER OrgName
    GitHub organization to remediate.

.PARAMETER ReportPath
    Path to github_audit_report.json from Invoke-GitHubAudit.ps1.

.PARAMETER Policy
    Single policy key to apply (see $AllPolicies).

.PARAMETER Scope
    Apply all policies at 'org', 'repo', or 'all' scope.

.PARAMETER RepoName
    Target repository for repo-scoped policies.

.PARAMETER AllRepos
    Apply repo-scoped policies to every repo in the org.

.PARAMETER Force
    Skip ShouldProcess confirmation prompts.

.EXAMPLE
    ./Invoke-GitHubRemediate.ps1 -OrgName contoso-gh
    Interactive menu of audit failures.

.EXAMPLE
    ./Invoke-GitHubRemediate.ps1 -OrgName contoso-gh -Policy two_factor_requirement_enabled -Force

.EXAMPLE
    ./Invoke-GitHubRemediate.ps1 -OrgName contoso-gh -Scope org -WhatIf

.NOTES
    Author  : Platform Engineering
    Version : 2.1.0
    Requires: PowerShell 5.1+, gh CLI authenticated with admin:org + repo scopes.
    Security: authentication via gh CLI session / GH_TOKEN — never logged.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $OrgName    = '<github-org>',
    [string] $ReportPath = '.\github_audit_report.json',
    [string] $Policy     = '',
    [ValidateSet('org', 'repo', 'all', '')] [string] $Scope = '',
    [string] $RepoName   = '',
    [switch] $AllRepos,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region HELPERS
function Write-RemLog {
    param([string] $Message, [ValidateSet('INFO','WARN','ERROR','SUCCESS')] [string] $Level = 'INFO')
    $color = switch ($Level) { 'INFO' { 'Cyan' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'SUCCESS' { 'Green' } }
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Invoke-GhChange {
    param([Parameter(Mandatory)][string[]] $GhArguments, [Parameter(Mandatory)][string] $Description)
    if ($WhatIfPreference) {
        Write-RemLog "WhatIf: would run -> gh $($GhArguments -join ' ')" -Level WARN
        return $true
    }
    $raw = (& gh @GhArguments 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        Write-RemLog "FAILED: $Description — $raw. Fix: ensure the PAT has admin:org (org policies) or repo admin (repo policies)." -Level ERROR
        return $false
    }
    Write-RemLog "APPLIED: $Description" -Level SUCCESS
    return $true
}

function Get-TargetRepos {
    if ($RepoName) { return @($RepoName) }
    if ($AllRepos) {
        $raw = (& gh api "/orgs/$OrgName/repos?per_page=100" --paginate --jq '.[].name' 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Could not list repos for '$OrgName'. Fix: check org name and PAT scopes. Detail: $raw" }
        return @($raw | Where-Object { $_ })
    }
    throw "Repo-scoped policy requires -RepoName <repo> or -AllRepos. Fix: specify the target repository/repositories."
}
#endregion

#region POLICY CATALOG
$AllPolicies = [ordered]@{
    'two_factor_requirement_enabled' = @{
        Description = 'Enforce two-factor authentication for all org members'
        Scope       = 'org'
        Action      = { Invoke-GhChange -Description 'Enforce 2FA' -GhArguments @('api', '-X', 'PATCH', "/orgs/$OrgName", '-F', 'two_factor_requirement_enabled=true') }
    }
    'default_repository_permission' = @{
        Description = "Set default repository permission to 'none'"
        Scope       = 'org'
        Action      = { Invoke-GhChange -Description "Default repo permission = none" -GhArguments @('api', '-X', 'PATCH', "/orgs/$OrgName", '-f', 'default_repository_permission=none') }
    }
    'members_can_create_repositories' = @{
        Description = 'Block member repository creation'
        Scope       = 'org'
        Action      = { Invoke-GhChange -Description 'Block member repo creation' -GhArguments @('api', '-X', 'PATCH', "/orgs/$OrgName", '-F', 'members_can_create_repositories=false') }
    }
    'members_can_create_public_repositories' = @{
        Description = 'Block public repository creation'
        Scope       = 'org'
        Action      = { Invoke-GhChange -Description 'Block public repo creation' -GhArguments @('api', '-X', 'PATCH', "/orgs/$OrgName", '-F', 'members_can_create_public_repositories=false') }
    }
    'members_can_fork_private_repositories' = @{
        Description = 'Block forking of private repositories'
        Scope       = 'org'
        Action      = { Invoke-GhChange -Description 'Block private repo forks' -GhArguments @('api', '-X', 'PATCH', "/orgs/$OrgName", '-F', 'members_can_fork_private_repositories=false') }
    }
    'dependabot_alerts' = @{
        Description = 'Enable Dependabot alerts for new repositories'
        Scope       = 'org'
        Action      = { Invoke-GhChange -Description 'Dependabot alerts for new repos' -GhArguments @('api', '-X', 'PATCH', "/orgs/$OrgName", '-F', 'dependabot_alerts_enabled_for_new_repositories=true') }
    }
    'secret_scanning' = @{
        Description = 'Enable secret scanning for new repositories'
        Scope       = 'org'
        Action      = { Invoke-GhChange -Description 'Secret scanning for new repos' -GhArguments @('api', '-X', 'PATCH', "/orgs/$OrgName", '-F', 'secret_scanning_enabled_for_new_repositories=true') }
    }
    'branch_protection' = @{
        Description = 'Apply default branch protection (1 review, dismiss stale, no force-push/delete)'
        Scope       = 'repo'
        Action      = {
            foreach ($repo in (Get-TargetRepos)) {
                $defBranch = (& gh api "/repos/$OrgName/$repo" --jq '.default_branch' 2>&1)
                if ($LASTEXITCODE -ne 0) { Write-RemLog "Skip '$repo' — cannot resolve default branch." -Level WARN; continue }
                $rules = @'
{
  "required_status_checks": { "strict": true, "contexts": [] },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false,
  "required_conversation_resolution": true
}
'@
                $tmp = Join-Path ([IO.Path]::GetTempPath()) "bp-$repo.json"
                Set-Content -LiteralPath $tmp -Value $rules -Encoding UTF8
                try {
                    Invoke-GhChange -Description "Branch protection on $repo@$defBranch" -GhArguments @('api', '-X', 'PUT', "/repos/$OrgName/$repo/branches/$defBranch/protection", '--input', $tmp) | Out-Null
                }
                finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            }
        }
    }
    'vulnerability_alerts' = @{
        Description = 'Enable vulnerability alerts'
        Scope       = 'repo'
        Action      = {
            foreach ($repo in (Get-TargetRepos)) {
                Invoke-GhChange -Description "Vulnerability alerts on $repo" -GhArguments @('api', '-X', 'PUT', "/repos/$OrgName/$repo/vulnerability-alerts") | Out-Null
            }
        }
    }
    'disable_actions' = @{
        Description = 'Disable GitHub Actions (for repos that do not use it)'
        Scope       = 'repo'
        Action      = {
            foreach ($repo in (Get-TargetRepos)) {
                Invoke-GhChange -Description "Disable Actions on $repo" -GhArguments @('api', '-X', 'PUT', "/repos/$OrgName/$repo/actions/permissions", '-F', 'enabled=false') | Out-Null
            }
        }
    }
}
#endregion

#region POLICY EXECUTION
function Invoke-Policy {
    param([Parameter(Mandatory)][string] $Key)
    if (-not $AllPolicies.Contains($Key)) {
        throw "Unknown policy '$Key'. Expected one of: $($AllPolicies.Keys -join ', '). Fix: use a valid policy key."
    }
    $entry = $AllPolicies[$Key]
    $target = if ($entry.Scope -eq 'org') { $OrgName } elseif ($RepoName) { "$OrgName/$RepoName" } else { "$OrgName (repos)" }
    if ($Force -or $PSCmdlet.ShouldProcess($target, $entry.Description)) {
        & $entry.Action
    }
}
#endregion

#region MODE DISPATCH
if ($Policy) {
    Invoke-Policy -Key $Policy
}
elseif ($Scope) {
    $keys = @($AllPolicies.Keys | Where-Object { $Scope -eq 'all' -or $AllPolicies[$_].Scope -eq $Scope })
    Write-RemLog "Applying $($keys.Count) policies at scope '$Scope'..."
    foreach ($k in $keys) { Invoke-Policy -Key $k }
}
else {
    # -- Interactive menu from audit report -------------------------------
    if (-not (Test-Path -LiteralPath $ReportPath)) {
        throw "Audit report not found at '$ReportPath'. Expected github_audit_report.json from Invoke-GitHubAudit.ps1. Fix: run the audit first or pass -ReportPath."
    }
    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json

    $failures = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($p in $report.org_checks.PSObject.Properties) {
        if ($p.Value.status -eq 'FAIL' -and $AllPolicies.Contains($p.Name)) {
            $failures.Add([PSCustomObject]@{ Key = $p.Name; Where = 'org'; Detail = "value=$($p.Value.value) expected=$($p.Value.expected)" })
        }
    }
    foreach ($rc in @($report.repo_checks)) {
        foreach ($p in $rc.checks.PSObject.Properties) {
            if ($p.Value.status -eq 'FAIL' -and $AllPolicies.Contains($p.Name)) {
                $failures.Add([PSCustomObject]@{ Key = $p.Name; Where = $rc.repo; Detail = "value=$($p.Value.value) expected=$($p.Value.expected)" })
            }
        }
    }

    if ($failures.Count -eq 0) {
        Write-RemLog 'No remediable failures found in the audit report. Nothing to do.' -Level SUCCESS
        return
    }

    Write-Host "`nRemediable audit failures:" -ForegroundColor Magenta
    for ($i = 0; $i -lt $failures.Count; $i++) {
        Write-Host ("  [{0}] {1}  ({2})  {3}" -f ($i + 1), $failures[$i].Key, $failures[$i].Where, $failures[$i].Detail)
    }
    $selection = Read-Host "`nEnter number(s) to remediate (comma-separated), 'all', or 'q' to quit"
    if ($selection -eq 'q') { return }

    $indices = if ($selection -eq 'all') { 1..$failures.Count } else { $selection -split ',' | ForEach-Object { [int]$_.Trim() } }
    foreach ($idx in $indices) {
        $f = $failures[$idx - 1]
        if ($f.Where -ne 'org' -and -not $RepoName -and -not $AllRepos) {
            $script:RepoName = $f.Where
        }
        Invoke-Policy -Key $f.Key
        $script:RepoName = $RepoName
    }
}

Write-RemLog 'Remediation run complete. Re-run Invoke-GitHubAudit.ps1 to verify.' -Level SUCCESS
#endregion
