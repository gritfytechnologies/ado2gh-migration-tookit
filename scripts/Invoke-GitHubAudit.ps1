#Requires -Version 5.1
<#
.SYNOPSIS
    Audits GitHub security posture at organization, enterprise, and repository
    level, producing colored PASS/FAIL/WARN console output and a JSON report.

.DESCRIPTION
    Org-level checks: 2FA enforcement, default repo permission, member repo
    creation, public repo creation, private forking, and the six
    "*_for_new_repositories" security defaults (dependency graph, Dependabot
    alerts/updates, Advanced Security, secret scanning, push protection).

    Enterprise-level checks (skippable via -SkipEnterprise): Actions policies,
    IP allow list, SAML SSO enforcement.

    Repository-level checks (sampled up to -MaxRepos, or one via -RepoName, or
    every repo via -AllRepos): branch protection, secret scanning, Dependabot
    alerts, vulnerability alerts, visibility, Actions permissions.

.PARAMETER OrgName
    GitHub organization to audit.

.PARAMETER AllRepos
    Audit every repository (overrides -MaxRepos).

.PARAMETER RepoName
    Audit a single repository.

.PARAMETER MaxRepos
    Repository sample size when -AllRepos/-RepoName not used.

.PARAMETER OutputPath
    Path for the JSON audit report.

.PARAMETER SkipEnterprise
    Skip enterprise-level checks (required for orgs without enterprise access).

.PARAMETER ToolsPath
    Explicit folder containing gh.exe and jq.exe. Resolution order:
    ToolsPath > script folder > current directory > PATH.

.EXAMPLE
    ./Invoke-GitHubAudit.ps1 -OrgName contoso-gh
    Audit org + enterprise + 20 sampled repos.

.EXAMPLE
    ./Invoke-GitHubAudit.ps1 -OrgName contoso-gh -AllRepos -SkipEnterprise

.NOTES
    Author  : Platform Engineering
    Version : 2.1.0
    Requires: PowerShell 5.1+, gh CLI (authenticated), jq.
    Scopes  : read:org (org checks), admin:org + read:enterprise (enterprise),
              repo (repo checks).
    Security: authentication via gh CLI session / GH_TOKEN — never logged.
#>
[CmdletBinding()]
param(
    [string] $OrgName    = '<github-org>',
    [switch] $AllRepos,
    [string] $RepoName   = '',
    [int]    $MaxRepos   = 20,
    [string] $OutputPath = '.\github_audit_report.json',
    [switch] $SkipEnterprise,
    [string] $ToolsPath  = ''   # explicit folder containing gh.exe and jq.exe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region TOOL RESOLUTION
function Resolve-Tool {
    param([Parameter(Mandatory)][string] $Name)
    $exe = if ($env:OS -match 'Windows' -or ($PSVersionTable.PSVersion.Major -ge 6 -and $IsWindows)) { "$Name.exe" } else { $Name }
    $candidates = @()
    if ($ToolsPath) { $candidates += (Join-Path $ToolsPath $exe) }
    $candidates += (Join-Path $PSScriptRoot $exe)
    $candidates += (Join-Path (Get-Location).Path $exe)
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    if (Get-Command $Name -ErrorAction SilentlyContinue) { return $Name }
    throw "Tool '$Name' not found. Searched: $($candidates -join '; ') and PATH. Fix: install $Name or pass -ToolsPath pointing at the folder containing $exe."
}

$Script:GhCmd = Resolve-Tool -Name 'gh'
$Script:JqCmd = Resolve-Tool -Name 'jq'
#endregion

#region CHECK ENGINE
$Script:Report = [ordered]@{
    org               = $OrgName
    timestamp         = (Get-Date).ToString('o')
    org_checks        = [ordered]@{}
    enterprise_checks = [ordered]@{}
    repo_checks       = @()
    summary           = [ordered]@{ total_checks = 0; passed = 0; failed = 0; warnings = 0 }
}

function Write-CheckResult {
    param(
        [string] $Name,
        [ValidateSet('PASS', 'FAIL', 'WARN')] [string] $Status,
        [string] $Value,
        [string] $Expected
    )
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } }
    Write-Host ("  [{0}] {1}  (value: {2}; expected: {3})" -f $Status.PadRight(4), $Name, $Value, $Expected) -ForegroundColor $color
    $Script:Report.summary.total_checks++
    switch ($Status) {
        'PASS' { $Script:Report.summary.passed++ }
        'FAIL' { $Script:Report.summary.failed++ }
        'WARN' { $Script:Report.summary.warnings++ }
    }
    return [ordered]@{ status = $Status; value = $Value; expected = $Expected }
}

function Invoke-GhApi {
    param([Parameter(Mandatory)][string] $Endpoint, [string[]] $Extra = @())
    $apiArgs = @('api', $Endpoint) + @($Extra)
    $raw = (& $Script:GhCmd @apiArgs 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        if ($raw -match '404') { return $null }
        throw "GitHub API call failed: $Endpoint — $raw"
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $raw }
}
#endregion

#region ORG-LEVEL CHECKS
Write-Host "`n=== ORG-LEVEL CHECKS: $OrgName ===" -ForegroundColor Magenta
$org = Invoke-GhApi "/orgs/$OrgName"
if ($null -eq $org) {
    throw "Organization '$OrgName' not found or inaccessible. Expected a readable org. Fix: check the org name and that the PAT has read:org scope."
}

function Get-OrgProp {
    param([string] $Prop)
    if ($org.PSObject.Properties.Name -contains $Prop -and $null -ne $org.$Prop) { return "$($org.$Prop)" }
    return 'not-set'
}

$orgPolicies = @(
    @{ Name = 'two_factor_requirement_enabled';                          Expected = 'True' }
    @{ Name = 'default_repository_permission';                          Expected = 'none' }
    @{ Name = 'members_can_create_repositories';                        Expected = 'False' }
    @{ Name = 'members_can_create_public_repositories';                 Expected = 'False' }
    @{ Name = 'members_can_fork_private_repositories';                  Expected = 'False' }
    @{ Name = 'dependency_graph_enabled_for_new_repositories';          Expected = 'True' }
    @{ Name = 'dependabot_alerts_enabled_for_new_repositories';         Expected = 'True' }
    @{ Name = 'dependabot_security_updates_enabled_for_new_repositories'; Expected = 'True' }
    @{ Name = 'advanced_security_enabled_for_new_repositories';         Expected = 'True' }
    @{ Name = 'secret_scanning_enabled_for_new_repositories';           Expected = 'True' }
    @{ Name = 'secret_scanning_push_protection_enabled_for_new_repositories'; Expected = 'True' }
)

foreach ($policy in $orgPolicies) {
    $value  = Get-OrgProp -Prop $policy.Name
    $status = if ($value -eq 'not-set') { 'WARN' }
              elseif ($value -eq $policy.Expected) { 'PASS' }
              else { 'FAIL' }
    $Script:Report.org_checks[$policy.Name] = Write-CheckResult -Name $policy.Name -Status $status -Value $value -Expected $policy.Expected
}
#endregion

#region ENTERPRISE-LEVEL CHECKS
if (-not $SkipEnterprise) {
    Write-Host "`n=== ENTERPRISE-LEVEL CHECKS ===" -ForegroundColor Magenta
    try {
        # Actions policies (org-scoped API reflects enterprise policy downstream)
        $actions = Invoke-GhApi "/orgs/$OrgName/actions/permissions"
        if ($actions) {
            $allowed = if ($actions.PSObject.Properties.Name -contains 'allowed_actions') { "$($actions.allowed_actions)" } else { 'all' }
            $status  = if ($allowed -in @('selected', 'local_only')) { 'PASS' } else { 'WARN' }
            $Script:Report.enterprise_checks['actions_allowed_policy'] = Write-CheckResult -Name 'actions_allowed_policy' -Status $status -Value $allowed -Expected 'selected or local_only'
        }

        # IP allow list + SAML SSO via GraphQL
        $gqlQuery = 'query($org:String!){ organization(login:$org){ ipAllowListEnabledSetting samlIdentityProvider { ssoUrl } } }'
        $gqlArgs  = @('api', 'graphql', '-f', "query=$gqlQuery", '-f', "org=$OrgName")
        $gqlRaw   = (& $Script:GhCmd @gqlArgs 2>&1) -join "`n"
        if ($LASTEXITCODE -eq 0) {
            $gql = ($gqlRaw | ConvertFrom-Json).data.organization
            $ipVal = "$($gql.ipAllowListEnabledSetting)"
            $ipStatus = if ($ipVal -eq 'ENABLED') { 'PASS' } else { 'WARN' }
            $Script:Report.enterprise_checks['ip_allow_list_enabled'] = Write-CheckResult -Name 'ip_allow_list_enabled' -Status $ipStatus -Value $ipVal -Expected 'ENABLED'

            $samlVal = if ($null -ne $gql.samlIdentityProvider) { 'configured' } else { 'not-configured' }
            $samlStatus = if ($samlVal -eq 'configured') { 'PASS' } else { 'WARN' }
            $Script:Report.enterprise_checks['saml_sso_enforcement'] = Write-CheckResult -Name 'saml_sso_enforcement' -Status $samlStatus -Value $samlVal -Expected 'configured (or EMU-managed)'
        }
        else {
            Write-Host '  [WARN] Enterprise GraphQL checks unavailable (likely insufficient permissions or EMU restriction). Use -SkipEnterprise to silence.' -ForegroundColor Yellow
            $Script:Report.enterprise_checks['graphql_access'] = [ordered]@{ status = 'WARN'; value = 'inaccessible'; expected = 'accessible' }
            $Script:Report.summary.total_checks++; $Script:Report.summary.warnings++
        }
    }
    catch {
        Write-Host "  [WARN] Enterprise checks failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
#endregion

#region REPOSITORY-LEVEL CHECKS
Write-Host "`n=== REPOSITORY-LEVEL CHECKS ===" -ForegroundColor Magenta

$repos =
    if ($RepoName) { @([PSCustomObject]@{ name = $RepoName }) }
    else {
        $limit = if ($AllRepos) { 1000 } else { $MaxRepos }
        @(Invoke-GhApi "/orgs/$OrgName/repos?per_page=100" -Extra @('--paginate') | Select-Object -First $limit)
    }

$repoCheckResults = @()
foreach ($repo in @($repos)) {
    $rn = $repo.name
    Write-Host "`n  Repo: $rn" -ForegroundColor Cyan
    $checks = [ordered]@{}

    $detail = Invoke-GhApi "/repos/$OrgName/$rn"
    if ($null -eq $detail) {
        Write-Host "    [WARN] Repo '$rn' not accessible — skipping." -ForegroundColor Yellow
        continue
    }

    # Visibility
    $vis = "$($detail.visibility)"
    $checks['no_public_visibility'] = Write-CheckResult -Name 'no_public_visibility' -Status $(if ($vis -ne 'public') { 'PASS' } else { 'FAIL' }) -Value $vis -Expected 'private/internal'

    # Branch protection on default branch
    $defBranch = "$($detail.default_branch)"
    $bp = Invoke-GhApi "/repos/$OrgName/$rn/branches/$defBranch/protection"
    if ($null -eq $bp) {
        $checks['branch_protection'] = Write-CheckResult -Name 'branch_protection' -Status 'FAIL' -Value 'none' -Expected "protection on $defBranch"
    }
    else {
        $prReviews = ($bp.PSObject.Properties.Name -contains 'required_pull_request_reviews')
        $noForce   = ($bp.PSObject.Properties.Name -contains 'allow_force_pushes') -and (-not $bp.allow_force_pushes.enabled)
        $noDelete  = ($bp.PSObject.Properties.Name -contains 'allow_deletions') -and (-not $bp.allow_deletions.enabled)
        $dismiss   = $prReviews -and $bp.required_pull_request_reviews.dismiss_stale_reviews
        $allGood   = $prReviews -and $noForce -and $noDelete -and $dismiss
        $checks['branch_protection'] = Write-CheckResult -Name 'branch_protection' -Status $(if ($allGood) { 'PASS' } else { 'WARN' }) -Value "reviews=$prReviews dismissStale=$dismiss noForce=$noForce noDelete=$noDelete" -Expected 'all true'
    }

    # Secret scanning
    $ss = if ($detail.PSObject.Properties.Name -contains 'security_and_analysis' -and $detail.security_and_analysis) {
        "$($detail.security_and_analysis.secret_scanning.status)"
    } else { 'unknown' }
    $checks['secret_scanning'] = Write-CheckResult -Name 'secret_scanning' -Status $(if ($ss -eq 'enabled') { 'PASS' } elseif ($ss -eq 'unknown') { 'WARN' } else { 'FAIL' }) -Value $ss -Expected 'enabled'

    # Vulnerability alerts (Dependabot alerts)
    $vaArgs = @('api', "/repos/$OrgName/$rn/vulnerability-alerts")
    $null = (& $Script:GhCmd @vaArgs 2>&1)
    $vaEnabled = ($LASTEXITCODE -eq 0)
    $checks['vulnerability_alerts'] = Write-CheckResult -Name 'vulnerability_alerts' -Status $(if ($vaEnabled) { 'PASS' } else { 'FAIL' }) -Value "$vaEnabled" -Expected 'True'
    $checks['dependabot_alerts']   = Write-CheckResult -Name 'dependabot_alerts' -Status $(if ($vaEnabled) { 'PASS' } else { 'FAIL' }) -Value "$vaEnabled" -Expected 'True'

    # Actions permissions
    $ap = Invoke-GhApi "/repos/$OrgName/$rn/actions/permissions"
    $apEnabled = if ($ap -and ($ap.PSObject.Properties.Name -contains 'enabled')) { [bool]$ap.enabled } else { $true }
    $checks['actions_permissions'] = Write-CheckResult -Name 'actions_permissions' -Status $(if ($apEnabled) { 'WARN' } else { 'PASS' }) -Value "enabled=$apEnabled" -Expected 'disabled if unused'

    $repoCheckResults += [ordered]@{ repo = $rn; checks = $checks }
}
$Script:Report.repo_checks = $repoCheckResults
#endregion

#region OUTPUT
$Script:Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

Write-Host "`n=== AUDIT SUMMARY ===" -ForegroundColor Magenta
Write-Host ("  Total: {0}   Passed: {1}   Failed: {2}   Warnings: {3}" -f `
    $Script:Report.summary.total_checks, $Script:Report.summary.passed,
    $Script:Report.summary.failed, $Script:Report.summary.warnings) -ForegroundColor Cyan
Write-Host "  Report: $OutputPath" -ForegroundColor Cyan
Write-Host "  Next: review failures, then run Invoke-GitHubRemediate.ps1 -ReportPath $OutputPath" -ForegroundColor Cyan
#endregion
