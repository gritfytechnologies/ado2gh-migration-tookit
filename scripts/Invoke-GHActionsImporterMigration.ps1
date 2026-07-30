#Requires -Version 7.2
<#
.SYNOPSIS
    Migrates Azure DevOps build and/or release pipelines to GitHub Actions workflows
    using GitHub Actions Importer, with selectable repo scope, rate-limit handling,
    resumable state, and enterprise-grade logging/reporting.

.DESCRIPTION
    Wraps `gh actions-importer` (audit / dry-run / migrate) to convert classic OR
    YAML Azure DevOps build pipelines and classic release pipelines into GitHub
    Actions workflows. Designed as a companion to Invoke-GHEMigration.ps1 (repo
    history migration) and Get-ADOInventory.ps1 (source-of-truth inventory).

    Selection scope:
        -SelectionMode All      : every pipeline in the inventory
        -SelectionMode Single   : one named repo/pipeline
        -SelectionMode Count    : first N repos from inventory (deterministic order)
        -SelectionMode List     : explicit list of repo/pipeline names or IDs

    Pipeline type scope:
        -PipelineType Build     : classic/YAML build pipelines only
        -PipelineType Release   : classic release pipelines only
        -PipelineType Both      : both, build first then release per repo

    Safety model:
        Default mode is DRY RUN. Nothing is written to GitHub, no PRs are opened,
        until you pass -Migrate explicitly. This mirrors the -DryRun convention
        used in Invoke-GHEMigration.ps1.

.PARAMETER InventoryPath
    Path to the JSON inventory produced by Get-ADOInventory.ps1. Must contain
    repository/pipeline entries with at minimum: RepoName, ProjectName,
    BuildPipelineIds (array), ReleasePipelineIds (array).

.PARAMETER SelectionMode
    All | Single | Count | List

.PARAMETER SingleRepoName
    Required when -SelectionMode Single.

.PARAMETER RepoCount
    Required when -SelectionMode Count. Takes the first N repos as ordered in
    the inventory file.

.PARAMETER RepoList
    Required when -SelectionMode List. Comma-separated or array of repo names.

.PARAMETER PipelineType
    Build | Release | Both. Default: Both.

.PARAMETER Migrate
    Switch. When present, opens PRs against the target GitHub repo. When absent,
    runs in dry-run mode only (default, safe).

.PARAMETER MaxConcurrency
    Max parallel pipeline conversions. Default 3. Keep low (2-4) — each unit of
    work spins up a Docker container and hits both ADO and GitHub REST APIs;
    high concurrency is the most common cause of secondary rate limiting.

.PARAMETER MaxRetries
    Max retry attempts per pipeline on transient/rate-limit failures. Default 5.

.PARAMETER InitialBackoffSeconds
    Base backoff for exponential retry with jitter. Default 15.

.PARAMETER OutputDir
    Root output directory for logs, state, reports, and per-pipeline artifacts.
    Default .\ghai-output.

.PARAMETER StateFilePath
    Path to the resumable state file. Default: <OutputDir>\state\migration-state.json

.PARAMETER Resume
    Switch. Skip pipelines already marked Succeeded in the state file.

.PARAMETER SkipPreflightChecks
    Switch. Bypass prerequisite validation (not recommended; use only for repeat
    runs in a session where preflight already passed).

.PARAMETER GitHubTargetUrlTemplate
    Template for the target GitHub repo URL, with {RepoName} placeholder.
    Example: "https://github.com/my-enterprise-org/{RepoName}"

.EXAMPLE
    # Dry-run every pipeline (build + release) for all repos in inventory
    .\Invoke-GHActionsImporterMigration.ps1 -InventoryPath .\ado-inventory.json `
        -GitHubTargetUrlTemplate "https://github.com/acme-org/{RepoName}"

.EXAMPLE
    # Dry-run build pipelines only, first 10 repos, 4-way concurrency
    .\Invoke-GHActionsImporterMigration.ps1 -InventoryPath .\ado-inventory.json `
        -SelectionMode Count -RepoCount 10 -PipelineType Build -MaxConcurrency 4 `
        -GitHubTargetUrlTemplate "https://github.com/acme-org/{RepoName}"

.EXAMPLE
    # Production migration (opens PRs) for a single repo, both pipeline types
    .\Invoke-GHActionsImporterMigration.ps1 -InventoryPath .\ado-inventory.json `
        -SelectionMode Single -SingleRepoName "payments-api" -PipelineType Both `
        -Migrate -GitHubTargetUrlTemplate "https://github.com/acme-org/{RepoName}"

.EXAMPLE
    # Resume a partially completed run, skipping already-succeeded pipelines
    .\Invoke-GHActionsImporterMigration.ps1 -InventoryPath .\ado-inventory.json `
        -SelectionMode All -Migrate -Resume `
        -GitHubTargetUrlTemplate "https://github.com/acme-org/{RepoName}"

.NOTES
    Author        : Siva (with Claude)
    Version       : 1.0.0
    Requires      : PowerShell 7.2+, gh CLI, gh-actions-importer extension, Docker
    Companion to  : Get-ADOInventory.ps1, Invoke-GHEMigration.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$InventoryPath,

    [Parameter(Mandatory = $true)]
    [string]$GitHubTargetUrlTemplate,

    [ValidateSet('All', 'Single', 'Count', 'List')]
    [string]$SelectionMode = 'All',

    [string]$SingleRepoName,

    [ValidateRange(1, 100000)]
    [int]$RepoCount,

    [string[]]$RepoList,

    [ValidateSet('Build', 'Release', 'Both')]
    [string]$PipelineType = 'Both',

    [switch]$Migrate,

    [ValidateRange(1, 10)]
    [int]$MaxConcurrency = 3,

    [ValidateRange(0, 15)]
    [int]$MaxRetries = 5,

    [ValidateRange(1, 300)]
    [int]$InitialBackoffSeconds = 15,

    [string]$OutputDir = ".\ghai-output",

    [string]$StateFilePath,

    [switch]$Resume,

    [switch]$SkipPreflightChecks,

    [ValidateRange(60, 3600)]
    [int]$PerPipelineTimeoutSeconds = 600
)

#region --- Globals & Setup ------------------------------------------------

$ErrorActionPreference = 'Stop'
$script:RunId       = (Get-Date -Format 'yyyyMMdd-HHmmss')
$script:StartTime    = Get-Date
$script:LogDir       = Join-Path $OutputDir 'logs'
$script:StateDir     = Join-Path $OutputDir 'state'
$script:ReportDir    = Join-Path $OutputDir 'reports'
$script:ArtifactDir  = Join-Path $OutputDir 'artifacts'
$script:LogFile      = Join-Path $script:LogDir "actions-importer-$($script:RunId).log"
$script:JsonLogFile  = Join-Path $script:LogDir "actions-importer-$($script:RunId).jsonl"

if (-not $StateFilePath) {
    $StateFilePath = Join-Path $script:StateDir 'migration-state.json'
}

foreach ($dir in @($OutputDir, $script:LogDir, $script:StateDir, $script:ReportDir, $script:ArtifactDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# Simple in-memory rate-limit budget tracker (also enforced via backoff on failures)
$script:RateLimitState = [pscustomobject]@{
    LastCallTimestamps = [System.Collections.Generic.List[datetime]]::new()
    MinIntervalSeconds  = 2   # floor spacing between any two gh actions-importer invocations
}
$script:RateLimitLock = [System.Object]::new()

#endregion

#region --- Logging ----------------------------------------------------------

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR', 'SUCCESS')][string]$Level = 'INFO',
        [string]$RepoName = '',
        [string]$PipelineType = ''
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = "[$timestamp] [$Level]$(if ($RepoName) { " [$RepoName]" })$(if ($PipelineType) { " [$PipelineType]" }) $Message"

    $color = switch ($Level) {
        'DEBUG'   { 'DarkGray' }
        'INFO'    { 'Gray' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'SUCCESS' { 'Green' }
        default   { 'White' }
    }
    Write-Host $line -ForegroundColor $color

    # Text log (thread-safe append via mutex, since -Parallel runs multiple threads)
    $mutex = New-Object System.Threading.Mutex($false, 'Global\GHAI_LogMutex')
    try {
        $mutex.WaitOne() | Out-Null
        Add-Content -Path $script:LogFile -Value $line -Encoding utf8
        $jsonLine = [pscustomobject]@{
            timestamp    = $timestamp
            level        = $Level
            repoName     = $RepoName
            pipelineType = $PipelineType
            message      = $Message
        } | ConvertTo-Json -Compress
        Add-Content -Path $script:JsonLogFile -Value $jsonLine -Encoding utf8
    }
    finally {
        $mutex.ReleaseMutex() | Out-Null
        $mutex.Dispose()
    }
}

#endregion

#region --- Preflight Checks --------------------------------------------------

function Test-Prerequisites {
    [CmdletBinding()]
    param()

    Write-Log -Level INFO -Message "Running preflight checks..."
    $failures = [System.Collections.Generic.List[string]]::new()

    # 1. PowerShell version
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $failures.Add("PowerShell 7.2+ required. Current: $($PSVersionTable.PSVersion). Parallel throttling depends on ForEach-Object -Parallel.")
    }

    # 2. gh CLI installed
    $ghPath = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $ghPath) {
        $failures.Add("GitHub CLI ('gh') not found on PATH. Install: https://cli.github.com")
    }
    else {
        try {
            $ghVersion = (gh --version) -join ' '
            Write-Log -Level DEBUG -Message "gh CLI found: $ghVersion"
        } catch {
            $failures.Add("gh CLI found but 'gh --version' failed: $($_.Exception.Message)")
        }
    }

    # 3. gh-actions-importer extension installed
    if ($ghPath) {
        $extensions = gh extension list 2>$null
        if ($extensions -notmatch 'actions-importer') {
            $failures.Add("gh-actions-importer extension not installed. Run: gh extension install github/gh-actions-importer")
        }
        else {
            Write-Log -Level DEBUG -Message "gh-actions-importer extension detected."
        }
    }

    # 4. Docker installed and running
    $dockerPath = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerPath) {
        $failures.Add("Docker CLI not found. GitHub Actions Importer runs as a Docker container.")
    }
    else {
        docker info *> $null
        if ($LASTEXITCODE -ne 0) {
            $failures.Add("Docker is installed but the daemon is not running/reachable. Start Docker Desktop or the docker service.")
        }
        else {
            Write-Log -Level DEBUG -Message "Docker daemon reachable."
        }
    }

    # 5. Required environment variables (set via `gh actions-importer configure`)
    $requiredEnvVars = @(
        'GITHUB_ACCESS_TOKEN',
        'GITHUB_INSTANCE_URL',
        'AZURE_DEVOPS_ACCESS_TOKEN',
        'AZURE_DEVOPS_ORGANIZATION',
        'AZURE_DEVOPS_INSTANCE_URL'
    )
    foreach ($var in $requiredEnvVars) {
        $value = [Environment]::GetEnvironmentVariable($var)
        if ([string]::IsNullOrWhiteSpace($value)) {
            $failures.Add("Required environment variable '$var' is not set. Run 'gh actions-importer configure' or load your .env.local file.")
        }
    }

    # 6. Validate PAT scopes are at minimum plausible (length/format sanity, not a live scope check)
    $ghToken = [Environment]::GetEnvironmentVariable('GITHUB_ACCESS_TOKEN')
    if ($ghToken -and $ghToken.Length -lt 20) {
        $failures.Add("GITHUB_ACCESS_TOKEN looks malformed (too short). Verify it's a classic PAT with 'workflow' scope.")
    }

    # 7. Network reachability to ADO and GitHub
    foreach ($target in @(
        @{ Name = 'GitHub API'; Url = 'https://api.github.com' },
        @{ Name = 'Azure DevOps'; Url = 'https://dev.azure.com' }
    )) {
        try {
            $resp = Invoke-WebRequest -Uri $target.Url -Method Head -TimeoutSec 10 -SkipHttpErrorCheck
            Write-Log -Level DEBUG -Message "$($target.Name) reachable (HTTP $($resp.StatusCode))."
        } catch {
            $failures.Add("Cannot reach $($target.Name) at $($target.Url): $($_.Exception.Message)")
        }
    }

    # 8. gh-actions-importer image is up to date (non-fatal, warn only)
    try {
        $updateOutput = gh actions-importer update 2>&1
        Write-Log -Level DEBUG -Message "actions-importer update check: $updateOutput"
    } catch {
        Write-Log -Level WARN -Message "Could not verify actions-importer container is up to date: $($_.Exception.Message)"
    }

    # 9. Disk space (conversions + audit output can accumulate)
    try {
        $drive = (Get-Item $OutputDir).PSDrive
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
        if ($freeGB -lt 2) {
            $failures.Add("Low disk space on drive $($drive.Name): only ${freeGB}GB free. Recommend 2GB+ for audit/migrate artifacts.")
        }
    } catch {
        Write-Log -Level DEBUG -Message "Disk space check skipped: $($_.Exception.Message)"
    }

    # 10. Inventory file structure sanity
    try {
        $null = Get-Content $InventoryPath -Raw | ConvertFrom-Json
    } catch {
        $failures.Add("InventoryPath '$InventoryPath' is not valid JSON: $($_.Exception.Message)")
    }

    if ($failures.Count -gt 0) {
        Write-Log -Level ERROR -Message "Preflight check failed with $($failures.Count) issue(s):"
        foreach ($f in $failures) { Write-Log -Level ERROR -Message " - $f" }
        throw "Preflight checks failed. Resolve the issues above (or pass -SkipPreflightChecks to bypass, not recommended) and re-run."
    }

    Write-Log -Level SUCCESS -Message "All preflight checks passed."
}

#endregion

#region --- Rate Limiting -----------------------------------------------------

function Wait-ForRateLimitWindow {
    <#
        Enforces a minimum spacing between gh actions-importer invocations regardless
        of thread. This is a floor, not the primary defense — the primary defense is
        the retry/backoff wrapper below reacting to actual 403/429 responses embedded
        in gh actions-importer's log output (ADO and GitHub both throttle via 429s,
        and ADO also uses secondary/soft throttling that returns 203 TF400733-style
        payloads without a clean HTTP status).
    #>
    [CmdletBinding()]
    param()

    [System.Threading.Monitor]::Enter($script:RateLimitLock)
    try {
        $now = Get-Date
        $cutoff = $now.AddMinutes(-1)
        $script:RateLimitState.LastCallTimestamps.RemoveAll({ param($t) $t -lt $cutoff }) | Out-Null

        if ($script:RateLimitState.LastCallTimestamps.Count -gt 0) {
            $last = $script:RateLimitState.LastCallTimestamps[-1]
            $elapsed = ($now - $last).TotalSeconds
            $minInterval = $script:RateLimitState.MinIntervalSeconds
            if ($elapsed -lt $minInterval) {
                $sleepFor = [math]::Round($minInterval - $elapsed, 1)
                Start-Sleep -Seconds $sleepFor
            }
        }
        $script:RateLimitState.LastCallTimestamps.Add((Get-Date))
    }
    finally {
        [System.Threading.Monitor]::Exit($script:RateLimitLock)
    }
}

function Test-RateLimitSignal {
    <#
        Inspects gh actions-importer output/logs for known rate-limit indicators.
        The CLI doesn't expose a typed rate-limit exception, so this pattern-matches
        against known ADO/GitHub throttling signatures in stdout/stderr and the log
        files it writes under the run's output directory.
    #>
    param([string]$OutputText)

    $patterns = @(
        'TF400733',            # ADO rate limit / too many requests
        '429',                 # HTTP 429 Too Many Requests
        'rate limit',
        'RateLimitExceeded',
        'secondary rate limit',
        'abuse detection',
        '503 Service Unavailable',
        'Connection reset by peer'
    )
    foreach ($p in $patterns) {
        if ($OutputText -match [regex]::Escape($p)) {
            return $true
        }
    }
    return $false
}

#endregion

#region --- Retry Wrapper -----------------------------------------------------

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [string]$RepoName = '',
        [string]$OperationName = 'operation',
        [int]$MaxRetries = 5,
        [int]$InitialBackoffSeconds = 15
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Wait-ForRateLimitWindow
            $result = & $ScriptBlock

            $combinedOutput = ($result | Out-String)
            if (Test-RateLimitSignal -OutputText $combinedOutput) {
                throw "Rate-limit signal detected in output for '$OperationName' (attempt $attempt)."
            }

            return $result
        }
        catch {
            if ($attempt -ge $MaxRetries) {
                Write-Log -Level ERROR -RepoName $RepoName -Message "'$OperationName' failed after $attempt attempts: $($_.Exception.Message)"
                throw
            }

            # Exponential backoff with full jitter: base * 2^(attempt-1), randomized
            $backoffBase = $InitialBackoffSeconds * [math]::Pow(2, $attempt - 1)
            $jitter = Get-Random -Minimum 0 -Maximum ([int]($backoffBase * 0.5) + 1)
            $sleepSeconds = [math]::Min(300, [int]($backoffBase + $jitter))  # cap at 5 min

            Write-Log -Level WARN -RepoName $RepoName -Message "'$OperationName' attempt $attempt/$MaxRetries failed: $($_.Exception.Message). Retrying in ${sleepSeconds}s..."
            Start-Sleep -Seconds $sleepSeconds
        }
    }
}

#endregion

#region --- State Management --------------------------------------------------

function Import-MigrationState {
    param([string]$Path)

    if (Test-Path $Path) {
        try {
            $raw = Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable
            Write-Log -Level INFO -Message "Loaded existing state file with $($raw.Keys.Count) tracked pipeline(s) from $Path"
            return $raw
        } catch {
            Write-Log -Level WARN -Message "State file at $Path could not be parsed, starting fresh: $($_.Exception.Message)"
            return @{}
        }
    }
    return @{}
}

function Save-MigrationState {
    param([hashtable]$State, [string]$Path)

    $mutex = New-Object System.Threading.Mutex($false, 'Global\GHAI_StateMutex')
    try {
        $mutex.WaitOne() | Out-Null
        $State | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding utf8
    }
    finally {
        $mutex.ReleaseMutex() | Out-Null
        $mutex.Dispose()
    }
}

function Get-StateKey {
    param([string]$RepoName, [string]$PipelineType, [string]$PipelineId)
    return "$RepoName|$PipelineType|$PipelineId"
}

#endregion

#region --- Repo / Pipeline Selection -----------------------------------------

function Get-WorkItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [Parameter(Mandatory = $true)][string]$SelectionMode,
        [string]$SingleRepoName,
        [int]$RepoCount,
        [string[]]$RepoList,
        [Parameter(Mandatory = $true)][string]$PipelineType
    )

    $repos = $Inventory.Repositories
    if (-not $repos) {
        throw "Inventory file does not contain a 'Repositories' array. Confirm this is output from Get-ADOInventory.ps1 (or matching schema)."
    }

    $selectedRepos = switch ($SelectionMode) {
        'All' {
            $repos
        }
        'Single' {
            if (-not $SingleRepoName) { throw "-SingleRepoName is required when -SelectionMode Single." }
            $match = $repos | Where-Object { $_.RepoName -eq $SingleRepoName }
            if (-not $match) { throw "Repo '$SingleRepoName' not found in inventory." }
            @($match)
        }
        'Count' {
            if (-not $RepoCount -or $RepoCount -le 0) { throw "-RepoCount (>0) is required when -SelectionMode Count." }
            $repos | Select-Object -First $RepoCount
        }
        'List' {
            if (-not $RepoList -or $RepoList.Count -eq 0) { throw "-RepoList is required when -SelectionMode List." }
            $matches = $repos | Where-Object { $_.RepoName -in $RepoList }
            $notFound = $RepoList | Where-Object { $_ -notin $matches.RepoName }
            if ($notFound) {
                Write-Log -Level WARN -Message "The following repos in -RepoList were not found in inventory and will be skipped: $($notFound -join ', ')"
            }
            $matches
        }
    }

    if (-not $selectedRepos -or @($selectedRepos).Count -eq 0) {
        throw "No repositories matched the selection criteria."
    }

    $workItems = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($repo in $selectedRepos) {
        $projectName = $repo.ProjectName
        $repoName    = $repo.RepoName

        if ($PipelineType -in @('Build', 'Both')) {
            $buildIds = @($repo.BuildPipelineIds)
            if ($buildIds.Count -eq 0) {
                Write-Log -Level DEBUG -RepoName $repoName -Message "No build pipeline IDs found in inventory; skipping build conversion for this repo."
            }
            foreach ($id in $buildIds) {
                $workItems.Add([pscustomobject]@{
                    RepoName     = $repoName
                    ProjectName  = $projectName
                    PipelineType = 'Build'
                    PipelineId   = $id
                })
            }
        }

        if ($PipelineType -in @('Release', 'Both')) {
            $releaseIds = @($repo.ReleasePipelineIds)
            if ($releaseIds.Count -eq 0) {
                Write-Log -Level DEBUG -RepoName $repoName -Message "No release pipeline IDs found in inventory; skipping release conversion for this repo."
            }
            foreach ($id in $releaseIds) {
                $workItems.Add([pscustomobject]@{
                    RepoName     = $repoName
                    ProjectName  = $projectName
                    PipelineType = 'Release'
                    PipelineId   = $id
                })
            }
        }
    }

    if ($workItems.Count -eq 0) {
        throw "Selection produced zero pipelines to process. Check inventory has BuildPipelineIds/ReleasePipelineIds populated for the selected repos."
    }

    return $workItems
}

#endregion

#region --- Core Conversion Logic ---------------------------------------------

function Invoke-PipelineConversion {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$WorkItem,
        [Parameter(Mandatory = $true)][string]$GitHubTargetUrlTemplate,
        [Parameter(Mandatory = $true)][string]$ArtifactDir,
        [switch]$Migrate,
        [int]$MaxRetries,
        [int]$InitialBackoffSeconds,
        [int]$TimeoutSeconds
    )

    $repoName     = $WorkItem.RepoName
    $pipelineType = $WorkItem.PipelineType   # 'Build' or 'Release'
    $pipelineId   = $WorkItem.PipelineId
    $subcommand   = if ($pipelineType -eq 'Build') { 'pipeline' } else { 'release' }
    $targetUrl    = $GitHubTargetUrlTemplate -replace '\{RepoName\}', $repoName
    $itemOutDir   = Join-Path $ArtifactDir "$repoName/$pipelineType-$pipelineId"

    New-Item -ItemType Directory -Path $itemOutDir -Force | Out-Null

    $mode = if ($Migrate) { 'migrate' } else { 'dry-run' }
    $actionDescription = "$mode $pipelineType pipeline $pipelineId for $repoName -> $targetUrl"

    if (-not $PSCmdlet.ShouldProcess($actionDescription, "Invoke gh actions-importer")) {
        return [pscustomobject]@{
            RepoName = $repoName; PipelineType = $pipelineType; PipelineId = $pipelineId
            Status = 'SkippedWhatIf'; Mode = $mode; Message = 'ShouldProcess declined (-WhatIf)'
            DurationSeconds = 0; PullRequestUrl = $null
        }
    }

    Write-Log -Level INFO -RepoName $repoName -PipelineType $pipelineType -Message "Starting $mode for pipeline ID $pipelineId..."

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $scriptBlock = {
        $ghArgs = @(
            'actions-importer', $mode, 'azure-devops', $subcommand,
            '--pipeline-id', $pipelineId,
            '--output-dir', $itemOutDir
        )
        if ($mode -eq 'migrate') {
            $ghArgs += @('--target-url', $targetUrl)
        }

        # Job with a hard timeout so one hung Docker container can't stall the whole batch
        $job = Start-Job -ScriptBlock {
            param($exe, $jobArgs)
            & $exe @jobArgs 2>&1
        } -ArgumentList 'gh', $ghArgs

        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $completed) {
            Stop-Job -Job $job | Out-Null
            Remove-Job -Job $job -Force | Out-Null
            throw "Timed out after ${TimeoutSeconds}s waiting for gh actions-importer $mode on pipeline $pipelineId."
        }

        $output = Receive-Job -Job $job
        $exitCode = $job.ChildJobs[0].JobStateInfo.State
        Remove-Job -Job $job -Force | Out-Null

        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "gh actions-importer exited with code $LASTEXITCODE. Output: $($output | Out-String)"
        }

        return $output
    }

    try {
        $output = Invoke-WithRetry -ScriptBlock $scriptBlock -RepoName $repoName `
            -OperationName "$mode $pipelineType pipeline $pipelineId" `
            -MaxRetries $MaxRetries -InitialBackoffSeconds $InitialBackoffSeconds

        $sw.Stop()
        $outputText = $output | Out-String

        # Persist raw output for troubleshooting/auditing
        $outputText | Set-Content -Path (Join-Path $itemOutDir 'invocation-output.log') -Encoding utf8

        $prUrl = $null
        if ($mode -eq 'migrate') {
            $prMatch = [regex]::Match($outputText, 'Pull request:\s*''?(?<url>https://\S+)''?')
            if ($prMatch.Success) { $prUrl = $prMatch.Groups['url'].Value.Trim("'") }
        }

        Write-Log -Level SUCCESS -RepoName $repoName -PipelineType $pipelineType `
            -Message "$mode completed in $([math]::Round($sw.Elapsed.TotalSeconds,1))s.$(if ($prUrl) { " PR: $prUrl" })"

        return [pscustomobject]@{
            RepoName = $repoName; PipelineType = $pipelineType; PipelineId = $pipelineId
            Status = 'Succeeded'; Mode = $mode; Message = 'OK'
            DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            PullRequestUrl = $prUrl
        }
    }
    catch {
        $sw.Stop()
        Write-Log -Level ERROR -RepoName $repoName -PipelineType $pipelineType `
            -Message "$mode failed: $($_.Exception.Message)"
        return [pscustomobject]@{
            RepoName = $repoName; PipelineType = $pipelineType; PipelineId = $pipelineId
            Status = 'Failed'; Mode = $mode; Message = $_.Exception.Message
            DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            PullRequestUrl = $null
        }
    }
}

#endregion

#region --- Reporting ----------------------------------------------------------

function New-SummaryReport {
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[pscustomobject]]$Results,
        [Parameter(Mandatory = $true)][string]$ReportDir,
        [datetime]$StartTime
    )

    $csvPath  = Join-Path $ReportDir "migration-results-$($script:RunId).csv"
    $htmlPath = Join-Path $ReportDir "migration-dashboard-$($script:RunId).html"

    $Results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8

    $succeeded = @($Results | Where-Object Status -eq 'Succeeded')
    $failed    = @($Results | Where-Object Status -eq 'Failed')
    $skipped   = @($Results | Where-Object Status -like 'Skipped*')
    $total     = $Results.Count
    $duration  = (Get-Date) - $StartTime

    $rows = ($Results | Sort-Object RepoName, PipelineType | ForEach-Object {
        $statusColor = switch ($_.Status) {
            'Succeeded' { '#1a7f37' }
            'Failed'    { '#cf222e' }
            default     { '#9a6700' }
        }
        $prLink = if ($_.PullRequestUrl) { "<a href='$($_.PullRequestUrl)'>PR</a>" } else { '-' }
        "<tr><td>$($_.RepoName)</td><td>$($_.PipelineType)</td><td>$($_.PipelineId)</td>" +
        "<td style='color:$statusColor;font-weight:600'>$($_.Status)</td><td>$($_.Mode)</td>" +
        "<td>$($_.DurationSeconds)s</td><td>$prLink</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Message))</td></tr>"
    }) -join "`n"

    $html = @"
<!DOCTYPE html>
<html><head><meta charset='utf-8'><title>GH Actions Importer Migration Dashboard</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:2rem;background:#f6f8fa;color:#1f2328}
h1{font-size:1.4rem} .summary{display:flex;gap:1rem;margin:1rem 0 2rem}
.card{background:#fff;border:1px solid #d0d7de;border-radius:6px;padding:1rem 1.5rem;min-width:120px}
.card .num{font-size:1.8rem;font-weight:700} table{width:100%;border-collapse:collapse;background:#fff}
th,td{padding:.5rem .75rem;border-bottom:1px solid #d0d7de;text-align:left;font-size:.9rem}
th{background:#f6f8fa}
</style></head><body>
<h1>GitHub Actions Importer Migration Dashboard</h1>
<p>Run ID: $($script:RunId) &middot; Duration: $([math]::Round($duration.TotalMinutes,1)) min &middot; Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
<div class='summary'>
<div class='card'><div class='num'>$total</div>Total</div>
<div class='card'><div class='num' style='color:#1a7f37'>$($succeeded.Count)</div>Succeeded</div>
<div class='card'><div class='num' style='color:#cf222e'>$($failed.Count)</div>Failed</div>
<div class='card'><div class='num' style='color:#9a6700'>$($skipped.Count)</div>Skipped</div>
</div>
<table>
<tr><th>Repo</th><th>Type</th><th>Pipeline ID</th><th>Status</th><th>Mode</th><th>Duration</th><th>PR</th><th>Message</th></tr>
$rows
</table>
</body></html>
"@

    $html | Set-Content -Path $htmlPath -Encoding utf8

    Write-Log -Level INFO -Message "CSV report: $csvPath"
    Write-Log -Level INFO -Message "HTML dashboard: $htmlPath"

    return [pscustomobject]@{ CsvPath = $csvPath; HtmlPath = $htmlPath }
}

#endregion

#region --- Main ---------------------------------------------------------------

try {
    Write-Log -Level INFO -Message "=== GH Actions Importer Migration — Run $($script:RunId) ==="
    Write-Log -Level INFO -Message "Mode: $(if ($Migrate) { 'MIGRATE (opens PRs)' } else { 'DRY-RUN (no changes)' }) | Selection: $SelectionMode | PipelineType: $PipelineType | Concurrency: $MaxConcurrency"

    if (-not $SkipPreflightChecks) {
        Test-Prerequisites
    } else {
        Write-Log -Level WARN -Message "Preflight checks skipped by user request (-SkipPreflightChecks)."
    }

    $inventory = Get-Content $InventoryPath -Raw | ConvertFrom-Json
    $workItems = Get-WorkItems -Inventory $inventory -SelectionMode $SelectionMode `
        -SingleRepoName $SingleRepoName -RepoCount $RepoCount -RepoList $RepoList -PipelineType $PipelineType

    Write-Log -Level INFO -Message "Resolved $($workItems.Count) pipeline(s) to process across $(@($workItems.RepoName | Select-Object -Unique).Count) repo(s)."

    $state = Import-MigrationState -Path $StateFilePath

    if ($Resume) {
        $before = $workItems.Count
        $workItems = $workItems | Where-Object {
            $key = Get-StateKey -RepoName $_.RepoName -PipelineType $_.PipelineType -PipelineId $_.PipelineId
            -not ($state.ContainsKey($key) -and $state[$key].Status -eq 'Succeeded')
        }
        Write-Log -Level INFO -Message "Resume enabled: skipping $($before - $workItems.Count) already-succeeded pipeline(s). $($workItems.Count) remain."
    }

    if ($workItems.Count -eq 0) {
        Write-Log -Level SUCCESS -Message "Nothing to do — all selected pipelines already succeeded in state file."
        return
    }

    if ($Migrate -and $PSCmdlet.ShouldProcess("$($workItems.Count) pipeline(s)", "Open GitHub PRs via gh actions-importer migrate")) {
        Write-Log -Level WARN -Message "Running in MIGRATE mode. PRs will be opened against target repositories."
    }

    # Thread-safe results collection for parallel runspaces
    $results = [System.Collections.Concurrent.ConcurrentBag[pscustomobject]]::new()

    # ForEach-Object -Parallel runs each iteration in an isolated runspace with no
    # access to the caller's functions or script-scoped variables except through
    # $using:. Function bodies must be marshalled in as strings and redefined
    # inside the parallel block; script-scoped values are copied to plain local
    # variables first so $using: can see them.
    $writeLogDef                 = ${function:Write-Log}.ToString()
    $waitForRateLimitWindowDef   = ${function:Wait-ForRateLimitWindow}.ToString()
    $testRateLimitSignalDef      = ${function:Test-RateLimitSignal}.ToString()
    $invokeWithRetryDef          = ${function:Invoke-WithRetry}.ToString()
    $invokePipelineConversionDef = ${function:Invoke-PipelineConversion}.ToString()

    $sharedRunId          = $script:RunId
    $sharedLogFile        = $script:LogFile
    $sharedJsonLogFile    = $script:JsonLogFile
    $sharedArtifactDir    = $script:ArtifactDir
    $sharedRateLimitState = $script:RateLimitState
    $sharedRateLimitLock  = $script:RateLimitLock

    $workItems | ForEach-Object -ThrottleLimit $MaxConcurrency -Parallel {
        $item           = $_
        $migrateFlag    = $using:Migrate
        $urlTemplate    = $using:GitHubTargetUrlTemplate
        $maxRetries     = $using:MaxRetries
        $initialBackoff = $using:InitialBackoffSeconds
        $timeoutSec     = $using:PerPipelineTimeoutSeconds
        $resultsBag     = $using:results

        # Re-hydrate functions and shared state inside this runspace
        ${function:Write-Log}                = $using:writeLogDef
        ${function:Wait-ForRateLimitWindow}   = $using:waitForRateLimitWindowDef
        ${function:Test-RateLimitSignal}      = $using:testRateLimitSignalDef
        ${function:Invoke-WithRetry}          = $using:invokeWithRetryDef
        ${function:Invoke-PipelineConversion} = $using:invokePipelineConversionDef

        $script:RunId          = $using:sharedRunId
        $script:LogFile        = $using:sharedLogFile
        $script:JsonLogFile    = $using:sharedJsonLogFile
        $script:RateLimitState = $using:sharedRateLimitState
        $script:RateLimitLock  = $using:sharedRateLimitLock
        $artifactDir           = $using:sharedArtifactDir

        $result = Invoke-PipelineConversion -WorkItem $item -GitHubTargetUrlTemplate $urlTemplate `
            -ArtifactDir $artifactDir -Migrate:$migrateFlag -MaxRetries $maxRetries `
            -InitialBackoffSeconds $initialBackoff -TimeoutSeconds $timeoutSec

        $resultsBag.Add($result)
    }

    $resultsList = [System.Collections.Generic.List[pscustomobject]]::new($results)

    # Persist state after the batch (single-writer, avoids lock contention mid-run)
    foreach ($r in $resultsList) {
        $key = Get-StateKey -RepoName $r.RepoName -PipelineType $r.PipelineType -PipelineId $r.PipelineId
        $state[$key] = @{
            Status          = $r.Status
            Mode            = $r.Mode
            LastRun         = (Get-Date).ToString('o')
            DurationSeconds = $r.DurationSeconds
            PullRequestUrl  = $r.PullRequestUrl
            Message         = $r.Message
        }
    }
    Save-MigrationState -State $state -Path $StateFilePath

    $report = New-SummaryReport -Results $resultsList -ReportDir $script:ReportDir -StartTime $script:StartTime

    $failedCount = @($resultsList | Where-Object Status -eq 'Failed').Count
    Write-Log -Level INFO -Message "=== Run complete: $($resultsList.Count) processed, $failedCount failed. Total time: $([math]::Round(((Get-Date) - $script:StartTime).TotalMinutes,1)) min ==="

    if ($failedCount -gt 0) {
        Write-Log -Level WARN -Message "Re-run with -Resume to retry only the failed/incomplete pipelines after investigating logs in $script:LogDir"
        exit 1
    }
    else {
        exit 0
    }
}
catch {
    Write-Log -Level ERROR -Message "Fatal error: $($_.Exception.Message)"
    Write-Log -Level ERROR -Message $_.ScriptStackTrace
    exit 2
}

#endregion
