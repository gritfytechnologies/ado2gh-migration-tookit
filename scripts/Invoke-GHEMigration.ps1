#Requires -Version 7.0
<#
.SYNOPSIS
    Migrates Git repositories from Azure DevOps to GitHub Enterprise using the
    GitHub Enterprise Importer (gh ado2gh) with wave-based parallel execution.

.DESCRIPTION
    Invoke-GHEMigration.ps1 is the primary orchestration script of the
    GitHub Enterprise Migration Toolkit (v2.7.0). It executes 8 phases:

      Phase 1: VALIDATION     - Tools, versions, credentials, PAT permission test
      Phase 2: DISCOVERY      - Repo enumeration (All/Single/Selected), resume filter
      Phase 3: AUDIT          - Active PRs, size/branch/tag inventory, risk, HTML dashboard
      Phase 4: MIGRATION      - Wave-based RunspacePool parallel execution, state persistence
      Phase 5: VERIFICATION   - Branch + tag count ADO <-> GitHub per repo, per-repo SHA validation
      Phase 6: POST-CONFIG    - Branch protection, team access, default branch rename, custom properties
      Phase 7: PIPELINE GUIDE - YAML update snippets, Update-DevRemote.ps1, mannequin guide
      Phase 8: REPORT         - HTML migration report, final state JSON

    SCOPE: Git repositories only. ADO Pipelines remain in ADO and are
    reconnected via a GitHub Service Connection (see 4_Rewire-Pipeline.ps1).

    v2.7.0 merges the v2.6.0 feature set of the upstream "GitHub Migration"
    lineage of this same tool: LFS verification/fallback-push (backing the
    previously informational -IncludeLfs flag), tag + HEAD-SHA verification,
    per-repo post-migration validation, GitHub custom properties, migration
    log download via gh ado2gh, and resumable state restore (backing
    -ResumeFromState). Toolkit-only features — Write-MannequinGuide, the
    audit dashboard, HTML report, and pipeline guide content — are retained.

.PARAMETER Mode
    Migration mode: 'All' (every enabled repo in the ADO project),
    'Single' (one repo via -RepoName), or 'Selected' (CSV via -RepoListFile).

.PARAMETER AdoOrg
    Azure DevOps organization name.

.PARAMETER AdoProject
    Azure DevOps team project name.

.PARAMETER AdoPat
    Azure DevOps PAT as SecureString. Falls back to $env:ADO_PAT, then
    config file, then interactive prompt. Never logged.

.PARAMETER GitHubOrg
    Target GitHub organization.

.PARAMETER GitHubPat
    GitHub PAT as SecureString (requires repo, admin:org, workflow scopes).
    Falls back to $env:GH_PAT, then config file, then interactive prompt.

.PARAMETER GitHubEnterpriseHost
    Optional GHES API URL for GitHub Enterprise Server targets.

.PARAMETER RepoName
    Repository name for Single mode.

.PARAMETER RepoListFile
    Path to repos.csv (AdoRepo,GitHubRepo,Lfs) for Selected mode.

.PARAMETER ConfigFile
    Path to migration.config.json. CLI parameters always win over config values.

.PARAMETER BranchProtectionFile
    Path to branch protection rules JSON. Empty = built-in enterprise default.

.PARAMETER TeamSlug
    GitHub team slug granted push access post-migration.

.PARAMETER DefaultBranch
    Desired default branch name post-migration (renamed if different).

.PARAMETER ServiceConnectionName
    Name of the GitHub service connection in ADO, used in the generated
    pipeline-update-guide.yml snippets. Default: 'github-app-service-connection'.

.PARAMETER OutputDir
    Output directory for logs, reports, state and audit files.

.PARAMETER WaveSize
    Repositories per wave (0 = single wave / unlimited).

.PARAMETER ConcurrentJobs
    RunspacePool worker count (1-10).

.PARAMETER WaveDelaySeconds
    Pause between waves to avoid GitHub secondary rate limits.

.PARAMETER IncludeLfs
    Enables post-migration LFS verification (clone + `git lfs ls-files`) and,
    on failure, an interactive LFS fallback push (full ADO clone -> LFS fetch
    -> push to GitHub). gh ado2gh migrates LFS objects automatically; this
    flag adds a belt-and-braces verification/repair pass. See also
    -SkipLfsVerification.

.PARAMETER DryRun
    Validate and simulate only. No migrations executed. ALWAYS RUN FIRST.

.PARAMETER SkipAudit
    Skip the pre-migration audit phase.

.PARAMETER SkipBranchVerification
    Skip post-migration branch/tag count verification.

.PARAMETER SkipPostConfig
    Skip branch protection / team access / branch rename / custom properties phase.

.PARAMETER SkipPipelineUpdate
    Skip generation of pipeline-update-guide.yml and Update-DevRemote.ps1.

.PARAMETER ForceWithActivePrs
    Warn but do not block when active PRs are found in ADO.

.PARAMETER SkipExistingRepos
    Idempotency: skip repos that already exist in the target GitHub org.

.PARAMETER VerboseMigration
    Pass --verbose to gh ado2gh migrate-repo.

.PARAMETER ResumeFromState
    Path to a previous migration-state JSON. Repos in Completed[] are skipped.

.PARAMETER CustomProperties
    Hashtable of GitHub custom-property key/value pairs applied to every
    successfully migrated repo post-migration (e.g. @{ team = 'payments' }).
    Property schemas are auto-initialised on the org if missing.

.PARAMETER SetAdoMetadata
    Also stamp ado-origin-org / ado-origin-project / ado-origin-repo as
    GitHub custom properties on each migrated repo, for provenance tracking.

.PARAMETER SkipLfsVerification
    Skip the LFS verification/fallback-push phase even when -IncludeLfs is set.

.PARAMETER SkipPerRepoValidation
    Skip the per-repo HEAD-SHA/branch/tag validation performed immediately
    after each successful migration (Phase 4/5 boundary).

.EXAMPLE
    ./Invoke-GHEMigration.ps1 -Mode Selected -RepoListFile ./repos.csv `
        -AdoOrg contoso -AdoProject Payments -GitHubOrg contoso-gh -DryRun

    Dry-run a selected-list migration. ALWAYS do this first.

.EXAMPLE
    ./Invoke-GHEMigration.ps1 -Mode All -AdoOrg contoso -AdoProject Payments `
        -GitHubOrg contoso-gh -WaveSize 10 -ConcurrentJobs 3 -SkipExistingRepos

    Migrate every enabled repo in waves of 10, 3 in parallel, skipping repos
    that already exist on GitHub.

.EXAMPLE
    ./Invoke-GHEMigration.ps1 -Mode Single -RepoName app-service-1 `
        -AdoOrg contoso -AdoProject Payments -GitHubOrg contoso-gh -IncludeLfs

.NOTES
    Author  : Platform Engineering
    Version : 2.7.0 (merges upstream v2.6.0 feature set)
    Requires: PowerShell 7.0+, git 2.38+, gh CLI 2.30+ with ado2gh extension,
              az CLI with azure-devops extension, jq.
    Security: PATs are handled as SecureString / environment variables only and
              are NEVER echoed, logged, or written to any output file.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'All')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('All', 'Single', 'Selected')]
    [string] $Mode,

    [Parameter(Mandatory)] [string] $AdoOrg,
    [Parameter(Mandatory)] [string] $AdoProject,
    [Parameter()] [SecureString] $AdoPat,
    [Parameter(Mandatory)] [string] $GitHubOrg,
    [Parameter()] [SecureString] $GitHubPat,
    [Parameter()] [string] $GitHubEnterpriseHost,

    [Parameter(ParameterSetName = 'Single')]   [string] $RepoName,
    [Parameter(ParameterSetName = 'Selected')] [string] $RepoListFile,

    [Parameter()] [string] $ConfigFile,
    [Parameter()] [string] $BranchProtectionFile,
    [Parameter()] [string] $TeamSlug,
    [Parameter()] [string] $DefaultBranch,
    [Parameter()] [string] $ServiceConnectionName = 'github-app-service-connection',
    [Parameter()] [string] $OutputDir = './migration-output',

    [Parameter()] [ValidateRange(0, 200)] [int] $WaveSize = 10,
    [Parameter()] [ValidateRange(1, 10)]  [int] $ConcurrentJobs = 3,
    [Parameter()] [ValidateRange(0, 300)] [int] $WaveDelaySeconds = 30,

    [switch] $IncludeLfs,
    [switch] $DryRun,
    [switch] $SkipAudit,
    [switch] $SkipBranchVerification,
    [switch] $SkipPostConfig,
    [switch] $SkipPipelineUpdate,
    [switch] $ForceWithActivePrs,
    [switch] $SkipExistingRepos,   # Idempotency: skip repos already on GitHub
    [switch] $VerboseMigration,    # Pass --verbose to gh ado2gh migrate-repo

    [Parameter()] [string] $ResumeFromState,

    [Parameter()] [hashtable] $CustomProperties,
    [switch] $SetAdoMetadata,
    [switch] $SkipLfsVerification,
    [switch] $SkipPerRepoValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region 1 — CONSTANTS & GLOBALS
# ============================================================================
# Capture the SCRIPT-level bound parameters. Inside functions,
# $PSBoundParameters refers to the function's own parameters — using it there
# for CLI-vs-config precedence checks would be a bug.
$Script:CliBoundParams = $PSBoundParameters

$Script:VERSION    = '2.7.0'
$Script:TOOL_NAME  = 'Invoke-GHEMigration'
$Script:START_TIME = Get-Date
$Script:RUN_ID     = $Script:START_TIME.ToString('yyyyMMdd-HHmmss')

# File paths (resolved during Initialize-Environment)
$Script:LOG_FILE    = $null
$Script:REPORT_FILE = $null
$Script:STATE_FILE  = $null
$Script:AUDIT_DIR   = $null
$Script:LOGS_DIR    = $null

# Runtime counters
$Script:Stats = [ordered]@{
    Total     = 0
    Succeeded = 0
    Failed    = 0
    Skipped   = 0  # repos skipped (already exist + SkipExistingRepos, or DryRun)
    Warnings  = 0
}

# Per-repo result list (for HTML report)
$Script:Results = [System.Collections.Generic.List[hashtable]]::new()

# Resolved tool paths (may fall back to local exe)
$Script:GhCmd = 'gh'
$Script:JqCmd = 'jq'

# Resume state
$Script:MigrationState = @{
    RunId      = $Script:RUN_ID
    Mode       = $Mode
    Completed  = @()
    Failed     = @()
    Skipped    = @()
    InProgress = @()
}

# Populated by Invoke-PreMigrationAudit; consumed by LFS verification and
# per-repo validation (keyed lookup by RepoName).
$Script:AuditData    = @{}
$Script:AuditResults = @()

# LFS disk-space accounting (populated during audit; used by Phase 5b LFS verification)
$Script:LfsDiskRequiredGB  = 0
$Script:LfsDiskAvailableGB = 0

# Per-repo post-migration validation results (HEAD SHA / branch / tag), see -SkipPerRepoValidation
$Script:ValidationResults = [System.Collections.Generic.List[PSObject]]::new()
#endregion

#region 2 — LOGGING
# ============================================================================
function Write-Log {
    param(
        [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG', 'HEADER', 'STEP')]
        [string] $Level = 'INFO',
        [switch] $NoFile
    )
    $ts      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $logLine = "[$ts][$Level] $Message"
    $color   = switch ($Level) {
        'INFO'    { 'Cyan' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'SUCCESS' { 'Green' }
        'DEBUG'   { 'Gray' }
        'HEADER'  { 'Magenta' }
        'STEP'    { 'White' }
    }
    if ($Level -eq 'HEADER') {
        Write-Host "`n$('=' * 72)" -ForegroundColor DarkBlue
        Write-Host "  $Message" -ForegroundColor Magenta
        Write-Host "$('=' * 72)" -ForegroundColor DarkBlue
    }
    elseif ($Level -eq 'STEP') {
        Write-Host "  >  $Message" -ForegroundColor White
    }
    else {
        Write-Host "[$($Level.PadRight(7))] $Message" -ForegroundColor $color
    }
    if (-not $NoFile -and $Script:LOG_FILE) {
        Add-Content -Path $Script:LOG_FILE -Value $logLine -Encoding UTF8
    }
    if ($Level -eq 'WARN') { $Script:Stats.Warnings++ }
}

function Write-Section { param([string]$Title)   Write-Log $Title -Level HEADER }
function Write-Step    { param([string]$Message) Write-Log $Message -Level STEP }
#endregion

#region 3 — INITIALISATION
# ============================================================================
function Initialize-Environment {
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $resolvedOut = (Resolve-Path -LiteralPath $OutputDir).Path

    $Script:LOG_FILE    = Join-Path $resolvedOut "migration-$($Script:RUN_ID).log"
    $Script:REPORT_FILE = Join-Path $resolvedOut "migration-report-$($Script:RUN_ID).html"
    $Script:STATE_FILE  = Join-Path $resolvedOut "migration-state-$($Script:RUN_ID).json"
    $Script:AUDIT_DIR   = Join-Path $resolvedOut 'audit'
    $Script:LOGS_DIR    = Join-Path $resolvedOut 'migration-logs'

    foreach ($dir in @($Script:AUDIT_DIR, $Script:LOGS_DIR)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    Write-Section "$($Script:TOOL_NAME) v$($Script:VERSION)  |  Run $($Script:RUN_ID)"
    Write-Log "Mode                : $Mode"
    Write-Log "ADO Source          : $AdoOrg / $AdoProject"
    Write-Log "GitHub Target       : $GitHubOrg"
    Write-Log "Wave size           : $WaveSize   Concurrent jobs: $ConcurrentJobs   Wave delay: ${WaveDelaySeconds}s"
    Write-Log "DryRun              : $($DryRun.IsPresent)"
    Write-Log "SkipExistingRepos   : $($SkipExistingRepos.IsPresent)"
    Write-Log "ForceWithActivePrs  : $($ForceWithActivePrs.IsPresent)"
    Write-Log "IncludeLfs          : $($IncludeLfs.IsPresent)   SkipLfsVerification: $($SkipLfsVerification.IsPresent)"
    Write-Log "SkipPerRepoValidation: $($SkipPerRepoValidation.IsPresent)"
    Write-Log "Output directory    : $resolvedOut"
    # SECURITY: PAT values are intentionally never logged.
}

function Resolve-LocalTools {
    [CmdletBinding()]
    param()

    $exeSuffix   = if ($IsWindows) { '.exe' } else { '' }
    $searchDirs  = @(
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin'),
        $PSScriptRoot
    )

    foreach ($tool in @('gh', 'jq')) {
        $resolved = $null
        $onPath   = Get-Command $tool -ErrorAction SilentlyContinue
        if ($onPath) {
            $resolved = $tool
        }
        else {
            foreach ($dir in $searchDirs) {
                $candidate = Join-Path $dir "$tool$exeSuffix"
                if (Test-Path -LiteralPath $candidate) { $resolved = $candidate; break }
            }
        }
        if (-not $resolved) {
            Write-Log "Tool '$tool' not found on PATH, in bin/, or beside the script. Install it or place $tool$exeSuffix in the bin/ folder." -Level WARN
            $resolved = $tool  # keep default; Test-Prerequisites will fail it explicitly
        }
        if ($tool -eq 'gh') { $Script:GhCmd = $resolved } else { $Script:JqCmd = $resolved }
    }
    Write-Log "Resolved gh -> $Script:GhCmd ; jq -> $Script:JqCmd" -Level DEBUG
}

function Import-ConfigFile {
    [CmdletBinding()]
    param()

    if (-not $ConfigFile) { return }
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw "Config file '$ConfigFile' not found. Expected a JSON file like migration.config.json. Fix: check the path or omit -ConfigFile."
    }

    $config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
    Write-Log "Loaded configuration from $ConfigFile (CLI parameters take precedence)."

    $stringFields = @(
        'AdoOrg', 'AdoProject', 'GitHubOrg', 'GitHubEnterpriseHost', 'TeamSlug',
        'DefaultBranch', 'ServiceConnectionName', 'OutputDir', 'WaveSize', 'ConcurrentJobs',
        'WaveDelaySeconds', 'BranchProtectionFile', 'RepoListFile'
    )
    foreach ($field in $stringFields) {
        # Only apply when the caller did NOT specify the parameter (CLI wins)
        if ($Script:CliBoundParams.ContainsKey($field)) { continue }
        if (($config.PSObject.Properties.Name -contains $field) -and
            $null -ne $config.$field -and "$($config.$field)" -ne '') {
            Set-Variable -Name $field -Value $config.$field -Scope Script -Force
            Write-Log "Config applied: $field = $($config.$field)" -Level DEBUG
        }
    }

    # Switch params — migration.config.json's _flags_note promises "Each key matches
    # a -Switch parameter", but switches can't be assigned via the $stringFields loop
    # above ($config.$field is a JSON boolean, not a [switch]); handle them explicitly.
    $switchFields = @(
        'IncludeLfs', 'SkipAudit', 'SkipBranchVerification', 'SkipPostConfig',
        'SkipPipelineUpdate', 'ForceWithActivePrs', 'SkipExistingRepos', 'VerboseMigration',
        'SetAdoMetadata', 'SkipLfsVerification', 'SkipPerRepoValidation'
    )
    foreach ($field in $switchFields) {
        if ($Script:CliBoundParams.ContainsKey($field)) { continue }
        if (($config.PSObject.Properties.Name -contains $field) -and $config.$field -eq $true) {
            Set-Variable -Name $field -Value ([switch]::new($true)) -Scope Script -Force
            Write-Log "Config applied: $field = `$true" -Level DEBUG
        }
    }

    # CustomProperties is a hashtable, not a scalar — apply separately when not CLI-bound.
    if (-not $Script:CliBoundParams.ContainsKey('CustomProperties') -and
        ($config.PSObject.Properties.Name -contains 'CustomProperties') -and $config.CustomProperties) {
        $props = @{}
        foreach ($p in $config.CustomProperties.PSObject.Properties) {
            if ($p.Name -notlike '_*') { $props[$p.Name] = $p.Value }
        }
        if ($props.Count -gt 0) {
            $script:CustomProperties = $props
            Write-Log "Config applied: CustomProperties = $($props.Count) key(s)" -Level DEBUG
        }
    }

    # PATs from config only when not already provided (CLI param or env var wins).
    # SECURITY: converted straight to SecureString; plain value not retained or logged.
    if (-not $Script:CliBoundParams.ContainsKey('AdoPat') -and -not $env:ADO_PAT) {
        if (($config.PSObject.Properties.Name -contains 'AdoPat') -and $config.AdoPat) {
            $script:AdoPat = ConvertTo-SecureString -String $config.AdoPat -AsPlainText -Force
            Write-Log 'AdoPat loaded from config file (value not logged).' -Level DEBUG
        }
    }
    if (-not $Script:CliBoundParams.ContainsKey('GitHubPat') -and -not $env:GH_PAT) {
        if (($config.PSObject.Properties.Name -contains 'GitHubPat') -and $config.GitHubPat) {
            $script:GitHubPat = ConvertTo-SecureString -String $config.GitHubPat -AsPlainText -Force
            Write-Log 'GitHubPat loaded from config file (value not logged).' -Level DEBUG
        }
    }
}
#endregion

#region 4 — CREDENTIAL HELPERS
# ============================================================================
function Get-PlainPat {
    <#
    .SYNOPSIS
        Extracts the plain-text value of a SecureString PAT.
    .NOTES
        SECURITY: the returned value must NEVER be logged or written to disk.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [SecureString] $Secure)
    return [System.Net.NetworkCredential]::new('', $Secure).Password
}

function Resolve-Credentials {
    [CmdletBinding()]
    param()

    Write-Step 'Resolving credentials (CLI param > env var > config > interactive prompt)'

    if (-not $script:AdoPat) {
        if ($env:ADO_PAT) {
            $script:AdoPat = ConvertTo-SecureString -String $env:ADO_PAT -AsPlainText -Force
            Write-Log 'ADO PAT sourced from $env:ADO_PAT.' -Level DEBUG
        }
        else {
            $script:AdoPat = Read-Host -Prompt 'Enter Azure DevOps PAT' -AsSecureString
        }
    }
    if (-not $script:GitHubPat) {
        if ($env:GH_PAT) {
            $script:GitHubPat = ConvertTo-SecureString -String $env:GH_PAT -AsPlainText -Force
            Write-Log 'GitHub PAT sourced from $env:GH_PAT.' -Level DEBUG
        }
        else {
            $script:GitHubPat = Read-Host -Prompt 'Enter GitHub PAT' -AsSecureString
        }
    }

    # Export for child processes (gh ado2gh reads ADO_PAT / GH_PAT; gh CLI
    # itself authenticates via GH_TOKEN; az devops reads AZURE_DEVOPS_EXT_PAT).
    # SECURITY: values live only in process environment — never logged.
    $env:ADO_PAT              = Get-PlainPat -Secure $script:AdoPat
    $env:GH_PAT               = Get-PlainPat -Secure $script:GitHubPat
    $env:GH_TOKEN             = $env:GH_PAT
    $env:AZURE_DEVOPS_EXT_PAT = $env:ADO_PAT

    Write-Log 'Credentials resolved and exported to child-process environment (values not logged).' -Level SUCCESS
}
#endregion

#region 5 — PREREQUISITES CHECK
# ============================================================================
function Test-Prerequisites {
    [CmdletBinding()]
    param()

    Write-Section 'PHASE 1 — VALIDATION'
    $allOk = $true

    # -- git ------------------------------------------------------------
    try {
        $gitVersionRaw = (& git --version) -join ''
        if ($gitVersionRaw -match '(\d+)\.(\d+)') {
            $gitVer = [version]"$($Matches[1]).$($Matches[2])"
            if ($gitVer -lt [version]'2.38') {
                Write-Log "git $gitVer found but 2.38+ required. Fix: upgrade git (winget upgrade Git.Git / brew upgrade git)." -Level ERROR
                $allOk = $false
            }
            else { Write-Log "git $gitVer OK" -Level SUCCESS }
        }
    }
    catch {
        Write-Log "git not found. Expected git 2.38+. Fix: install from https://git-scm.com." -Level ERROR
        $allOk = $false
    }

    # -- gh -------------------------------------------------------------
    try {
        $ghVersionRaw = (& $Script:GhCmd --version 2>&1) -join ' '
        if ($ghVersionRaw -match '(\d+)\.(\d+)') {
            $ghVer = [version]"$($Matches[1]).$($Matches[2])"
            if ($ghVer -lt [version]'2.30') {
                Write-Log "gh CLI $ghVer found but 2.30+ required. Fix: upgrade gh (https://cli.github.com)." -Level ERROR
                $allOk = $false
            }
            else { Write-Log "gh CLI $ghVer OK ($Script:GhCmd)" -Level SUCCESS }
        }
    }
    catch {
        Write-Log "gh CLI not found ('$Script:GhCmd'). Expected gh 2.30+. Fix: install from https://cli.github.com or drop gh$(if ($IsWindows) { '.exe' }) into bin/." -Level ERROR
        $allOk = $false
    }

    # -- gh ado2gh extension ---------------------------------------------
    try {
        $extList = (& $Script:GhCmd extension list 2>&1) -join "`n"
        if ($extList -notmatch 'ado2gh') {
            Write-Log "gh extension 'ado2gh' not installed. Expected the GitHub Enterprise Importer. Fix: gh extension install github/gh-ado2gh" -Level ERROR
            $allOk = $false
        }
        else { Write-Log 'gh ado2gh extension OK' -Level SUCCESS }
    }
    catch {
        Write-Log "Could not list gh extensions: $($_.Exception.Message). Fix: run 'gh auth login' then 'gh extension install github/gh-ado2gh'." -Level ERROR
        $allOk = $false
    }

    # -- az -------------------------------------------------------------
    try {
        $null = & az version --output json 2>&1
        Write-Log 'az CLI OK' -Level SUCCESS
        $azExt = (& az extension list --output json 2>&1) -join ''
        if ($azExt -notmatch 'azure-devops') {
            Write-Log "az extension 'azure-devops' missing. Fix: az extension add --name azure-devops" -Level ERROR
            $allOk = $false
        }
        else { Write-Log 'az azure-devops extension OK' -Level SUCCESS }
    }
    catch {
        Write-Log "az CLI not found. Expected Azure CLI with azure-devops extension. Fix: https://learn.microsoft.com/cli/azure/install-azure-cli then 'az extension add --name azure-devops'." -Level ERROR
        $allOk = $false
    }

    # -- jq -------------------------------------------------------------
    try {
        $null = & $Script:JqCmd --version 2>&1
        Write-Log "jq OK ($Script:JqCmd)" -Level SUCCESS
    }
    catch {
        Write-Log "jq not found ('$Script:JqCmd'). Fix: install jq (https://jqlang.github.io/jq) or drop jq$(if ($IsWindows) { '.exe' }) into bin/." -Level ERROR
        $allOk = $false
    }

    if (-not $allOk) {
        Write-Log 'One or more prerequisites failed — see errors above for exact fixes.' -Level ERROR
    }
    return $allOk
}

function Test-GitHubPatPermissions {
    <#
    .SYNOPSIS
        Pre-flight test that GH_PAT can create a GEI migration source.
    .NOTES
        The (undocumented) 'workflow' PAT scope is required by ado2gh.
        This creates a throwaway migration source via GraphQL to fail fast.
    #>
    [CmdletBinding()]
    param()

    if ($DryRun) {
        Write-Log 'Skipping GH_PAT permission pre-flight (DryRun).' -Level WARN
        return
    }

    Write-Step 'Testing GH_PAT permissions (createMigrationSource GraphQL mutation)'
    $query = @"
mutation {
  createMigrationSource(input: {
    name: "PAT-preflight-$($Script:RUN_ID)",
    url: "https://dev.azure.com/$AdoOrg",
    ownerId: "MDEyOk9yZ2FuaXphdGlvbjE=",
    type: AZURE_DEVOPS
  }) { migrationSource { id name } }
}
"@
    $response = (& $Script:GhCmd api graphql -f query=$query 2>&1) -join "`n"

    if ($response -match 'insufficient|permission') {
        Write-Log "GH_PAT permission test FAILED. Response indicated insufficient permissions." -Level ERROR
        throw "GH_PAT is missing the 'workflow' scope required for ado2gh migrations. Add 'workflow' scope to the PAT and retry."
    }
    # Other errors (e.g. invalid ownerId) still prove the scope is accepted.
    Write-Log 'GH_PAT permission pre-flight passed (workflow scope present).' -Level SUCCESS
}
#endregion

#region 6 — ADO HELPERS
# ============================================================================
function Get-AdoAuthHeader {
    [CmdletBinding()]
    param()
    $pat    = Get-PlainPat -Secure $script:AdoPat
    $base64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    return @{ Authorization = "Basic $base64" }
}

function Get-AdoRepos {
    [CmdletBinding()]
    param()

    $uri = "https://dev.azure.com/$AdoOrg/$AdoProject/_apis/git/repositories?api-version=7.1"
    Write-Log "Enumerating ADO repositories: $uri" -Level DEBUG
    try {
        $response = Invoke-RestMethod -Uri $uri -Headers (Get-AdoAuthHeader) -Method Get
    }
    catch {
        throw "Failed to list repositories for '$AdoOrg/$AdoProject'. Expected HTTP 200 from ADO REST API. Fix: verify org/project names and that ADO_PAT has Code (Read) scope. Detail: $($_.Exception.Message)"
    }

    $repos = foreach ($r in @($response.value)) {
        [PSCustomObject]@{
            Id             = $r.id
            Name           = $r.name
            DefaultBranch  = if ($r.PSObject.Properties.Name -contains 'defaultBranch' -and $r.defaultBranch) { $r.defaultBranch -replace '^refs/heads/', '' } else { '' }
            SizeMB         = if ($r.PSObject.Properties.Name -contains 'size' -and $r.size) { [math]::Round($r.size / 1MB, 2) } else { 0 }
            IsDisabled     = if ($r.PSObject.Properties.Name -contains 'isDisabled') { [bool]$r.isDisabled } else { $false }
            LastUpdateTime = if ($r.PSObject.Properties.Name -contains 'project') { $r.project.lastUpdateTime } else { $null }
        }
    }
    Write-Log "Found $(@($repos).Count) repositories in $AdoOrg/$AdoProject."
    return @($repos)
}

function Get-AdoRepoId {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name)
    $uri = "https://dev.azure.com/$AdoOrg/$AdoProject/_apis/git/repositories/$([uri]::EscapeDataString($Name))?api-version=7.1"
    try {
        $repo = Invoke-RestMethod -Uri $uri -Headers (Get-AdoAuthHeader) -Method Get
        return $repo.id
    }
    catch {
        throw "Repository '$Name' not found in $AdoOrg/$AdoProject. Expected an existing Git repo. Fix: check the repo name spelling. Detail: $($_.Exception.Message)"
    }
}

function Get-AdoActivePrs {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array] $Repos)

    $result = @{}
    $Script:AuditData['ActivePrDetails'] = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($repo in @($Repos)) {
        try {
            $repoId = Get-AdoRepoId -Name $repo.AdoRepo
            $uri    = "https://dev.azure.com/$AdoOrg/$AdoProject/_apis/git/repositories/$repoId/pullrequests?searchCriteria.status=active&api-version=7.1"
            $prs    = Invoke-RestMethod -Uri $uri -Headers (Get-AdoAuthHeader) -Method Get
            $count  = @($prs.value).Count
            $result[$repo.AdoRepo] = $count
            foreach ($pr in @($prs.value)) {
                $Script:AuditData['ActivePrDetails'].Add([PSCustomObject]@{
                    RepoName = $repo.AdoRepo
                    PrId     = $pr.pullRequestId
                    Title    = $pr.title
                    Author   = $pr.createdBy.displayName
                })
            }
        }
        catch {
            Write-Log "Could not check active PRs for '$($repo.AdoRepo)': $($_.Exception.Message)" -Level WARN
            $result[$repo.AdoRepo] = 0
        }
    }
    return $result
}

function Get-AdoBranchCount {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoName)

    try {
        $repoId = Get-AdoRepoId -Name $RepoName
        $uri    = "https://dev.azure.com/$AdoOrg/$AdoProject/_apis/git/repositories/$repoId/refs?filter=heads&api-version=7.1"
        $refs   = Invoke-RestMethod -Uri $uri -Headers (Get-AdoAuthHeader) -Method Get
        return @($refs.value).Count
    }
    catch {
        Write-Log "Could not count branches for '$RepoName': $($_.Exception.Message)" -Level WARN
        return -1
    }
}

function Get-AdoTagCount {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoName)

    try {
        $repoId = Get-AdoRepoId -Name $RepoName
        $uri    = "https://dev.azure.com/$AdoOrg/$AdoProject/_apis/git/repositories/$repoId/refs?filter=tags&api-version=7.1"
        $refs   = Invoke-RestMethod -Uri $uri -Headers (Get-AdoAuthHeader) -Method Get
        return @($refs.value).Count
    }
    catch {
        Write-Log "Could not count tags for '$RepoName': $($_.Exception.Message)" -Level WARN
        return -1
    }
}

function Get-AdoDefaultBranchSha {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoName,
        [Parameter(Mandatory)] [string] $BranchName
    )

    try {
        $repoId     = Get-AdoRepoId -Name $RepoName
        $normalized = if ($BranchName -like 'refs/heads/*') { $BranchName } else { "refs/heads/$BranchName" }
        $uri        = "https://dev.azure.com/$AdoOrg/$AdoProject/_apis/git/repositories/$repoId/refs?filter=heads&api-version=7.1"
        $refs       = Invoke-RestMethod -Uri $uri -Headers (Get-AdoAuthHeader) -Method Get
        $match      = @($refs.value) | Where-Object { $_.name -eq $normalized } | Select-Object -First 1
        if ($match) { return $match.objectId }
        return $null
    }
    catch {
        Write-Log "Could not resolve default-branch SHA for '$RepoName@$BranchName': $($_.Exception.Message)" -Level WARN
        return $null
    }
}
#endregion

#region 7 — GITHUB HELPERS
# ============================================================================
function Invoke-GitHubApi {
    <#
    .SYNOPSIS
        Wrapper around 'gh api' returning parsed JSON.
    .NOTES
        Uses $apiArgs — NOT $args — to avoid the PowerShell automatic-variable
        collision that silently corrupts argument arrays.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $Endpoint,
        [Parameter()]          [string[]] $ExtraArgs = @()
    )

    $apiArgs = @('api', $Endpoint) + @($ExtraArgs)
    $raw     = (& $Script:GhCmd @apiArgs 2>&1) -join "`n"

    if ($LASTEXITCODE -ne 0) {
        if ($raw -match '404|Not Found') { return $null }
        if ($raw -match 'HTTP 5\d\d|50[0-4]') {
            throw "GitHub API 5xx on '$Endpoint'. Response: $raw. Fix: retry later or check https://www.githubstatus.com."
        }
        throw "GitHub API call failed for '$Endpoint'. Response: $raw"
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $raw }
}

function Test-GitHubRepoExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Repo)

    $response = Invoke-GitHubApi -Endpoint "/repos/$GitHubOrg/$Repo"
    if ($null -ne $response -and ($response.PSObject.Properties.Name -contains 'name')) {
        return $true
    }
    return $false
}

function Get-GitHubBranchCount {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoName)

    try {
        $apiArgs = @('api', "/repos/$GitHubOrg/$RepoName/branches", '--paginate', '--jq', '.[].name')
        $raw     = (& $Script:GhCmd @apiArgs 2>&1)
        if ($LASTEXITCODE -ne 0) { return -1 }
        return @($raw | Where-Object { $_ }).Count
    }
    catch { return -1 }
}

function Get-GitHubTagCount {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoName)

    try {
        $raw     = (& $Script:GhCmd api "/repos/$GitHubOrg/$RepoName/git/refs/tags" --paginate 2>&1)
        $rawText = $raw | Out-String
        if ($rawText -match '404|422') { return 0 } # repo has no tags — not an error
        if ($LASTEXITCODE -ne 0) { return -1 }
        $tags = @(ConvertFrom-Json $rawText)
        return $tags.Count
    }
    catch { return -1 }
}

function Get-GitHubHeadSha {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoName,
        [Parameter(Mandatory)] [string] $BranchName
    )

    try {
        $branch = $BranchName -replace '^refs/heads/', ''
        $sha    = (& $Script:GhCmd api "/repos/$GitHubOrg/$RepoName/git/refs/heads/$branch" --jq '.object.sha' 2>$null)
        if ($sha -match '^[0-9a-f]{40}$') { return $sha }
        return $null
    }
    catch { return $null }
}

function Set-GitHubDefaultBranch {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $RepoName,
        [Parameter(Mandatory)] [string] $Branch
    )

    if ($PSCmdlet.ShouldProcess("$GitHubOrg/$RepoName", "Set default branch to '$Branch'")) {
        $body = @{ default_branch = $Branch } | ConvertTo-Json -Compress
        $raw  = ($body | & $Script:GhCmd api "/repos/$GitHubOrg/$RepoName" -X PATCH --input - 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Set default branch FAILED for $RepoName -> $Branch. Response: $raw" -Level WARN
            return $false
        }
        return $true
    }
    return $true
}

function Get-DefaultBranchProtectionJson {
    [CmdletBinding()]
    param()
    return @'
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
}

function Set-BranchProtection {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $Branch
    )

    $rulesFile = $null
    try {
        if ($BranchProtectionFile -and (Test-Path -LiteralPath $BranchProtectionFile)) {
            # Strip _comment keys the API would reject
            $rules = Get-Content -LiteralPath $BranchProtectionFile -Raw | ConvertFrom-Json
            $clean = [ordered]@{}
            foreach ($p in $rules.PSObject.Properties) {
                if ($p.Name -notlike '_*') { $clean[$p.Name] = $p.Value }
            }
            $rulesJson = $clean | ConvertTo-Json -Depth 10
        }
        else {
            $rulesJson = Get-DefaultBranchProtectionJson
        }
        $rulesFile = Join-Path ([IO.Path]::GetTempPath()) "bp-rules-$($Script:RUN_ID)-$Repo.json"
        Set-Content -LiteralPath $rulesFile -Value $rulesJson -Encoding UTF8

        if ($PSCmdlet.ShouldProcess("$GitHubOrg/$Repo@$Branch", 'Apply branch protection')) {
            $raw = (& $Script:GhCmd api -X PUT "/repos/$GitHubOrg/$Repo/branches/$Branch/protection" --input $rulesFile 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0) {
                Write-Log "Branch protection FAILED for $Repo@$Branch. Response: $raw. Fix: ensure the PAT has repo admin rights and the branch exists." -Level WARN
                return $false
            }
            Write-Log "Branch protection applied: $Repo@$Branch" -Level SUCCESS
            return $true
        }
        return $true
    }
    finally {
        if ($rulesFile -and (Test-Path -LiteralPath $rulesFile)) {
            Remove-Item -LiteralPath $rulesFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Grant-TeamAccess {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Repo)

    if (-not $TeamSlug) { return }
    if ($PSCmdlet.ShouldProcess("$GitHubOrg/$Repo", "Grant push access to team '$TeamSlug'")) {
        $raw = (& $Script:GhCmd api -X PUT "/orgs/$GitHubOrg/teams/$TeamSlug/repos/$GitHubOrg/$Repo" -f permission=push 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Team access grant FAILED for $Repo (team '$TeamSlug'). Response: $raw. Fix: verify the team slug exists in $GitHubOrg and the PAT has admin:org." -Level WARN
        }
        else {
            Write-Log "Team '$TeamSlug' granted push on $Repo" -Level SUCCESS
        }
    }
}

function Initialize-CustomPropertySchema {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter()] [string[]] $PropertyNames)

    if (-not $PropertyNames -or @($PropertyNames).Count -eq 0) { return }
    foreach ($name in @($PropertyNames)) {
        if ($PSCmdlet.ShouldProcess("$GitHubOrg", "Initialise custom property schema '$name'")) {
            try {
                $body = @{ value_type = 'string'; required = $false } | ConvertTo-Json -Compress
                $raw  = ($body | & $Script:GhCmd api "/orgs/$GitHubOrg/properties/schema/$name" -X PUT --input - 2>&1) -join "`n"
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "Failed to initialise custom property schema '$name'. Response: $raw" -Level WARN
                }
            }
            catch {
                Write-Log "Failed to initialise custom property schema '$name': $($_.Exception.Message)" -Level WARN
            }
        }
    }
}

function Set-RepoCustomProperties {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]    $RepoName,
        [Parameter(Mandatory)] [hashtable] $Properties
    )

    if (-not $Properties -or $Properties.Count -eq 0) { return }
    if ($PSCmdlet.ShouldProcess("$GitHubOrg/$RepoName", 'Set custom properties')) {
        $propList = foreach ($key in $Properties.Keys) {
            @{ property_name = $key; value = "$($Properties[$key])" }
        }
        $body = @{ properties = @($propList) } | ConvertTo-Json -Depth 5 -Compress
        $raw  = ($body | & $Script:GhCmd api "/repos/$GitHubOrg/$RepoName/properties/values" -X PATCH --input - 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Failed to set custom properties on $RepoName. Response: $raw" -Level WARN
        }
        else {
            Write-Log "Custom properties applied: $RepoName ($($Properties.Count) key(s))" -Level SUCCESS
        }
    }
}

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Generic retry helper with exponential backoff and 429 Retry-After support.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $Action,
        [int] $MaxAttempts    = 3,
        [int] $InitialDelayMs = 1000
    )

    $attempt = 0
    $delayMs = $InitialDelayMs
    while ($true) {
        $attempt++
        try {
            return & $Action
        }
        catch {
            $msg = $_.Exception.Message
            if ($attempt -ge $MaxAttempts) {
                throw "Action failed after $MaxAttempts attempts. Last error: $msg"
            }
            if ($msg -match '429') {
                # Honour Retry-After if present in the error payload
                $retryAfter = 60
                if ($msg -match 'Retry-After[:\s]+(\d+)') { $retryAfter = [int]$Matches[1] }
                Write-Log "Rate limited (429). Waiting ${retryAfter}s before retry $($attempt + 1)/$MaxAttempts..." -Level WARN
                Start-Sleep -Seconds $retryAfter
            }
            else {
                Write-Log "Attempt $attempt failed: $msg — retrying in $([math]::Round($delayMs/1000,1))s" -Level WARN
                Start-Sleep -Milliseconds $delayMs
                $delayMs = $delayMs * 2   # exponential backoff
            }
        }
    }
}
#endregion

#region 8 — PRE-MIGRATION AUDIT
# ============================================================================
function Get-AvailableDiskSpaceGB {
    [CmdletBinding()]
    param([string] $Path = '.')
    try {
        return [math]::Round((Get-Item -LiteralPath $Path).PSDrive.Free / 1GB, 1)
    }
    catch { return -1 }
}

function Invoke-PreMigrationAudit {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array] $RepoList)

    Write-Section 'PHASE 3 — PRE-MIGRATION AUDIT'
    $repoArr = @($RepoList)

    Write-Step 'Checking active pull requests in ADO'
    $activePrs = Get-AdoActivePrs -Repos $repoArr

    Write-Step 'Collecting branch/tag counts, size risk, and GitHub existence'
    $auditRows = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($repo in $repoArr) {
        $branchCount = Get-AdoBranchCount -RepoName $repo.AdoRepo
        $tagCount    = Get-AdoTagCount -RepoName $repo.AdoRepo
        $sizeMB      = if ($repo.PSObject.Properties.Name -contains 'SizeMB') { [double]$repo.SizeMB } else { 0 }
        $prCount     = if ($activePrs.ContainsKey($repo.AdoRepo)) { $activePrs[$repo.AdoRepo] } else { 0 }
        $alreadyInGh = Test-GitHubRepoExists -Repo $repo.GitHubRepo

        $risk = if     ($prCount -gt 0 -and -not $ForceWithActivePrs) { 'BLOCKED' }
                elseif ($prCount -gt 0 -and $ForceWithActivePrs)      { 'WARN' }
                elseif ($sizeMB -gt 10240)                             { 'CRITICAL' }
                elseif ($sizeMB -gt 5120)                              { 'XLARGE' }
                elseif ($sizeMB -gt 1024)                              { 'LARGE' }
                else                                                   { 'OK' }
        $needsLfs = if ($sizeMB -gt 500) { 'RECOMMENDED' } else { 'No' }

        if ($risk -in @('CRITICAL', 'XLARGE')) {
            Write-Log "$($repo.AdoRepo) is $risk (${sizeMB} MB). Recommended: migrate in its own wave with -IncludeLfs and verify disk headroom before proceeding." -Level WARN
        }

        $auditRows.Add([PSCustomObject]@{
            RepoName      = $repo.AdoRepo
            GitHubRepo    = $repo.GitHubRepo
            DefaultBranch = if ($repo.PSObject.Properties.Name -contains 'DefaultBranch') { $repo.DefaultBranch } else { '' }
            SizeMB        = $sizeMB
            BranchCount   = $branchCount
            TagCount      = $tagCount
            ActivePRs     = $prCount
            NeedsLfs      = $needsLfs
            AlreadyInGH   = $alreadyInGh
            MigrationRisk = $risk
        })
        $Script:AuditData[$repo.AdoRepo] = @{ BranchCount = $branchCount; TagCount = $tagCount; SizeMB = $sizeMB; ActivePRs = $prCount }
    }
    $Script:AuditResults = @($auditRows)

    # -- CSV exports -----------------------------------------------------
    $auditCsv = Join-Path $Script:AUDIT_DIR "audit-$($Script:RUN_ID).csv"
    $auditRows | Export-Csv -LiteralPath $auditCsv -NoTypeInformation -Encoding UTF8
    Write-Log "Audit CSV written: $auditCsv"

    $prDetails = @($Script:AuditData['ActivePrDetails'])
    if ($prDetails.Count -gt 0) {
        $prCsv = Join-Path $Script:AUDIT_DIR "active-prs-$($Script:RUN_ID).csv"
        $prDetails | Export-Csv -LiteralPath $prCsv -NoTypeInformation -Encoding UTF8
        Write-Log "Active PR CSV written: $prCsv" -Level WARN
    }

    # -- LFS disk-space requirement ----------------------------------------
    if (-not $SkipLfsVerification) {
        $lfsRepos   = @($auditRows | Where-Object { $_.NeedsLfs -eq 'RECOMMENDED' })
        $lfsTotalMb = ($lfsRepos | Measure-Object -Property SizeMB -Sum).Sum
        if (-not $lfsTotalMb) { $lfsTotalMb = 0 }
        # 2.5x buffer: working clone + LFS objects + headroom
        $lfsReqGB    = [math]::Round($lfsTotalMb * 2.5 / 1024, 1)
        $availableGB = Get-AvailableDiskSpaceGB -Path $OutputDir

        $Script:LfsDiskRequiredGB  = $lfsReqGB
        $Script:LfsDiskAvailableGB = $availableGB

        Write-Log "LFS disk requirement: $($lfsRepos.Count) LFS-recommended repo(s), ${lfsTotalMb} MB raw, ${lfsReqGB} GB required (2.5x buffer), ${availableGB} GB available."
        if ($availableGB -ge 0 -and $availableGB -lt $lfsReqGB) {
            Write-Log "Available disk space (${availableGB} GB) is below the recommended requirement (${lfsReqGB} GB) for LFS verification/fallback." -Level WARN
        }
    }

    # -- HTML dashboard ----------------------------------------------------
    Write-AuditDashboard -AuditRows @($auditRows)

    # -- Active PR gate ----------------------------------------------------
    $reposWithPrs = @($auditRows | Where-Object { $_.ActivePRs -gt 0 })
    if ($reposWithPrs.Count -gt 0) {
        foreach ($r in $reposWithPrs) {
            Write-Log "Repo '$($r.RepoName)' has $($r.ActivePRs) active PR(s). PRs migrate as read-only history." -Level WARN
        }
        if ($ForceWithActivePrs) {
            Write-Log 'ForceWithActivePrs set — continuing despite active PRs.' -Level WARN
        }
        elseif ([Environment]::UserInteractive -and -not $env:TF_BUILD -and -not $env:CI) {
            $choice = Read-Host 'Active PRs found. [S]kip affected repos, [F]orce continue, [A]bort all'
            switch ($choice.ToUpperInvariant()) {
                'F' { Write-Log 'User chose to FORCE — continuing.' -Level WARN }
                'S' {
                    $names = $reposWithPrs.RepoName
                    Write-Log "User chose to SKIP repos with active PRs: $($names -join ', ')" -Level WARN
                    $Script:SkipReposWithPrs = @($names)
                }
                default { throw 'Migration aborted by user due to active pull requests. Complete or abandon the PRs in ADO, or re-run with -ForceWithActivePrs.' }
            }
        }
        else {
            throw "Active pull requests found in $($reposWithPrs.Count) repo(s) and -ForceWithActivePrs was not set. Expected zero active PRs in CI mode. Fix: complete/abandon the PRs (see active-prs-$($Script:RUN_ID).csv) or re-run with -ForceWithActivePrs."
        }
    }
    else {
        Write-Log 'No active pull requests found — clear to migrate.' -Level SUCCESS
    }
}

function Write-AuditDashboard {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array] $AuditRows)

    $rows        = @($AuditRows)
    $total       = $rows.Count
    $totalSizeGb = [math]::Round((($rows | Measure-Object -Property SizeMB -Sum).Sum) / 1024, 2)
    $okCount     = @($rows | Where-Object { $_.MigrationRisk -eq 'OK' }).Count
    $largeCount  = @($rows | Where-Object { $_.MigrationRisk -eq 'LARGE' }).Count
    $xlargeCount = @($rows | Where-Object { $_.MigrationRisk -eq 'XLARGE' }).Count
    $criticalCount = @($rows | Where-Object { $_.MigrationRisk -eq 'CRITICAL' }).Count
    $warnCount   = @($rows | Where-Object { $_.MigrationRisk -eq 'WARN' }).Count
    $blockedCount = @($rows | Where-Object { $_.MigrationRisk -eq 'BLOCKED' }).Count
    $lfsCount    = @($rows | Where-Object { $_.NeedsLfs -eq 'RECOMMENDED' }).Count
    $activePrTotal = ($rows | Measure-Object -Property ActivePRs -Sum).Sum
    $alreadyInGh = @($rows | Where-Object { $_.AlreadyInGH -eq $true }).Count

    $riskColor = @{ BLOCKED = '#d73a49'; CRITICAL = '#7f1d1d'; XLARGE = '#e36209'; WARN = '#dbab09'; LARGE = '#dbab09'; OK = '#28a745' }
    $riskOrder = @{ BLOCKED = 0; CRITICAL = 1; XLARGE = 2; WARN = 3; LARGE = 4; OK = 5 }
    $sorted    = $rows | Sort-Object { $riskOrder[$_.MigrationRisk] }, { -$_.SizeMB }

    $lfsSectionHtml = if (-not $SkipLfsVerification -and $lfsCount -gt 0) {
        $usedPct  = if ($Script:LfsDiskRequiredGB -gt 0) { [math]::Min(100, [math]::Round(($Script:LfsDiskRequiredGB / [math]::Max($Script:LfsDiskAvailableGB, 0.01)) * 100)) } else { 0 }
        $boxClass = if ($Script:LfsDiskAvailableGB -ge $Script:LfsDiskRequiredGB) { 'ok-box' } else { 'warn-box' }
        $boxMsg   = if ($Script:LfsDiskAvailableGB -ge $Script:LfsDiskRequiredGB) { 'Sufficient disk space available.' } else { 'WARNING: available disk space may be insufficient for LFS verification/fallback.' }
        @"
<h2>LFS Disk Space Requirements</h2>
<p>LFS-recommended repos: <strong>$lfsCount</strong> &middot;
Recommended free disk (2.5x buffer): <strong>$($Script:LfsDiskRequiredGB) GB</strong> &middot;
Available: <strong>$($Script:LfsDiskAvailableGB) GB</strong></p>
<div class="bar-track"><div class="bar-fill" style="width:${usedPct}%;"></div></div>
<div class="$boxClass">$boxMsg</div>
"@
    } else { '' }

    $tableRows = foreach ($r in $sorted) {
        $riskColorVal = $riskColor[$r.MigrationRisk]
        "<tr><td>$($r.RepoName)</td><td>$($r.SizeMB)</td><td>$($r.BranchCount)</td><td>$($r.TagCount)</td><td>$($r.ActivePRs)</td><td>$($r.NeedsLfs)</td><td>$($r.AlreadyInGH)</td><td style='color:$riskColorVal;font-weight:bold'>$($r.MigrationRisk)</td></tr>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Pre-Migration Audit — Run $($Script:RUN_ID)</title>
<style>
 body{font-family:-apple-system,'Segoe UI',Roboto,sans-serif;margin:2rem;background:#f6f8fa;color:#24292e}
 h1{border-bottom:2px solid #0366d6;padding-bottom:.4rem}
 .cards{display:flex;flex-wrap:wrap;gap:1rem;margin:1.5rem 0}
 .card{flex:1;min-width:120px;padding:1.2rem;border-radius:8px;color:#fff;text-align:center;box-shadow:0 1px 3px rgba(0,0,0,.15)}
 .card h2{margin:0;font-size:2.2rem}.card p{margin:.3rem 0 0}
 .c-total{background:#0366d6}.c-blocked{background:#d73a49}.c-warn{background:#dbab09}.c-ok{background:#28a745}
 .c-size{background:#475569}.c-lfs{background:#e36209}.c-gh{background:#6f42c1}
 table{border-collapse:collapse;width:100%;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.1)}
 th,td{padding:.55rem .8rem;border:1px solid #e1e4e8;text-align:left}
 th{background:#24292e;color:#fff;cursor:pointer;user-select:none}
 tr:nth-child(even){background:#f6f8fa}
 .bar-track{background:#e5e7eb;border-radius:4px;height:14px;width:300px;overflow:hidden;}
 .bar-fill{background:#0366d6;height:100%;}
 .ok-box{background:#dcfce7;border:1px solid #16a34a;padding:8px 12px;border-radius:6px;margin-top:8px;}
 .warn-box{background:#fee2e2;border:1px solid #ef4444;padding:8px 12px;border-radius:6px;margin-top:8px;}
</style></head><body>
<h1>Pre-Migration Audit Dashboard</h1>
<p>Run <strong>$($Script:RUN_ID)</strong> &middot; Source <strong>$AdoOrg/$AdoProject</strong> &middot; Target <strong>$GitHubOrg</strong> &middot; Generated $((Get-Date).ToString('u'))</p>
<div class="cards">
  <div class="card c-total"><h2>$total</h2><p>Total Repos</p></div>
  <div class="card c-size"><h2>$totalSizeGb GB</h2><p>Total Size</p></div>
  <div class="card c-blocked"><h2>$blockedCount</h2><p>Blocked (Active PRs)</p></div>
  <div class="card c-warn"><h2>$($largeCount + $xlargeCount + $criticalCount + $warnCount)</h2><p>Warnings / Large+</p></div>
  <div class="card c-warn"><h2>$activePrTotal</h2><p>Total Active PRs</p></div>
  <div class="card c-ok"><h2>$okCount</h2><p>OK</p></div>
  <div class="card c-lfs"><h2>$lfsCount</h2><p>Needs LFS</p></div>
  <div class="card c-gh"><h2>$alreadyInGh</h2><p>Already in GitHub</p></div>
</div>
$lfsSectionHtml
<h2>Repository Detail</h2>
<table id="t">
<thead><tr><th onclick="s(0)">Repo</th><th onclick="s(1)">Size (MB)</th><th onclick="s(2)">Branches</th><th onclick="s(3)">Tags</th><th onclick="s(4)">Active PRs</th><th onclick="s(5)">Needs LFS</th><th onclick="s(6)">In GitHub</th><th onclick="s(7)">Risk</th></tr></thead>
<tbody>
$($tableRows -join "`n")
</tbody></table>
<script>
function s(c){const t=document.getElementById('t').tBodies[0];const r=[...t.rows];
const n=r.every(x=>!isNaN(parseFloat(x.cells[c].innerText)));
r.sort((a,b)=>n?parseFloat(a.cells[c].innerText)-parseFloat(b.cells[c].innerText)
:a.cells[c].innerText.localeCompare(b.cells[c].innerText));
r.forEach(x=>t.appendChild(x));}
</script>
</body></html>
"@
    $dashFile = Join-Path $Script:AUDIT_DIR "audit-dashboard-$($Script:RUN_ID).html"
    Set-Content -LiteralPath $dashFile -Value $html -Encoding UTF8
    Write-Log "Audit dashboard written: $dashFile" -Level SUCCESS
}
#endregion

#region 9 — REPO LIST RESOLUTION
# ============================================================================
$Script:SkipReposWithPrs = @()

function Restore-MigrationState {
    <#
    .SYNOPSIS
        Loads a previous migration-state-*.json and returns the Completed[] list.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Resume state file '$Path' not found. Expected a migration-state-*.json from a previous run. Fix: check the path under $OutputDir."
    }
    $state     = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $completed = @($state.Completed)
    $failed    = @($state.Failed)
    $skipped   = if ($state.PSObject.Properties.Name -contains 'Skipped') { @($state.Skipped) } else { @() }
    Write-Log "Restored state from '$Path': $($completed.Count) completed, $($failed.Count) failed, $($skipped.Count) skipped." -Level INFO
    return $completed
}

function Resolve-RepoList {
    [CmdletBinding()]
    param()

    Write-Section 'PHASE 2 — DISCOVERY'
    $list = [System.Collections.Generic.List[PSCustomObject]]::new()

    switch ($Mode) {
        'All' {
            $adoRepos = @(Get-AdoRepos)
            foreach ($r in $adoRepos) {
                if ($r.IsDisabled) {
                    Write-Log "Excluding disabled repo: $($r.Name)" -Level DEBUG
                    continue
                }
                $list.Add([PSCustomObject]@{
                    AdoRepo    = $r.Name
                    GitHubRepo = $r.Name
                    Lfs        = 'auto'
                    SizeMB     = $r.SizeMB
                    IsDisabled = $r.IsDisabled
                    DefaultBranch = $r.DefaultBranch
                })
            }
        }
        'Single' {
            if (-not $RepoName) {
                throw "Mode 'Single' requires -RepoName. Expected a repository name. Fix: add -RepoName <repo>."
            }
            $list.Add([PSCustomObject]@{
                AdoRepo = $RepoName; GitHubRepo = $RepoName; Lfs = 'auto'; SizeMB = 0; IsDisabled = $false; DefaultBranch = ''
            })
        }
        'Selected' {
            if (-not $RepoListFile -or -not (Test-Path -LiteralPath $RepoListFile)) {
                throw "Mode 'Selected' requires -RepoListFile pointing to an existing CSV (AdoRepo,GitHubRepo,Lfs). Got: '$RepoListFile'. Fix: supply a valid path, e.g. -RepoListFile ./repos.csv."
            }
            $csv = @(Import-Csv -LiteralPath $RepoListFile)
            if ($csv.Count -eq 0) {
                throw "Repo list file '$RepoListFile' is empty. Expected at least one row with columns AdoRepo,GitHubRepo,Lfs."
            }
            # Case-insensitive header matching
            $headers = @($csv[0].PSObject.Properties.Name)
            $hAdo = $headers | Where-Object { $_ -ieq 'AdoRepo' }    | Select-Object -First 1
            $hGh  = $headers | Where-Object { $_ -ieq 'GitHubRepo' } | Select-Object -First 1
            $hLfs = $headers | Where-Object { $_ -ieq 'Lfs' }        | Select-Object -First 1
            if (-not $hAdo -or -not $hGh) {
                throw "Repo list '$RepoListFile' is missing required columns. Expected headers AdoRepo,GitHubRepo(,Lfs); found: $($headers -join ', '). Fix: correct the CSV header row."
            }
            foreach ($row in $csv) {
                $list.Add([PSCustomObject]@{
                    AdoRepo    = $row.$hAdo
                    GitHubRepo = if ($row.$hGh) { $row.$hGh } else { $row.$hAdo }
                    Lfs        = if ($hLfs -and $row.$hLfs) { $row.$hLfs } else { 'no' }
                    SizeMB     = 0
                    IsDisabled = $false
                    DefaultBranch = ''
                })
            }
        }
    }

    $resolved = @($list)

    # Enrich Single/Selected entries with ADO size/default-branch metadata when available
    if ($Mode -ne 'All') {
        try {
            $adoRepos = @(Get-AdoRepos)
            foreach ($entry in $resolved) {
                $match = $adoRepos | Where-Object { $_.Name -ieq $entry.AdoRepo } | Select-Object -First 1
                if ($match) { $entry.SizeMB = $match.SizeMB; $entry.IsDisabled = $match.IsDisabled; $entry.DefaultBranch = $match.DefaultBranch }
            }
        }
        catch {
            Write-Log "Could not enrich repo metadata from ADO: $($_.Exception.Message)" -Level WARN
        }
    }

    # -- Resume filter -----------------------------------------------------
    if ($ResumeFromState) {
        $completed = @(Restore-MigrationState -Path $ResumeFromState)
        $before    = $resolved.Count
        $resolved  = @($resolved | Where-Object { $completed -notcontains $_.AdoRepo })
        Write-Log "Resume: filtered out $($before - $resolved.Count) already-completed repo(s) from state '$ResumeFromState'." -Level INFO
    }

    # -- Idempotency filter --------------------------------------------------
    if ($SkipExistingRepos) {
        Write-Step 'Checking for repos that already exist on GitHub (SkipExistingRepos)'
        $remaining = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($entry in $resolved) {
            if (Test-GitHubRepoExists -Repo $entry.GitHubRepo) {
                Write-Log "SKIP — $($entry.GitHubRepo) already exists on GitHub" -Level WARN
                $Script:Stats.Skipped++
                $Script:MigrationState.Skipped = @($Script:MigrationState.Skipped) + $entry.AdoRepo
                $Script:Results.Add(@{
                    RepoName = $entry.AdoRepo; GitHubRepo = $entry.GitHubRepo
                    Status = 'Skipped'; DurationSeconds = 0
                    Notes = 'Already exists on GitHub (SkipExistingRepos)'
                })
            }
            else {
                $remaining.Add($entry)
            }
        }
        $resolved = @($remaining)
    }

    Write-Log "Repositories queued for migration: $($resolved.Count)"
    return @($resolved)
}
#endregion

#region 10 — GEI MIGRATION
# ============================================================================
function Build-AdoArgs {
    <#
    .SYNOPSIS
        Builds the gh ado2gh migrate-repo argument array.
    .NOTES
        Uses $adoArgs — NOT $args — to avoid the PowerShell automatic-variable collision.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $RepoEntry)

    $adoArgs = @(
        'ado2gh', 'migrate-repo',
        '--ado-org',              $AdoOrg,
        '--ado-team-project',     $AdoProject,
        '--ado-repo',             $RepoEntry.AdoRepo,
        '--github-org',           $GitHubOrg,
        '--github-repo',          $RepoEntry.GitHubRepo,
        '--target-repo-visibility', 'private'
    )
    if ($GitHubEnterpriseHost) { $adoArgs += @('--ghes-api-url', $GitHubEnterpriseHost) }
    if ($VerboseMigration)     { $adoArgs += '--verbose' }
    return @($adoArgs)
}

function Invoke-PerRepoValidation {
    <#
    .SYNOPSIS
        Post-migration validation of a single repo: default-branch HEAD SHA,
        branch count, and tag count, ADO vs GitHub. Gated by -SkipPerRepoValidation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $AdoRepo,
        [Parameter(Mandatory)] [string] $GitHubRepo,
        [string] $DefaultBranchName
    )

    $issues = [System.Collections.Generic.List[string]]::new()

    $adoSha = if ($DefaultBranchName) { Get-AdoDefaultBranchSha -RepoName $AdoRepo -BranchName $DefaultBranchName } else { $null }
    $ghSha  = if ($DefaultBranchName) { Get-GitHubHeadSha -RepoName $GitHubRepo -BranchName $DefaultBranchName } else { $null }
    $shaMatch = ($adoSha -and $ghSha -and $adoSha -eq $ghSha)
    if ($DefaultBranchName -and -not $shaMatch) { $issues.Add("HEAD SHA mismatch (ADO:$adoSha GH:$ghSha)") }

    $adoBranches = Get-AdoBranchCount -RepoName $AdoRepo
    $ghBranches  = Get-GitHubBranchCount -RepoName $GitHubRepo
    $branchMatch = ($adoBranches -ge 0 -and $adoBranches -eq $ghBranches)
    if (-not $branchMatch) { $issues.Add("Branch count mismatch (ADO:$adoBranches GH:$ghBranches)") }

    $adoTags = Get-AdoTagCount -RepoName $AdoRepo
    $ghTags  = Get-GitHubTagCount -RepoName $GitHubRepo
    $tagMatch = ($adoTags -ge 0 -and $adoTags -eq $ghTags)
    if (-not $tagMatch) { $issues.Add("Tag count mismatch (ADO:$adoTags GH:$ghTags)") }

    $status = if ($issues.Count -eq 0) { 'VERIFIED' } else { 'ISSUES_FOUND' }
    $shortAdoSha = if ($adoSha) { $adoSha.Substring(0, 8) } else { 'n/a' }
    $shortGhSha  = if ($ghSha)  { $ghSha.Substring(0, 8) }  else { 'n/a' }

    if ($status -eq 'VERIFIED') {
        Write-Log "VERIFIED: $GitHubRepo | HEAD:$shortGhSha | Branches:$ghBranches | Tags:$ghTags" -Level SUCCESS
    }
    else {
        Write-Log "VALIDATION ISSUES: $GitHubRepo — $($issues -join '; ')" -Level WARN
    }

    return [PSCustomObject]@{
        AdoRepo       = $AdoRepo
        GitHubRepo    = $GitHubRepo
        DefaultBranch = $DefaultBranchName
        Status        = $status
        AdoHeadSha    = $shortAdoSha
        GHHeadSha     = $shortGhSha
        AdoBranches   = $adoBranches
        GHBranches    = $ghBranches
        AdoTags       = $adoTags
        GHTags        = $ghTags
        Issues        = ($issues -join '|')
    }
}

function Invoke-SingleMigration {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $RepoEntry)

    $start   = Get-Date
    $adoArgs = Build-AdoArgs -RepoEntry $RepoEntry
    $logFile = Join-Path $Script:LOGS_DIR "$($RepoEntry.GitHubRepo)-$($Script:RUN_ID).log"

    $output = (& $Script:GhCmd @adoArgs 2>&1) -join "`n"
    $ok     = ($LASTEXITCODE -eq 0)

    if ($ok) {
        # Download the GEI migration log for the record
        try {
            $mlogArgs = @('api', "/repos/$GitHubOrg/$($RepoEntry.GitHubRepo)/migration-log")
            $mlog = (& $Script:GhCmd @mlogArgs 2>&1) -join "`n"
            if ($LASTEXITCODE -eq 0 -and $mlog) {
                Set-Content -LiteralPath $logFile -Value $mlog -Encoding UTF8
            }
            else {
                Set-Content -LiteralPath $logFile -Value $output -Encoding UTF8
            }
        }
        catch {
            Set-Content -LiteralPath $logFile -Value $output -Encoding UTF8
        }
    }
    else {
        Set-Content -LiteralPath $logFile -Value $output -Encoding UTF8
    }

    return [PSCustomObject]@{
        RepoName        = $RepoEntry.AdoRepo
        GitHubRepo      = $RepoEntry.GitHubRepo
        Status          = if ($ok) { 'Succeeded' } else { 'Failed' }
        DurationSeconds = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
        LogFile         = $logFile
        ErrorMessage    = if ($ok) { '' } else { ($output -split "`n" | Select-Object -Last 5) -join ' | ' }
    }
}

function Invoke-WaveMigration {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array] $Wave)

    $waveRepos = @($Wave)

    # -- Dry run: simulate, never execute ------------------------------------
    if ($DryRun) {
        foreach ($entry in $waveRepos) {
            $adoArgs = Build-AdoArgs -RepoEntry $entry
            Write-Log "[DRY-RUN] Would migrate $($entry.AdoRepo) -> $GitHubOrg/$($entry.GitHubRepo)" -Level WARN
            Write-Log "[DRY-RUN]   Command: $Script:GhCmd $($adoArgs -join ' ')" -Level DEBUG
            $Script:Stats.Skipped++
            $Script:MigrationState.Skipped = @($Script:MigrationState.Skipped) + $entry.AdoRepo
            $Script:Results.Add(@{
                RepoName = $entry.AdoRepo; GitHubRepo = $entry.GitHubRepo
                Status = 'Skipped'; DurationSeconds = 0; Notes = 'Dry run — simulated only'
            })
        }
        return
    }

    # -- Real run: RunspacePool concurrency ------------------------------------
    $rsPool = [System.Management.Automation.Runspaces.RunspacePool]::CreateRunspacePool(1, $ConcurrentJobs)
    $rsPool.Open()

    # Self-contained worker: no external function marshalling — everything passed in.
    $worker = {
        param(
            [string] $GhCmd,
            [string[]] $MigrateArgs,
            [string] $AdoRepoName,
            [string] $GitHubOrgName,
            [string] $GitHubRepoName,
            [string] $LogFilePath
        )
        $start  = Get-Date
        $output = (& $GhCmd @MigrateArgs 2>&1) -join "`n"
        $ok     = ($LASTEXITCODE -eq 0)

        if ($ok) {
            try {
                $mlog = (& $GhCmd api "/repos/$GitHubOrgName/$GitHubRepoName/migration-log" 2>&1) -join "`n"
                if ($LASTEXITCODE -eq 0 -and $mlog) { Set-Content -LiteralPath $LogFilePath -Value $mlog -Encoding UTF8 }
                else { Set-Content -LiteralPath $LogFilePath -Value $output -Encoding UTF8 }
            }
            catch { Set-Content -LiteralPath $LogFilePath -Value $output -Encoding UTF8 }
        }
        else {
            Set-Content -LiteralPath $LogFilePath -Value $output -Encoding UTF8
        }

        [PSCustomObject]@{
            RepoName        = $AdoRepoName
            GitHubRepo      = $GitHubRepoName
            Status          = if ($ok) { 'Succeeded' } else { 'Failed' }
            DurationSeconds = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
            LogFile         = $LogFilePath
            ErrorMessage    = if ($ok) { '' } else { (($output -split "`n") | Select-Object -Last 5) -join ' | ' }
        }
    }

    $handles = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($entry in $waveRepos) {
        if (@($Script:SkipReposWithPrs) -contains $entry.AdoRepo) {
            Write-Log "SKIP — $($entry.AdoRepo) skipped per active-PR decision" -Level WARN
            $Script:Stats.Skipped++
            $Script:MigrationState.Skipped = @($Script:MigrationState.Skipped) + $entry.AdoRepo
            $Script:Results.Add(@{
                RepoName = $entry.AdoRepo; GitHubRepo = $entry.GitHubRepo
                Status = 'Skipped'; DurationSeconds = 0; Notes = 'Skipped due to active PRs'
            })
            continue
        }

        $Script:MigrationState.InProgress = @($Script:MigrationState.InProgress) + $entry.AdoRepo
        Write-Step "Queueing migration: $($entry.AdoRepo) -> $GitHubOrg/$($entry.GitHubRepo)"

        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $rsPool
        $null = $ps.AddScript($worker).
            AddArgument($Script:GhCmd).
            AddArgument((Build-AdoArgs -RepoEntry $entry)).
            AddArgument($entry.AdoRepo).
            AddArgument($GitHubOrg).
            AddArgument($entry.GitHubRepo).
            AddArgument((Join-Path $Script:LOGS_DIR "$($entry.GitHubRepo)-$($Script:RUN_ID).log"))

        $handles.Add(@{ Ps = $ps; Handle = $ps.BeginInvoke(); Entry = $entry })
    }

    foreach ($h in $handles) {
        $entry = $h.Entry
        try {
            # EndInvoke returns PSDataCollection — extract via [0] with null guard
            $resultCollection = $h.Ps.EndInvoke($h.Handle)
            $result = if ($null -ne $resultCollection -and $resultCollection.Count -gt 0) { $resultCollection[0] } else { $null }

            if ($null -eq $result) {
                Write-Log "Migration of '$($entry.AdoRepo)' returned no result object — treating as FAILED. Check migration-logs/ for detail." -Level ERROR
                $Script:Stats.Failed++
                $Script:MigrationState.Failed = @($Script:MigrationState.Failed) + $entry.AdoRepo
                $Script:Results.Add(@{
                    RepoName = $entry.AdoRepo; GitHubRepo = $entry.GitHubRepo
                    Status = 'Failed'; DurationSeconds = 0; Notes = 'No result returned from runspace'
                })
            }
            elseif ($result.Status -eq 'Succeeded') {
                Write-Log "SUCCEEDED: $($result.RepoName) -> $GitHubOrg/$($result.GitHubRepo) in $($result.DurationSeconds)s" -Level SUCCESS
                $Script:Stats.Succeeded++
                $Script:MigrationState.Completed = @($Script:MigrationState.Completed) + $entry.AdoRepo
                $Script:Results.Add(@{
                    RepoName = $result.RepoName; GitHubRepo = $result.GitHubRepo
                    Status = 'Succeeded'; DurationSeconds = $result.DurationSeconds; Notes = ''
                })

                if (-not $SkipPerRepoValidation) {
                    $auditRow = $Script:AuditResults | Where-Object { $_.RepoName -eq $entry.AdoRepo } | Select-Object -First 1
                    $defaultBranchName = if ($auditRow -and $auditRow.DefaultBranch) { $auditRow.DefaultBranch } elseif ($DefaultBranch) { $DefaultBranch } else { $null }
                    $validation = Invoke-PerRepoValidation -AdoRepo $entry.AdoRepo -GitHubRepo $entry.GitHubRepo -DefaultBranchName $defaultBranchName
                    $Script:ValidationResults.Add($validation)
                }
            }
            else {
                Write-Log "FAILED: $($result.RepoName) — $($result.ErrorMessage). Log: $($result.LogFile)" -Level ERROR
                $Script:Stats.Failed++
                $Script:MigrationState.Failed = @($Script:MigrationState.Failed) + $entry.AdoRepo
                $Script:Results.Add(@{
                    RepoName = $result.RepoName; GitHubRepo = $result.GitHubRepo
                    Status = 'Failed'; DurationSeconds = $result.DurationSeconds; Notes = $result.ErrorMessage
                })
            }
        }
        catch {
            Write-Log "Runspace error for '$($entry.AdoRepo)': $($_.Exception.Message)" -Level ERROR
            $Script:Stats.Failed++
            $Script:MigrationState.Failed = @($Script:MigrationState.Failed) + $entry.AdoRepo
            $Script:Results.Add(@{
                RepoName = $entry.AdoRepo; GitHubRepo = $entry.GitHubRepo
                Status = 'Failed'; DurationSeconds = 0; Notes = $_.Exception.Message
            })
        }
        finally {
            $Script:MigrationState.InProgress = @(@($Script:MigrationState.InProgress) | Where-Object { $_ -ne $entry.AdoRepo })
            $h.Ps.Dispose()
        }
    }

    $rsPool.Close()
    $rsPool.Dispose()

    Write-Log "Wave complete — Succeeded: $($Script:Stats.Succeeded)  Failed: $($Script:Stats.Failed)  Skipped: $($Script:Stats.Skipped)"
}
#endregion

#region 11 — BRANCH + TAG VERIFICATION
# ============================================================================
function Invoke-RepoVerification {
    <#
    .SYNOPSIS
        Bulk branch + tag count comparison, ADO vs GitHub, for a list of
        {AdoRepo, GitHubRepo} entries. Exports repo-verification-*.csv.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array] $RepoList)

    $rows = foreach ($repo in @($RepoList)) {
        $adoBranches = Get-AdoBranchCount -RepoName $repo.AdoRepo
        $ghBranches  = Get-GitHubBranchCount -RepoName $repo.GitHubRepo
        $adoTags     = Get-AdoTagCount -RepoName $repo.AdoRepo
        $ghTags      = Get-GitHubTagCount -RepoName $repo.GitHubRepo
        $branchMatch = ($adoBranches -ge 0 -and $adoBranches -eq $ghBranches)
        $tagMatch    = ($adoTags -ge 0 -and $adoTags -eq $ghTags)

        [PSCustomObject]@{
            Repository   = $repo.GitHubRepo
            AdoBranches  = $adoBranches
            GHBranches   = $ghBranches
            BranchMatch  = $branchMatch
            AdoTags      = $adoTags
            GHTags       = $ghTags
            TagMatch     = $tagMatch
            OverallMatch = ($branchMatch -and $tagMatch)
        }
    }

    $csv = Join-Path $Script:AUDIT_DIR "repo-verification-$($Script:RUN_ID).csv"
    $rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    Write-Log "Branch/tag verification CSV written: $csv"
    return @($rows)
}

function Invoke-BranchVerification {
    [CmdletBinding()]
    param()

    Write-Section 'PHASE 5 — BRANCH + TAG VERIFICATION'
    $migrated = @($Script:Results | Where-Object { $_.Status -eq 'Succeeded' })
    if ($migrated.Count -eq 0) {
        Write-Log 'No successfully migrated repos to verify.' -Level INFO
        return
    }

    $repoEntries = foreach ($r in $migrated) { [PSCustomObject]@{ AdoRepo = $r.RepoName; GitHubRepo = $r.GitHubRepo } }
    $rows = Invoke-RepoVerification -RepoList @($repoEntries)

    foreach ($repo in $migrated) {
        $match = $rows | Where-Object { $_.Repository -eq $repo.GitHubRepo } | Select-Object -First 1
        if (-not $match) { continue }
        if ($match.OverallMatch) {
            Write-Log "PASS: $($repo.RepoName) — $($match.AdoBranches) branches / $($match.AdoTags) tags on both sides" -Level SUCCESS
        }
        else {
            Write-Log "MISMATCH: $($repo.RepoName) — ADO=$($match.AdoBranches)br/$($match.AdoTags)tg GitHub=$($match.GHBranches)br/$($match.GHTags)tg. Fix: inspect refs manually; GEI skips some ref types (e.g. stale refs/pull)." -Level WARN
        }
        # Attach to results for the HTML report
        $repo['Branches'] = "$($match.AdoBranches) / $($match.GHBranches)"
        $repo['Tags']     = "$($match.AdoTags) / $($match.GHTags)"
    }
}
#endregion

#region 12 — LFS VERIFICATION
# ============================================================================
function Invoke-LfsVerification {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $RepoEntry)

    $ghRepo  = $RepoEntry.GitHubRepo
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "lfs-verify-$(New-Guid)"
    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $cloneUrl    = "https://oauth2:$($env:GH_PAT)@github.com/$GitHubOrg/$ghRepo.git"
        $cloneOutput = (git clone --depth 1 $cloneUrl $tempDir) 2>&1
        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject]@{ Repo = $ghRepo; Status = 'CloneFailed'; LfsPresent = 0; LfsMissing = 0; Error = ($cloneOutput | Out-String).Trim() }
        }

        git -C $tempDir lfs pull 2>&1 | Out-Null
        $lsOutput = (git -C $tempDir lfs ls-files) 2>&1
        $present  = @($lsOutput | Select-String -Pattern '^\w+ \*').Count
        $missing  = @($lsOutput | Select-String -Pattern '^\w+ -').Count

        return [PSCustomObject]@{ Repo = $ghRepo; Status = 'Success'; LfsPresent = $present; LfsMissing = $missing; Error = $null }
    }
    catch {
        return [PSCustomObject]@{ Repo = $ghRepo; Status = 'Error'; LfsPresent = 0; LfsMissing = 0; Error = $_.Exception.Message }
    }
    finally {
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
}

function Invoke-LfsFallbackPush {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $RepoEntry)

    $adoRepo    = $RepoEntry.AdoRepo
    $ghRepo     = $RepoEntry.GitHubRepo
    $tempDir    = Join-Path ([System.IO.Path]::GetTempPath()) "lfs-fallback-$(New-Guid)"
    $adoCloneUrl = $null

    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        Write-Log "[LFS fallback 1/4] Full clone from ADO: $adoRepo"
        $encodedProject = [uri]::EscapeDataString($AdoProject)
        $adoCloneUrl = "https://pat:$($env:ADO_PAT)@dev.azure.com/$AdoOrg/$encodedProject/_git/$adoRepo"
        git clone $adoCloneUrl $tempDir 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "ADO clone failed for $adoRepo" }

        Write-Log "[LFS fallback 2/4] Fetching all LFS objects from ADO origin"
        git -C $tempDir lfs fetch --all origin 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "LFS fetch failed for $adoRepo" }

        Write-Log "[LFS fallback 3/4] Adding GitHub remote"
        $ghPushUrl = "https://oauth2:$($env:GH_PAT)@github.com/$GitHubOrg/$ghRepo.git"
        git -C $tempDir remote add github $ghPushUrl 2>&1 | Out-Null

        Write-Log "[LFS fallback 4/4] Pushing all LFS objects to GitHub"
        git -C $tempDir lfs push github --all 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "LFS push failed for $ghRepo" }

        return $true
    }
    catch {
        Write-Log "LFS fallback failed for $ghRepo`: $($_.Exception.Message)" -Level ERROR
        Write-Log "Manual recovery: git clone $adoCloneUrl; git -C <dir> lfs fetch --all; git -C <dir> lfs push https://github.com/$GitHubOrg/$ghRepo.git --all" -Level WARN
        return $false
    }
    finally {
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
}

function Invoke-LfsPhase {
    <#
    .SYNOPSIS
        Orchestrates LFS verification and (on failure, interactively) fallback
        push for successfully-migrated repos flagged NeedsLfs = RECOMMENDED.
        Gated by -SkipLfsVerification; a no-op in DryRun.
    #>
    [CmdletBinding()]
    param()

    if ($SkipLfsVerification -or $DryRun) { return }

    $migrated = @($Script:Results | Where-Object { $_.Status -eq 'Succeeded' })
    if ($migrated.Count -eq 0) { return }

    $needsLfsNames = @($Script:AuditResults | Where-Object { $_.NeedsLfs -eq 'RECOMMENDED' } | Select-Object -ExpandProperty RepoName)
    $needsLfsRepos = @($migrated | Where-Object { $needsLfsNames -contains $_.RepoName } | ForEach-Object {
        [PSCustomObject]@{ AdoRepo = $_.RepoName; GitHubRepo = $_.GitHubRepo }
    })
    if ($needsLfsRepos.Count -eq 0) { return }

    $availableGB = Get-AvailableDiskSpaceGB -Path $OutputDir
    if ($availableGB -ge 0 -and $availableGB -lt 1) {
        Write-Log "Skipping LFS verification — available disk space (${availableGB} GB) below 1 GB minimum." -Level WARN
        return
    }

    Write-Section 'PHASE 5b — LFS VERIFICATION'
    $lfsResults = foreach ($r in $needsLfsRepos) { Invoke-LfsVerification -RepoEntry $r }
    $lfsCsv = Join-Path $Script:AUDIT_DIR "lfs-verification-$($Script:RUN_ID).csv"
    $lfsResults | Export-Csv -LiteralPath $lfsCsv -NoTypeInformation -Encoding UTF8
    Write-Log "LFS verification CSV written: $lfsCsv"

    $lfsFailures = @($lfsResults | Where-Object { $_.Status -ne 'Success' -or $_.LfsMissing -gt 0 })
    if ($lfsFailures.Count -eq 0) {
        Write-Log 'All LFS-recommended repos verified clean.' -Level SUCCESS
        return
    }

    Write-Log "$($lfsFailures.Count) repo(s) have LFS issues." -Level WARN
    $attemptFallback = $false
    if ([Environment]::UserInteractive -and -not $env:TF_BUILD -and -not $env:CI) {
        $choice = Read-Host "$($lfsFailures.Count) repo(s) have LFS issues. Attempt fallback push? [Y/N]"
        $attemptFallback = ($choice.ToUpperInvariant() -eq 'Y')
    }
    else {
        Write-Log 'Non-interactive session — skipping LFS fallback prompt. Manual recovery required (see below).' -Level WARN
    }

    if ($attemptFallback) {
        $diskGB = Get-AvailableDiskSpaceGB -Path $OutputDir
        if ($diskGB -ge 0 -and $diskGB -lt $Script:LfsDiskRequiredGB) {
            Write-Log "Insufficient disk space for LFS fallback (${diskGB} GB available, $($Script:LfsDiskRequiredGB) GB required)." -Level WARN
        }
        foreach ($failed in $lfsFailures) {
            $entry = $needsLfsRepos | Where-Object { $_.GitHubRepo -eq $failed.Repo } | Select-Object -First 1
            if ($entry) {
                $ok = Invoke-LfsFallbackPush -RepoEntry $entry
                if (-not $ok) {
                    Write-Log "Manual recovery required for $($entry.GitHubRepo). See log file for commands." -Level WARN
                }
            }
        }
    }
    else {
        foreach ($failed in $lfsFailures) {
            Write-Log "Manual LFS recovery for $($failed.Repo): git clone <ado-url>; git lfs fetch --all; git remote add github <gh-url>; git lfs push github --all" -Level WARN
        }
    }
}
#endregion

#region 13 — POST-MIGRATION CONFIGURATION
# ============================================================================
function Invoke-DownloadMigrationLogs {
    <#
    .SYNOPSIS
        Downloads the gh ado2gh diagnostic log bundle per migrated repo
        (distinct from the per-repo /migration-log REST snapshot already
        captured inline during Invoke-WaveMigration).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [array] $MigratedList)

    if (@($MigratedList).Count -eq 0) { return }
    Write-Step 'Downloading gh ado2gh diagnostic logs'
    foreach ($repo in @($MigratedList)) {
        try {
            $dlArgs = @('ado2gh', 'download-logs', '--github-org', $GitHubOrg, '--github-repo', $repo.GitHubRepo)
            $out = (& $Script:GhCmd @dlArgs 2>&1) -join "`n"
            if ($LASTEXITCODE -eq 0) {
                Set-Content -LiteralPath (Join-Path $Script:LOGS_DIR "$($repo.GitHubRepo)-ado2gh-diagnostics.log") -Value $out -Encoding UTF8
            }
            else {
                Write-Log "Could not download ado2gh diagnostic log for $($repo.GitHubRepo): $out" -Level WARN
            }
        }
        catch {
            Write-Log "Could not download ado2gh diagnostic log for $($repo.GitHubRepo): $($_.Exception.Message)" -Level WARN
        }
    }
}

function Invoke-PostMigrationConfig {
    [CmdletBinding()]
    param()

    Write-Section 'PHASE 6 — POST-MIGRATION CONFIGURATION'
    $migrated = @($Script:Results | Where-Object { $_.Status -eq 'Succeeded' })

    if ($SkipPostConfig) {
        Write-Log 'SkipPostConfig set — skipping branch protection / team access / branch rename / custom properties.' -Level WARN
    }
    else {
        if ($CustomProperties -and $CustomProperties.Count -gt 0) {
            Initialize-CustomPropertySchema -PropertyNames @($CustomProperties.Keys)
        }
        if ($SetAdoMetadata) {
            Initialize-CustomPropertySchema -PropertyNames @('ado-origin-org', 'ado-origin-project', 'ado-origin-repo')
        }

        foreach ($repo in $migrated) {
            $ghRepo = $repo.GitHubRepo
            try {
                # Determine current default branch
                $current        = Invoke-GitHubApi -Endpoint "/repos/$GitHubOrg/$ghRepo"
                $currentDefault = if ($current -and ($current.PSObject.Properties.Name -contains 'default_branch')) { $current.default_branch } else { 'main' }

                # 1. Rename default branch first if requested (protection then lands on it)
                if ($DefaultBranch -and $DefaultBranch -ne $currentDefault) {
                    if (Set-GitHubDefaultBranch -RepoName $ghRepo -Branch $DefaultBranch) {
                        Write-Log "Default branch renamed: $ghRepo $currentDefault -> $DefaultBranch" -Level SUCCESS
                        $currentDefault = $DefaultBranch
                    }
                }

                # 2. Branch protection
                $null = Set-BranchProtection -Repo $ghRepo -Branch $currentDefault

                # 3. Team access
                Grant-TeamAccess -Repo $ghRepo

                # 4. Custom properties
                if ($CustomProperties -and $CustomProperties.Count -gt 0) {
                    Set-RepoCustomProperties -RepoName $ghRepo -Properties $CustomProperties
                }
                if ($SetAdoMetadata) {
                    Set-RepoCustomProperties -RepoName $ghRepo -Properties @{
                        'ado-origin-org'     = $AdoOrg
                        'ado-origin-project' = $AdoProject
                        'ado-origin-repo'    = $repo.RepoName
                    }
                }

                Write-Log "$ghRepo`: post-migration configuration applied." -Level SUCCESS
            }
            catch {
                Write-Log "$ghRepo`: post-migration configuration failed - $($_.Exception.Message)" -Level WARN
            }
        }
    }

    Invoke-DownloadMigrationLogs -MigratedList $migrated

    Write-Section 'PHASE 7 — PIPELINE & DEVELOPER GUIDES'
    if (-not $SkipPipelineUpdate) { Write-PipelineGuide }
    Write-MannequinGuide
}

function Write-PipelineGuide {
    [CmdletBinding()]
    param()

    $outRoot = Split-Path -Parent $Script:LOG_FILE

    $yamlGuide = @"
# ============================================================================
# pipeline-update-guide.yml — Run $($Script:RUN_ID)
# How to point an existing ADO pipeline at the migrated GitHub repository.
#
# Preferred: use scripts/4_Rewire-Pipeline.ps1 (gh ado2gh rewire-pipeline),
# which performs this change via the ADO REST API automatically.
# Manual equivalent below.
# ============================================================================

# BEFORE — checkout from Azure Repos (implicit self checkout):
# steps:
#   - checkout: self

# AFTER — checkout from GitHub via a GitHub service connection:
resources:
  repositories:
    - repository: migratedRepo
      type: github
      name: $GitHubOrg/<github-repo>          # e.g. $GitHubOrg/app-service-1
      endpoint: $ServiceConnectionName          # GitHub service connection name

steps:
  - checkout: migratedRepo
    persistCredentials: true
"@
    $yamlPath = Join-Path $outRoot 'pipeline-update-guide.yml'
    Set-Content -LiteralPath $yamlPath -Value $yamlGuide -Encoding UTF8
    Write-Log "Pipeline update guide written: $yamlPath" -Level SUCCESS

    $migrated = @($Script:Results | Where-Object { $_.Status -eq 'Succeeded' })
    $remoteLines = foreach ($m in $migrated) {
        "    '$($m.RepoName)' = 'https://github.com/$GitHubOrg/$($m.GitHubRepo).git'"
    }

    $devScript = @"
#Requires -Version 5.1
<#
.SYNOPSIS
    Updates the 'origin' remote of a local clone to the new GitHub URL.
.DESCRIPTION
    Generated by Invoke-GHEMigration v$($Script:VERSION) — run $($Script:RUN_ID).
    Run from inside a repository working copy, or pass -RepoPath.
.EXAMPLE
    ./Update-DevRemote.ps1 -RepoPath C:\src\app-service-1
#>
param([string] `$RepoPath = (Get-Location).Path)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

`$map = @{
$($remoteLines -join "`n")
}

`$name = Split-Path -Leaf `$RepoPath
if (-not `$map.ContainsKey(`$name)) {
    Write-Warning "Repo '`$name' not in the migrated set. Known repos: `$(`$map.Keys -join ', ')"
    return
}
Push-Location `$RepoPath
try {
    git remote set-url origin `$map[`$name]
    Write-Host "origin now points to `$(`$map[`$name])" -ForegroundColor Green
    git fetch origin --prune
}
finally { Pop-Location }
"@
    $devPath = Join-Path $outRoot 'Update-DevRemote.ps1'
    Set-Content -LiteralPath $devPath -Value $devScript -Encoding UTF8
    Write-Log "Developer remote-update script written: $devPath" -Level SUCCESS
}

function Write-MannequinGuide {
    [CmdletBinding()]
    param()

    Write-Log '--- MANNEQUIN RECLAIM (manual post-migration step) ---'
    Write-Log "1. Generate the mannequin CSV:   gh ado2gh generate-mannequin-csv --github-org $GitHubOrg --output mannequins.csv"
    Write-Log '2. Edit mannequins.csv — map each mannequin-user to the real GitHub login in the target-user column.'
    Write-Log "3. Reclaim:                      gh ado2gh reclaim-mannequin --github-org $GitHubOrg --csv mannequins.csv"
    Write-Log '4. Users receive an attribution invitation (EMU: use --skip-invitation where applicable).'
    Write-Log 'Until reclaimed, migrated commits/PRs are attributed to placeholder mannequin identities.'
}

function Write-HtmlReport {
    [CmdletBinding()]
    param()

    Write-Section 'PHASE 8 — REPORT'
    $duration = (Get-Date) - $Script:START_TIME
    $durationText = '{0:hh\:mm\:ss}' -f $duration

    $rowsHtml = foreach ($r in @($Script:Results)) {
        $cls = switch ($r.Status) {
            'Succeeded' { 'ok' } 'Failed' { 'bad' } default { 'skip' }
        }
        $branches = if ($r.ContainsKey('Branches')) { $r.Branches } else { '-' }
        $tags     = if ($r.ContainsKey('Tags')) { $r.Tags } else { '-' }
        $notes    = if ($r.ContainsKey('Notes') -and $r.Notes) { [System.Net.WebUtility]::HtmlEncode([string]$r.Notes) } else { '' }
        "<tr class='$cls'><td>$($r.RepoName)</td><td>$AdoOrg/$AdoProject</td><td>$GitHubOrg/$($r.GitHubRepo)</td><td>$($r.Status)</td><td>$($r.DurationSeconds)s</td><td>$branches</td><td>$tags</td><td>$notes</td></tr>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Migration Report — $($Script:RUN_ID)</title>
<style>
 body{font-family:-apple-system,'Segoe UI',Roboto,sans-serif;margin:2rem;background:#f6f8fa;color:#24292e}
 h1{border-bottom:2px solid #0366d6;padding-bottom:.4rem}
 .cards{display:flex;gap:1rem;margin:1.5rem 0}
 .card{flex:1;padding:1.2rem;border-radius:8px;color:#fff;text-align:center}
 .card h2{margin:0;font-size:2.2rem}.card p{margin:.3rem 0 0}
 .c-t{background:#0366d6}.c-s{background:#28a745}.c-f{background:#d73a49}.c-k{background:#dbab09}.c-d{background:#6f42c1}
 table{border-collapse:collapse;width:100%;background:#fff}
 th,td{padding:.55rem .8rem;border:1px solid #e1e4e8;text-align:left}
 th{background:#24292e;color:#fff}
 tr.ok{background:#e6ffed}tr.bad{background:#ffeef0}tr.skip{background:#fff8e1}
 footer{margin-top:2rem;padding:1rem;background:#fff;border-left:4px solid #0366d6}
</style></head><body>
<h1>ADO &rarr; GitHub Migration Report</h1>
<p>Run <strong>$($Script:RUN_ID)</strong> &middot; Mode <strong>$Mode</strong> &middot; $((Get-Date).ToString('u'))<br>
Source <strong>$AdoOrg/$AdoProject</strong> &rarr; Target <strong>$GitHubOrg</strong>$(if ($DryRun) { ' &middot; <strong style="color:#dbab09">DRY RUN</strong>' })</p>
<div class="cards">
  <div class="card c-t"><h2>$($Script:Stats.Total)</h2><p>Total</p></div>
  <div class="card c-s"><h2>$($Script:Stats.Succeeded)</h2><p>Succeeded</p></div>
  <div class="card c-f"><h2>$($Script:Stats.Failed)</h2><p>Failed</p></div>
  <div class="card c-k"><h2>$($Script:Stats.Skipped)</h2><p>Skipped</p></div>
  <div class="card c-d"><h2>$durationText</h2><p>Duration</p></div>
</div>
<table>
<thead><tr><th>Repo</th><th>ADO Source</th><th>GitHub Target</th><th>Status</th><th>Duration</th><th>Branches (ADO/GH)</th><th>Tags (ADO/GH)</th><th>Notes</th></tr></thead>
<tbody>
$($rowsHtml -join "`n")
</tbody></table>
<footer>
<h3>Next steps</h3>
<ol>
<li><strong>Mannequin reclaim</strong>: <code>gh ado2gh generate-mannequin-csv --github-org $GitHubOrg --output mannequins.csv</code> then <code>gh ado2gh reclaim-mannequin --csv mannequins.csv</code></li>
<li><strong>Pipeline reconnection</strong>: run <code>scripts/4_Rewire-Pipeline.ps1</code> against pipelines.csv</li>
<li><strong>Developer remotes</strong>: distribute <code>Update-DevRemote.ps1</code> to repo teams</li>
</ol>
</footer>
</body></html>
"@
    Set-Content -LiteralPath $Script:REPORT_FILE -Value $html -Encoding UTF8
    Write-Log "HTML report written: $Script:REPORT_FILE" -Level SUCCESS
}

function Save-MigrationState {
    [CmdletBinding()]
    param()
    $Script:MigrationState | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $Script:STATE_FILE -Encoding UTF8
    Write-Log "State saved: $Script:STATE_FILE" -Level DEBUG
}
#endregion

# ============================================================================
# MAIN EXECUTION
# ============================================================================
try {
    Import-ConfigFile
    Resolve-LocalTools
    Initialize-Environment
    Resolve-Credentials
    $null = Test-Prerequisites
    Test-GitHubPatPermissions

    $repoList = @(Resolve-RepoList)
    $Script:Stats.Total = @($repoList).Count + $Script:Stats.Skipped

    if (-not $SkipAudit -and @($repoList).Count -gt 0) { Invoke-PreMigrationAudit -RepoList @($repoList) }

    if (@($repoList).Count -eq 0) {
        Write-Log 'No repositories to migrate.' -Level WARN
    }
    else {
        Write-Section 'PHASE 4 — MIGRATION'
        # Split into waves
        $effectiveWave = if ($WaveSize -le 0) { @($repoList).Count } else { $WaveSize }
        $waves = for ($i = 0; $i -lt @($repoList).Count; $i += [Math]::Max(1, $effectiveWave)) {
            , @($repoList[$i..([Math]::Min($i + $effectiveWave - 1, @($repoList).Count - 1))])
        }
        $waves   = @($waves)
        $waveNum = 0
        foreach ($wave in $waves) {
            $waveNum++
            Write-Section "WAVE $waveNum of $($waves.Count)  ($(@($wave).Count) repos)"
            Invoke-WaveMigration -Wave @($wave)
            Save-MigrationState
            if ($waveNum -lt $waves.Count -and $WaveDelaySeconds -gt 0) {
                Write-Log "Pausing $WaveDelaySeconds seconds before next wave (secondary rate-limit protection)..." -Level INFO
                Start-Sleep -Seconds $WaveDelaySeconds
            }
        }
    }

    if (-not $SkipBranchVerification) { Invoke-BranchVerification }

    Invoke-LfsPhase

    if ($Script:ValidationResults.Count -gt 0) {
        $valCsv = Join-Path $Script:AUDIT_DIR "per-repo-validation-$($Script:RUN_ID).csv"
        $Script:ValidationResults | Export-Csv -LiteralPath $valCsv -NoTypeInformation -Encoding UTF8
        $verifiedCount = @($Script:ValidationResults | Where-Object { $_.Status -eq 'VERIFIED' }).Count
        Write-Log "Per-repo validation summary: $verifiedCount/$($Script:ValidationResults.Count) VERIFIED. CSV: $valCsv"
    }

    Invoke-PostMigrationConfig
    Write-HtmlReport
    Save-MigrationState

    Write-Section 'MIGRATION COMPLETE'
    Write-Log "Total: $($Script:Stats.Total)  Succeeded: $($Script:Stats.Succeeded)  Failed: $($Script:Stats.Failed)  Skipped: $($Script:Stats.Skipped)  Warnings: $($Script:Stats.Warnings)" -Level SUCCESS
    Write-Log "Report: $Script:REPORT_FILE" -Level INFO
    Write-Log "State:  $Script:STATE_FILE" -Level INFO

    if ($Script:Stats.Failed -gt 0) {
        Write-Log 'Failed repositories:' -Level ERROR
        foreach ($f in $Script:MigrationState.Failed) { Write-Log "  - $f" -Level ERROR }
        Write-Log "Resume with: -ResumeFromState '$($Script:STATE_FILE)'" -Level WARN
        exit 1
    }
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    if ($Script:LOG_FILE) { Write-Log ($_.ScriptStackTrace | Out-String) -Level DEBUG }
    exit 1
}
