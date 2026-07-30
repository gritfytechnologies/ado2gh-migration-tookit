#Requires -Version 7.0
<#
.SYNOPSIS
    Rewires Azure DevOps pipelines to point at migrated GitHub repositories
    using 'gh ado2gh rewire-pipeline'.

.DESCRIPTION
    Two modes:

    CSV mode (default): reads pipelines.csv
      (org,teamproject,repo,pipeline,github_org,github_repo,serviceConnection)
      and rewires every pipeline whose repo migrated successfully according to
      repos_with_status.csv (MigrationStatus = "Success"). Use -SkipStatusCheck
      to bypass the status filter.

    Inline single-repo mode: pass -AdoOrg/-AdoProject/-RepoName/-GitHubOrg/
      -GitHubRepo/-ServiceConnectionId to rewire pipelines for one repo without
      a CSV.

    Placeholder service connection values (your-service-connection-id,
    placeholder, TODO, TBD, xxx, empty) abort the run.

.PARAMETER PipelinesCsvPath
    Path to pipelines.csv (CSV mode).

.PARAMETER RepoStatusCsvPath
    Path to repos_with_status.csv produced post-migration.

.PARAMETER SelectedRepos
    Optional repo-name filter (CSV mode).

.PARAMETER SelectedPipelines
    Optional pipeline-name filter (CSV mode).

.PARAMETER SkipStatusCheck
    Skip the repos_with_status.csv migration-success filter.

.PARAMETER AdoOrg
    Inline mode: ADO organization.

.PARAMETER AdoProject
    Inline mode: ADO team project.

.PARAMETER RepoName
    Inline mode: ADO repository name (informational; pipelines matched by name).

.PARAMETER GitHubOrg
    Inline mode: target GitHub org.

.PARAMETER GitHubRepo
    Inline mode: target GitHub repo.

.PARAMETER ServiceConnectionId
    Inline mode: GitHub service connection GUID from ADO.

.PARAMETER AdoPat
    ADO PAT (defaults to $env:ADO_PAT). Never logged.

.PARAMETER GhPat
    GitHub PAT (defaults to $env:GH_PAT). Never logged.

.PARAMETER DryRun
    Print the rewire commands without executing them.

.PARAMETER LogDirectory
    Directory for the pipeline-rewiring-{timestamp}.txt log.

.EXAMPLE
    ./4_Rewire-Pipeline.ps1 -DryRun
    Preview every rewire that would run from pipelines.csv.

.EXAMPLE
    ./4_Rewire-Pipeline.ps1 -SelectedRepos app-service-1,app-service-2

.EXAMPLE
    ./4_Rewire-Pipeline.ps1 -AdoOrg contoso -AdoProject Payments `
        -RepoName app-service-1 -GitHubOrg contoso-gh -GitHubRepo app-service-1 `
        -ServiceConnectionId 11112222-3333-4444-5555-666677778888

.NOTES
    Author  : Platform Engineering
    Version : 2.1.0
    Requires: gh CLI with ado2gh extension; GitHub Pipelines App installed on
              the target org; a GitHub service connection in the ADO project.
    Security: PATs are read from parameters/env vars and NEVER logged.
#>
[CmdletBinding()]
param(
    # CSV-mode (default)
    [string]   $PipelinesCsvPath  = (Join-Path $PSScriptRoot 'pipelines.csv'),
    [string]   $RepoStatusCsvPath = (Join-Path $PSScriptRoot 'repos_with_status.csv'),
    [string[]] $SelectedRepos     = @(),
    [string[]] $SelectedPipelines = @(),
    [switch]   $SkipStatusCheck,

    # Inline single-repo mode (bypasses pipelines.csv)
    [string]   $AdoOrg,
    [string]   $AdoProject,
    [string]   $RepoName,
    [string]   $GitHubOrg,
    [string]   $GitHubRepo,
    [string]   $ServiceConnectionId,

    # Auth (falls back to env vars)
    [string]   $AdoPat        = $env:ADO_PAT,
    [string]   $GhPat         = $env:GH_PAT,

    [switch]   $DryRun,
    [string]   $LogDirectory  = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region SETUP & LOGGING
$Timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$LogFile   = Join-Path $LogDirectory "pipeline-rewiring-$Timestamp.txt"

$SuccessCount         = 0
$FailureCount         = 0
$SkippedCount         = 0
$AlreadyMigratedCount = 0
$SkippedRewiringCount = 0

$PlaceholderValues = @('your-service-connection-id', 'placeholder', 'TODO', 'TBD', 'xxx', '')

function Write-RewireLog {
    param(
        [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')] [string] $Level = 'INFO'
    )
    $line  = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))][$Level] $Message"
    $color = switch ($Level) { 'INFO' { 'Cyan' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'SUCCESS' { 'Green' } }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}
#endregion

#region VALIDATION
if ([string]::IsNullOrWhiteSpace($AdoPat)) {
    throw "ADO_PAT is empty. Expected an Azure DevOps PAT with Build (Read & execute) scope. Fix: set `$env:ADO_PAT or pass -AdoPat."
}
if ([string]::IsNullOrWhiteSpace($GhPat)) {
    throw "GH_PAT is empty. Expected a GitHub PAT with repo + workflow scopes. Fix: set `$env:GH_PAT or pass -GhPat."
}
# Ensure child processes see them (values never logged)
$env:ADO_PAT  = $AdoPat
$env:GH_PAT   = $GhPat
$env:GH_TOKEN = $GhPat

$ghOk = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghOk) {
    throw "gh CLI not found on PATH. Expected gh 2.30+ with the ado2gh extension. Fix: install from https://cli.github.com then 'gh extension install github/gh-ado2gh'."
}

$InlineMode = -not [string]::IsNullOrWhiteSpace($ServiceConnectionId) -and
              -not [string]::IsNullOrWhiteSpace($AdoOrg) -and
              -not [string]::IsNullOrWhiteSpace($AdoProject) -and
              -not [string]::IsNullOrWhiteSpace($GitHubOrg) -and
              -not [string]::IsNullOrWhiteSpace($GitHubRepo)
#endregion

#region BUILD WORK LIST
$WorkItems = [System.Collections.Generic.List[PSCustomObject]]::new()

if ($InlineMode) {
    if ($PlaceholderValues -contains $ServiceConnectionId.Trim()) {
        throw "ServiceConnectionId '$ServiceConnectionId' is a placeholder. Expected a real service connection GUID. Fix: copy the GUID from ADO Project Settings > Service connections > (connection) > URL."
    }
    Write-RewireLog "Inline mode: rewiring pipelines for repo '$RepoName' -> $GitHubOrg/$GitHubRepo"
    $WorkItems.Add([PSCustomObject]@{
        org = $AdoOrg; teamproject = $AdoProject; repo = $RepoName
        pipeline = "$RepoName-CI"; github_org = $GitHubOrg
        github_repo = $GitHubRepo; serviceConnection = $ServiceConnectionId
    })
}
else {
    if (-not (Test-Path -LiteralPath $PipelinesCsvPath)) {
        throw "pipelines.csv not found at '$PipelinesCsvPath'. Expected columns: org,teamproject,repo,pipeline,github_org,github_repo,serviceConnection. Fix: create the file or pass -PipelinesCsvPath."
    }
    $rows = @(Import-Csv -LiteralPath $PipelinesCsvPath)
    if ($rows.Count -eq 0) { throw "pipelines.csv '$PipelinesCsvPath' contains no rows. Fix: add at least one pipeline mapping." }

    # Required column validation
    $required = @('org', 'teamproject', 'repo', 'pipeline', 'github_org', 'github_repo', 'serviceConnection')
    $headers  = @($rows[0].PSObject.Properties.Name)
    $missing  = @($required | Where-Object { $headers -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw "pipelines.csv is missing required column(s): $($missing -join ', '). Expected: $($required -join ','). Fix: correct the header row in '$PipelinesCsvPath'."
    }

    # Placeholder service connection validation — abort the whole run
    $badRows = @($rows | Where-Object { $PlaceholderValues -contains ([string]$_.serviceConnection).Trim() })
    if ($badRows.Count -gt 0) {
        $names = ($badRows | ForEach-Object { $_.pipeline }) -join ', '
        throw "pipelines.csv contains placeholder serviceConnection values for: $names. Expected real service connection GUIDs. Fix: replace placeholders with the GUID from ADO Project Settings > Service connections."
    }

    # Migration status filter
    $MigratedRepos = @{}
    if (-not $SkipStatusCheck) {
        if (-not (Test-Path -LiteralPath $RepoStatusCsvPath)) {
            throw "repos_with_status.csv not found at '$RepoStatusCsvPath'. Expected the post-migration status file (RepoName,MigrationStatus). Fix: run the migration first, or use -SkipStatusCheck to bypass."
        }
        foreach ($s in @(Import-Csv -LiteralPath $RepoStatusCsvPath)) {
            if ($s.MigrationStatus -eq 'Success') { $MigratedRepos[$s.RepoName] = $true }
        }
        Write-RewireLog "Loaded $(@($MigratedRepos.Keys).Count) successfully-migrated repo(s) from status file."
    }
    else {
        Write-RewireLog 'SkipStatusCheck set — not filtering by migration status.' -Level WARN
    }

    foreach ($row in $rows) {
        if (-not $SkipStatusCheck -and -not $MigratedRepos.ContainsKey($row.repo)) {
            Write-RewireLog "SKIP (not migrated): pipeline '$($row.pipeline)' — repo '$($row.repo)' has no Success status." -Level WARN
            $SkippedCount++
            continue
        }
        if (@($SelectedRepos).Count -gt 0 -and $SelectedRepos -notcontains $row.repo) {
            $SkippedCount++; continue
        }
        if (@($SelectedPipelines).Count -gt 0 -and $SelectedPipelines -notcontains $row.pipeline) {
            $SkippedCount++; continue
        }
        $WorkItems.Add($row)
    }
}

Write-RewireLog "Pipelines queued for rewiring: $($WorkItems.Count)"
#endregion

#region REWIRE
foreach ($row in $WorkItems) {
    $pipelineName = ([string]$row.pipeline).TrimStart('\')
    $display      = "$($row.org)/$($row.teamproject) :: $pipelineName -> $($row.github_org)/$($row.github_repo)"

    if ($DryRun) {
        Write-RewireLog "[DRY-RUN] gh ado2gh rewire-pipeline --ado-org $($row.org) --ado-team-project $($row.teamproject) --ado-pipeline `"$pipelineName`" --github-org $($row.github_org) --github-repo $($row.github_repo) --service-connection-id $($row.serviceConnection)" -Level WARN
        $SkippedRewiringCount++
        continue
    }

    Write-RewireLog "Rewiring: $display"
    $output = (& gh ado2gh rewire-pipeline `
        --ado-org               $row.org `
        --ado-team-project      $row.teamproject `
        --ado-pipeline          $pipelineName `
        --github-org            $row.github_org `
        --github-repo           $row.github_repo `
        --service-connection-id $row.serviceConnection 2>&1) -join "`n"

    if ($LASTEXITCODE -eq 0) {
        Write-RewireLog "SUCCESS: $display" -Level SUCCESS
        $SuccessCount++
    }
    elseif ($output -match 'already.*(github|rewired|migrated)') {
        Write-RewireLog "ALREADY REWIRED: $display" -Level WARN
        $AlreadyMigratedCount++
    }
    else {
        Write-RewireLog "FAILED: $display — $output" -Level ERROR
        Write-RewireLog "  Fix: verify the pipeline name matches ADO exactly, the service connection GUID is valid, and the GitHub Pipelines App is installed on '$($row.github_org)'." -Level ERROR
        $FailureCount++
    }
}
#endregion

#region SUMMARY
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor DarkBlue
Write-Host '  PIPELINE REWIRING SUMMARY' -ForegroundColor Magenta
Write-Host ('=' * 60) -ForegroundColor DarkBlue
Write-Host "  Succeeded        : $SuccessCount"          -ForegroundColor Green
Write-Host "  Failed           : $FailureCount"          -ForegroundColor Red
Write-Host "  Skipped (filter) : $SkippedCount"          -ForegroundColor Yellow
Write-Host "  Already rewired  : $AlreadyMigratedCount"  -ForegroundColor Yellow
Write-Host "  Dry-run skipped  : $SkippedRewiringCount"  -ForegroundColor Yellow
Write-Host "  Log file         : $LogFile"               -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor DarkBlue

if ($FailureCount -gt 0) { exit 1 }
#endregion
