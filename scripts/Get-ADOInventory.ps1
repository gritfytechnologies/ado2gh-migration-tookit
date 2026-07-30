#requires -Version 5.1
<#
.SYNOPSIS
    Inventories an Azure DevOps organisation (projects, repositories, sizes,
    and build/release pipelines) and produces a multi-sheet Excel workbook
    plus a JSON sidecar for executive reporting and batch migration planning
    to GitHub Enterprise (GEI) and GitHub Actions.

.DESCRIPTION
    The script connects to an Azure DevOps organisation using a PAT token,
    inventories all projects, repositories, and build/release pipelines,
    optionally runs git-sizer analysis on each repo, optionally checks
    GitHub Actions Importer readiness for YAML pipelines, and produces a
    multi-sheet Excel workbook (a leadership showcase page plus detailed
    data pages) and a JSON sidecar for migration batch planning.

.PARAMETER Organisation
    Mandatory. ADO org name from dev.azure.com/{org}

.PARAMETER PAT
    Mandatory. Accepts plain string or SecureString.

.PARAMETER OutputPath
    Optional. Defaults to .\ADO_Inventory_{org}_{timestamp}.xlsx

.PARAMETER RunGitSizer
    Optional. Enables deep per-repo git-sizer analysis.

.PARAMETER GitSizerWorkDir
    Optional. Directory for temporary bare clones.
    Defaults to $env:TEMP\ADO-GitSizer-{timestamp}

.PARAMETER KeepClones
    Optional. Keep clones after analysis (debug).

.PARAMETER GitSizerPath
    Optional. Full path to git-sizer binary. Defaults to 'git-sizer' (searched on PATH).

.PARAMETER ExcludeEmptyRepos
    Optional. Skip repos with 0 bytes.

.PARAMETER IncludeDisabledProjects
    Optional. Include non-wellFormed projects.

.PARAMETER SkipPipelineInventory
    Optional. Skip build/release pipeline collection (faster, ADO API only).

.PARAMETER CheckActionsImporter
    Optional. Attempts a GitHub Actions Importer readiness check for each
    YAML build pipeline. Uses the real 'gh actions-importer' CLI if it is
    installed; otherwise falls back to a heuristic task-name scan. See
    README.md section 8 for details and caveats.

.PARAMETER InactivityThresholdDays
    Optional. Number of days since last commit/pipeline run after which a
    repository is flagged as "Stale". Defaults to 180.

.EXAMPLE
    .\Get-ADOInventory.ps1 -Organisation contoso -PAT $pat

.EXAMPLE
    .\Get-ADOInventory.ps1 -Organisation contoso -PAT $pat -RunGitSizer -CheckActionsImporter

.NOTES
    Must run on PowerShell 5.1 and PowerShell 7+ on Windows.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Organisation,

    [Parameter(Mandatory = $true)]
    [object]$PAT,

    [string]$OutputPath,

    [switch]$RunGitSizer,

    [string]$GitSizerWorkDir,

    [switch]$KeepClones,

    [string]$GitSizerPath,

    [switch]$ExcludeEmptyRepos,

    [switch]$IncludeDisabledProjects,

    [switch]$SkipPipelineInventory,

    [switch]$CheckActionsImporter,

    [int]$InactivityThresholdDays = 180
)

# ============================================================================
# GLOBALS / CONSTANTS
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

if (-not $OutputPath -or $OutputPath -eq '') {
    $OutputPath = ".\ADO_Inventory_${Organisation}_${script:Timestamp}.xlsx"
}

if (-not $GitSizerWorkDir -or $GitSizerWorkDir -eq '') {
    $GitSizerWorkDir = Join-Path $env:TEMP "ADO-GitSizer-${script:Timestamp}"
}

if (-not $GitSizerPath -or $GitSizerPath -eq '') {
    $GitSizerPath = 'git-sizer'
}

# GitHub Enterprise Importer (GEI) limits
$GH_REPO_MAX_BYTES        = 40GB
$GH_REPO_WARN_BYTES       = 30GB
$GH_REPO_INFO_BYTES       = 100MB
$GH_FILE_BLOCKER_BYTES    = 400MB
$GH_FILE_WARNING_BYTES    = 100MB
$GH_COMMIT_MAX_BYTES      = 2GB
$GH_REF_MAX_BYTES         = 255

# Colour palette (hex strings, no #)
$colNavy        = '1F3864'
$colAccent      = '2E75B6'
$colWhite       = 'FFFFFF'
$colGreen       = '70AD47'
$colTeal        = '1F7A6C'
$colPurple      = '7030A0'
$colLightBlue   = 'BDD7EE'
$colYellow      = 'FFD966'
$colOrange      = 'ED7D31'
$colRed         = 'C00000'
$colGrey        = '808080'
$colGreenLight  = 'E2EFDA'
$colRedLight    = 'FCE4D6'
$colYellowLight = 'FFEB9C'

$script:ADOBaseUrl  = "https://dev.azure.com/$Organisation"
$script:VSRMBaseUrl = "https://vsrm.dev.azure.com/$Organisation"

# Well-known ADO pipeline task names the GitHub Actions Importer (or a
# straightforward manual conversion) typically maps cleanly. Anything not
# on this list is conservatively treated as "needs manual review". This is
# a heuristic only - see README.md section 8 for how to run the official
# 'gh actions-importer audit azure-devops' tool for an authoritative report.
$script:SupportedAdoTasks = @(
    'powershell', 'bash', 'cmdline', 'dotnetcorecli', 'nugetcommand', 'vsbuild', 'msbuild',
    'publishbuildartifacts', 'publishpipelineartifact', 'downloadbuildartifacts', 'downloadpipelineartifact',
    'checkout', 'docker', 'dockercompose', 'azurecli', 'azurewebapp', 'copyfiles', 'archivefiles',
    'vstest', 'publishtestresults', 'publishcodecoverageresults', 'usedotnet', 'nodetool',
    'usepythonversion', 'npm', 'gradle', 'maven', 'gopackage', 'gotool', 'cache', 'reviewsweep'
)

# ============================================================================
# HELPER FUNCTIONS - CONSOLE OUTPUT
# ============================================================================

function Write-Step    { param([string]$m) Write-Host "> $m" -ForegroundColor Cyan }
function Write-Success { param([string]$m) Write-Host "OK $m" -ForegroundColor Green }
function Write-Warn    { param([string]$m) Write-Host "!! $m" -ForegroundColor Yellow }
function Write-Fail    { param([string]$m) Write-Host "[FAIL] $m" -ForegroundColor Red }

# ============================================================================
# HELPER FUNCTIONS - GENERAL
# ============================================================================

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    elseif ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    elseif ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    else { return ('{0} B' -f $Bytes) }
}

function Get-ObjProp {
    param($obj, [Parameter(Mandatory = $true)][string]$prop, $fallback = $null)
    if ($null -eq $obj) { return $fallback }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($prop)) { return $obj[$prop] }
        return $fallback
    }
    $p = $obj.PSObject.Properties[$prop]
    if ($null -ne $p) { return $p.Value }
    return $fallback
}

function Get-NestedObjProp {
    param($obj, [string]$path, $fallback = $null)
    $current = $obj
    foreach ($part in ($path -split '\.')) {
        $current = Get-ObjProp -obj $current -prop $part -fallback $null
        if ($null -eq $current) { return $fallback }
    }
    return $current
}

function ConvertTo-SafeDate {
    param($value)
    if (-not $value) { return $null }
    try {
        return [DateTime]::Parse([string]$value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    catch {
        return $null
    }
}

function Get-ActivityStatus {
    param($DaysSinceActivity, [int]$StaleThreshold)
    if ($null -eq $DaysSinceActivity) { return '[UNKNOWN] No activity data' }
    $d = [int]$DaysSinceActivity
    if ($d -le 30) { return '[ACTIVE] Active (0-30 days)' }
    elseif ($d -le 90) { return '[RECENT] Recent (31-90 days)' }
    elseif ($d -le $StaleThreshold) { return "[DORMANT] Dormant (91-$StaleThreshold days)" }
    else { return "[STALE] Stale (>$StaleThreshold days)" }
}

function Get-MigrationBatch {
    param(
        [int]$BlockerCount,
        [int]$WarningCount,
        [long]$SizeBytes,
        [int]$PipelineCount,
        [int]$ReleasePipelineCount,
        [string]$ActivityStatus,
        [bool]$IsFork,
        [int]$ActivePRCount = 0
    )
    if ($BlockerCount -gt 0) { return 'Batch 0 - Remediate First (not yet eligible)' }
    if ($IsFork) { return 'Batch 4 - Forks (confirm ownership before migrating)' }
    if ($ActivePRCount -gt 0) { return 'Batch 3 - Complex (has open PRs - coordinate a freeze/cutover window)' }

    $isStale = ($ActivityStatus -match 'STALE|DORMANT')
    $isSimple = ($PipelineCount -le 1 -and $ReleasePipelineCount -eq 0 -and $WarningCount -eq 0)

    if ($isStale -and $isSimple -and $SizeBytes -lt 1GB) {
        return 'Batch 1 - Pilot (low risk, low activity)'
    }
    if ($ReleasePipelineCount -gt 0 -or $PipelineCount -gt 2 -or $WarningCount -gt 0) {
        return 'Batch 3 - Complex (coordinate pipeline cutover)'
    }
    return 'Batch 2 - Standard'
}

# ============================================================================
# HELPER FUNCTIONS - ADO REST API
# ============================================================================

function Invoke-ADORestApi {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [int]$MaxRetries = 6
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $resp = Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -ErrorAction Stop
            return $resp
        }
        catch {
            $err = $_
            $statusCode = 0
            $retryAfter = 30

            $webEx = $err.Exception -as [System.Net.WebException]
            if ($null -ne $webEx -and $null -ne $webEx.Response) {
                try {
                    $httpResp = [System.Net.HttpWebResponse]$webEx.Response
                    $statusCode = [int]$httpResp.StatusCode
                    $raHeader = $httpResp.Headers['Retry-After']
                    if ($raHeader) {
                        $parsed = 0
                        if ([int]::TryParse($raHeader, [ref]$parsed)) { $retryAfter = $parsed }
                    }
                }
                catch { $statusCode = 0 }
            }

            if ($attempt -ge $MaxRetries) {
                throw "Invoke-ADORestApi failed after $attempt attempts calling '$Uri': $($err.Exception.Message)"
            }

            if ($statusCode -eq 429) {
                Write-Warn "Rate limited (429) calling $Uri - waiting $retryAfter s (attempt $attempt/$MaxRetries)"
                Start-Sleep -Seconds $retryAfter
            }
            elseif ($statusCode -eq 503) {
                $backoff = [Math]::Min(60, [Math]::Pow(2, $attempt))
                Write-Warn "Service unavailable (503) calling $Uri - backing off $backoff s (attempt $attempt/$MaxRetries)"
                Start-Sleep -Seconds $backoff
            }
            else {
                $backoff = [Math]::Min(30, [Math]::Pow(2, $attempt))
                Write-Warn "Request error calling $Uri - backing off $backoff s (attempt $attempt/$MaxRetries): $($err.Exception.Message)"
                Start-Sleep -Seconds $backoff
            }
        }
    }
}

# ============================================================================
# HELPER FUNCTIONS - PIPELINE COLLECTION
# ============================================================================

function Get-ADOBuildDefinitions {
    param([string]$ProjectId, [hashtable]$Headers)
    $uri = "$script:ADOBaseUrl/$ProjectId/_apis/build/definitions?api-version=7.1&`$top=1000"
    try {
        $resp = Invoke-ADORestApi -Uri $uri -Headers $Headers -MaxRetries 3
        $vp = $resp.PSObject.Properties['value']
        if ($null -ne $vp) { return @($vp.Value) }
    }
    catch {
        Write-Warn "Could not fetch build definitions for project '$ProjectId': $($_.Exception.Message)"
    }
    return @()
}

function Get-ADOLatestBuild {
    param([string]$ProjectId, $DefinitionId, [hashtable]$Headers)
    try {
        $uri = "$script:ADOBaseUrl/$ProjectId/_apis/build/builds?definitions=$DefinitionId&`$top=1&queryOrder=queueTimeDescending&api-version=7.1"
        $resp = Invoke-ADORestApi -Uri $uri -Headers $Headers -MaxRetries 2
        $vp = $resp.PSObject.Properties['value']
        if ($null -ne $vp -and @($vp.Value).Count -gt 0) { return @($vp.Value)[0] }
    }
    catch { }
    return $null
}

function Get-ADOReleaseDefinitions {
    param([string]$ProjectId, [hashtable]$Headers)
    $uri = "$script:VSRMBaseUrl/$ProjectId/_apis/release/definitions?api-version=7.1&`$top=1000"
    try {
        $resp = Invoke-ADORestApi -Uri $uri -Headers $Headers -MaxRetries 3
        $vp = $resp.PSObject.Properties['value']
        if ($null -ne $vp) { return @($vp.Value) }
    }
    catch {
        Write-Warn "Could not fetch release definitions for project '$ProjectId' (Release Management may not be enabled): $($_.Exception.Message)"
    }
    return @()
}

function Get-ADOReleaseDefinitionDetail {
    param([string]$ProjectId, $DefinitionId, [hashtable]$Headers)
    try {
        $uri = "$script:VSRMBaseUrl/$ProjectId/_apis/release/definitions/${DefinitionId}?api-version=7.1"
        return Invoke-ADORestApi -Uri $uri -Headers $Headers -MaxRetries 2
    }
    catch { return $null }
}

function Get-ADOLatestRelease {
    param([string]$ProjectId, $DefinitionId, [hashtable]$Headers)
    try {
        $uri = "$script:VSRMBaseUrl/$ProjectId/_apis/release/releases?definitionId=$DefinitionId&`$top=1&queryOrder=descending&api-version=7.1"
        $resp = Invoke-ADORestApi -Uri $uri -Headers $Headers -MaxRetries 2
        $vp = $resp.PSObject.Properties['value']
        if ($null -ne $vp -and @($vp.Value).Count -gt 0) { return @($vp.Value)[0] }
    }
    catch { }
    return $null
}

function Get-ADOYamlContent {
    param([string]$ProjectId, [string]$RepoId, [string]$Path, [hashtable]$Headers)
    if (-not $Path) { return $null }
    try {
        $encodedPath = [Uri]::EscapeDataString($Path)
        $uri = "$script:ADOBaseUrl/$ProjectId/_apis/git/repositories/$RepoId/items?path=$encodedPath&includeContent=true&api-version=7.1"
        $resp = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get -ErrorAction Stop
        $contentProp = $resp.PSObject.Properties['content']
        if ($null -ne $contentProp) { return $contentProp.Value }
    }
    catch { }
    return $null
}

function Get-ADOActivePullRequests {
    param([string]$ProjectId, [string]$RepoId, [hashtable]$Headers)
    try {
        $uri = "$script:ADOBaseUrl/$ProjectId/_apis/git/repositories/$RepoId/pullrequests?searchCriteria.status=active&`$top=1000&api-version=7.1"
        $resp = Invoke-ADORestApi -Uri $uri -Headers $Headers -MaxRetries 2
        $vp = $resp.PSObject.Properties['value']
        if ($null -ne $vp) { return @($vp.Value) }
    }
    catch {
        # non-fatal - best effort only
    }
    return @()
}

function Test-ActionsImporterCli {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { return $false }
    try {
        $ext = (& gh extension list 2>&1 | Out-String)
        return ($ext -match 'actions-importer')
    }
    catch { return $false }
}

function Get-YamlActionsImporterReadiness {
    param([string]$YamlContent)

    if (-not $YamlContent) {
        return [PSCustomObject]@{
            Readiness   = 'Unknown - could not read YAML source (check PAT Code:Read scope)'
            ReviewTasks = @()
        }
    }

    $taskMatches = [regex]::Matches($YamlContent, '(?im)^\s*-?\s*task:\s*([A-Za-z0-9_.]+)@?\d*')
    if ($taskMatches.Count -eq 0) {
        return [PSCustomObject]@{
            Readiness   = 'Likely Automatable (script-only pipeline, no marketplace tasks detected)'
            ReviewTasks = @()
        }
    }

    $supported = 0
    $reviewTasks = New-Object System.Collections.Generic.List[string]
    foreach ($m in $taskMatches) {
        $rawName = $m.Groups[1].Value
        $taskName = ($rawName -split '@')[0].ToLowerInvariant().Trim()
        if ($script:SupportedAdoTasks -contains $taskName) {
            $supported++
        }
        else {
            if (-not $reviewTasks.Contains($rawName)) { $reviewTasks.Add($rawName) }
        }
    }

    $total = $taskMatches.Count
    $pct = if ($total -gt 0) { [Math]::Round(($supported / $total) * 100, 0) } else { 100 }
    $readinessText = if ($reviewTasks.Count -eq 0) {
        "Likely Automatable ($pct% of tasks recognized)"
    }
    else {
        "Needs Manual Review ($pct% of tasks recognized, $($reviewTasks.Count) task type(s) to check)"
    }

    return [PSCustomObject]@{
        Readiness   = $readinessText
        ReviewTasks = $reviewTasks
    }
}

# ============================================================================
# HELPER FUNCTIONS - EXCEL
# ============================================================================

function Set-Cell {
    param(
        $ws, [int]$row, [int]$col, $value,
        [string]$bgColor, [string]$fgColor, [bool]$bold = $false,
        [int]$fontSize = 11, [string]$hAlign, [bool]$wrapText = $false
    )
    $cell = $ws.Cells[$row, $col]
    $cell.Value = $value
    $cell.Style.Font.Size = $fontSize
    $cell.Style.Font.Bold = $bold
    if ($fgColor) { $cell.Style.Font.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml("#$fgColor")) }
    if ($bgColor) {
        $cell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
        $cell.Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml("#$bgColor"))
    }
    if ($hAlign) { $cell.Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::$hAlign }
    if ($wrapText) { $cell.Style.WrapText = $true }
    return $cell
}

function Set-Border {
    param($ws, [int]$row, [int]$col)
    $cell = $ws.Cells[$row, $col]
    $cell.Style.Border.Top.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
    $cell.Style.Border.Bottom.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
    $cell.Style.Border.Left.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
    $cell.Style.Border.Right.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
}

function Write-SheetHeader {
    param($ws, [string]$title, [int]$colSpan, [string]$bgColor)
    $ws.Cells[1, 1, 1, $colSpan].Merge = $true
    Set-Cell -ws $ws -row 1 -col 1 -value $title -bgColor $bgColor -fgColor $colWhite -bold $true -fontSize 18 -hAlign 'Left'
    $ws.Row(1).Height = 32
}

function Write-TableHeaders {
    param($ws, [int]$row, [string[]]$headers, [string]$bgColor)
    for ($i = 0; $i -lt $headers.Count; $i++) {
        $col = $i + 1
        Set-Cell -ws $ws -row $row -col $col -value $headers[$i] -bgColor $bgColor -fgColor $colWhite -bold $true -hAlign 'Left'
        Set-Border -ws $ws -row $row -col $col
    }
    $ws.Row($row).Height = 20
}

# ============================================================================
# GIT-SIZER PARSING (regex only - git-sizer JSON contains ^{tree} annotations
# that break every PowerShell JSON parser)
# ============================================================================

function Read-GsNumber {
    param([string]$text, [string]$field)
    if ($text -match ('"' + $field + '":\s*(\d+)')) { return [long]$Matches[1] }
    return [long]0
}

# ============================================================================
# GIT-SIZER ANALYSIS
# ============================================================================

function Invoke-GitSizerAnalysis {
    param(
        [Parameter(Mandatory = $true)][string]$RepoName,
        [Parameter(Mandatory = $true)][string]$CloneUrl,
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [Parameter(Mandatory = $true)][string]$GitSizerBin,
        [Parameter(Mandatory = $true)][string]$PlainPat,
        [long]$RepoSizeBytes = 0
    )

    $result = [PSCustomObject]@{
        Analysed            = $false
        Error               = ''
        TotalBlobSizeBytes  = [long]0
        MaxBlobSizeBytes    = [long]0
        MaxBlobName         = ''
        MaxCommitSizeBytes  = [long]0
        MaxRefNameBytes     = [long]0
        TreeCount           = [long]0
        CommitCount         = [long]0
        BlobCount           = [long]0
        TagCount            = [long]0
        HasLFS              = $false
        OverSizeBlocker     = $false
        LargeFileBlocker    = $false
        LargeFileWarning    = $false
        LargeCommitBlocker  = $false
        LongRefBlocker      = $false
        BlockerCount        = 0
        WarningCount        = 0
        Blockers            = New-Object System.Collections.Generic.List[string]
        Warnings            = New-Object System.Collections.Generic.List[string]
        Recommendations     = New-Object System.Collections.Generic.List[string]
    }

    $cloneDir = Join-Path $WorkDir ([Guid]::NewGuid().ToString('N'))

    try {
        $requiredBytes = [Math]::Max(512MB, [long]($RepoSizeBytes * 0.75))
        try {
            $drive = (Split-Path -Qualifier $WorkDir)
            $psDrive = Get-PSDrive ($drive.TrimEnd(':')) -ErrorAction Stop
            if ($psDrive.Free -lt $requiredBytes) {
                throw "Insufficient disk space for '$RepoName': need $(Format-Bytes $requiredBytes), have $(Format-Bytes $psDrive.Free)"
            }
        }
        catch {
            if ($_.Exception.Message -like 'Insufficient disk space*') { throw }
            Write-Warn "Could not verify free disk space for '$RepoName' - continuing without the check"
        }

        if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }

        if ($CloneUrl -match '@') {
            $authUrl = $CloneUrl -replace '^https://[^@]+@', "https://pat:$PlainPat@"
        }
        else {
            $authUrl = $CloneUrl -replace '^https://', "https://pat:$PlainPat@"
        }

        $cloneOutput = & git clone --bare --quiet $authUrl $cloneDir 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE): $cloneOutput" }

        $gsFullText = $null
        try {
            $env:GIT_DIR = $cloneDir
            $gsOutput = & $GitSizerBin --json --no-progress 2>&1
            if ($LASTEXITCODE -ne 0) { $gsOutput = & $GitSizerBin --json 2>&1 }
            $gsFullText = ($gsOutput | Out-String)
        }
        finally {
            Remove-Item Env:\GIT_DIR -ErrorAction SilentlyContinue
        }

        $result.TotalBlobSizeBytes = Read-GsNumber $gsFullText 'unique_blob_size'
        $result.MaxBlobSizeBytes   = Read-GsNumber $gsFullText 'max_blob_size'
        $result.MaxCommitSizeBytes = Read-GsNumber $gsFullText 'max_commit_size'
        $result.MaxRefNameBytes    = Read-GsNumber $gsFullText 'max_path_length'
        $result.TreeCount          = Read-GsNumber $gsFullText 'unique_tree_count'
        $result.CommitCount        = Read-GsNumber $gsFullText 'unique_commit_count'
        $result.BlobCount          = Read-GsNumber $gsFullText 'unique_blob_count'
        $result.TagCount           = Read-GsNumber $gsFullText 'max_tag_depth'

        if ($gsFullText -match '"max_blob_size_blob":\s*"([^"]+)"') {
            $ann = $Matches[1]
            $colon = $ann.LastIndexOf(':')
            if ($colon -ge 0) { $result.MaxBlobName = $ann.Substring($colon + 1).TrimEnd(')').Trim() }
        }

        $hasLfs = $false
        if (Test-Path (Join-Path $cloneDir 'lfsconfig')) { $hasLfs = $true }
        if (-not $hasLfs) {
            try {
                $attrOut = & git -C $cloneDir show 'HEAD:.gitattributes' 2>&1
                if (($attrOut | Out-String) -match 'filter=lfs') { $hasLfs = $true }
            }
            catch { }
        }
        $result.HasLFS = $hasLfs

        if ($result.TotalBlobSizeBytes -ge $GH_REPO_MAX_BYTES) {
            $result.OverSizeBlocker = $true
            $result.Blockers.Add("Repository unique blob size $(Format-Bytes $result.TotalBlobSizeBytes) exceeds GEI limit of $(Format-Bytes $GH_REPO_MAX_BYTES)")
        }
        if ($result.MaxBlobSizeBytes -ge $GH_FILE_BLOCKER_BYTES) {
            $result.LargeFileBlocker = $true
            $result.Blockers.Add("Largest file '$($result.MaxBlobName)' is $(Format-Bytes $result.MaxBlobSizeBytes), exceeds GEI file blocker limit of $(Format-Bytes $GH_FILE_BLOCKER_BYTES)")
        }
        elseif ($result.MaxBlobSizeBytes -ge $GH_FILE_WARNING_BYTES) {
            $result.LargeFileWarning = $true
            $result.Warnings.Add("Largest file '$($result.MaxBlobName)' is $(Format-Bytes $result.MaxBlobSizeBytes), exceeds GEI warning threshold of $(Format-Bytes $GH_FILE_WARNING_BYTES)")
        }
        if ($result.MaxCommitSizeBytes -ge $GH_COMMIT_MAX_BYTES) {
            $result.LargeCommitBlocker = $true
            $result.Blockers.Add("Largest commit is $(Format-Bytes $result.MaxCommitSizeBytes), exceeds GEI commit limit of $(Format-Bytes $GH_COMMIT_MAX_BYTES)")
        }
        if ($result.MaxRefNameBytes -gt $GH_REF_MAX_BYTES) {
            $result.LongRefBlocker = $true
            $result.Blockers.Add("Longest ref/path is $($result.MaxRefNameBytes) bytes, exceeds GEI limit of $GH_REF_MAX_BYTES bytes")
        }
        if ($result.HasLFS) {
            $result.Warnings.Add('Repository uses Git LFS - LFS objects require a manual push to GitHub after migration')
            $result.Recommendations.Add('Run "git lfs push --all <destination>" manually after the GEI migration completes')
        }

        $result.BlockerCount = $result.Blockers.Count
        $result.WarningCount = $result.Warnings.Count
        $result.Analysed = $true
    }
    catch {
        $msg = $_.Exception.Message
        $result.Error = $msg

        if ($msg -match 'pack has bad object|inflate returned|index-pack output|corrupt|bad object') {
            $result.Blockers.Add('Repository pack data is CORRUPTED in ADO')
            $result.Recommendations.Add('Run "git fsck", contact your ADO admin, and re-push from a clean copy before migrating')
            $result.BlockerCount = $result.Blockers.Count
            Write-Fail "[CORRUPTED REPO] $RepoName - $msg"
        }
        elseif ($msg -match 'git clone failed') {
            $result.Warnings.Add('git-sizer analysis could not clone the repository')
            $result.Recommendations.Add('Check that the PAT has Code:Read scope for this project')
            $result.WarningCount = $result.Warnings.Count
            Write-Warn "$RepoName - $msg"
        }
        else {
            Write-Warn "$RepoName - git-sizer analysis skipped: $msg"
        }
    }
    finally {
        if ($KeepClones) {
            if (Test-Path $cloneDir) { Write-Warn "Keeping clone for '$RepoName' at $cloneDir (-KeepClones set)" }
        }
        else {
            if (Test-Path $cloneDir) {
                try {
                    Get-ChildItem -LiteralPath $cloneDir -Recurse -Force -ErrorAction SilentlyContinue |
                        ForEach-Object { $_.Attributes = 'Normal' }
                    Remove-Item -LiteralPath $cloneDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                catch { }
            }
        }
    }

    return $result
}

# ============================================================================
# BOOTSTRAP SEQUENCE
# ============================================================================

Write-Step "Bootstrapping Get-ADOInventory for organisation '$Organisation'"

# --- 1. Resolve PAT ---
$plainPat = $null
if ($PAT -is [System.Security.SecureString]) {
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PAT)
    try { $plainPat = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
else {
    $plainPat = [string]$PAT
}

$basicToken = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$plainPat"))
$authHeaders = @{ Authorization = "Basic $basicToken" }

# --- 2. Install / import ImportExcel ---
Write-Step 'Checking for NuGet package provider and ImportExcel module'
try {
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge '2.8.5.201' }
    if (-not (@($nuget)).Count) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
}
catch {
    Write-Warn "Could not verify/install NuGet provider: $($_.Exception.Message)"
}

if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-Step 'Installing ImportExcel module from PSGallery'
    Install-Module -Name ImportExcel -Scope CurrentUser -Force -AllowClobber
}
Import-Module ImportExcel -ErrorAction Stop
Write-Success 'ImportExcel module ready'

# --- 3. git-sizer bootstrap (only if requested) ---
function Find-GitSizerBinary {
    param([string]$ExplicitPath)

    if ($ExplicitPath -and $ExplicitPath -ne 'git-sizer' -and (Test-Path $ExplicitPath)) { return $ExplicitPath }

    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    foreach ($candidate in @((Join-Path $scriptDir 'git-sizer.exe'), (Join-Path $scriptDir 'git-sizer'))) {
        if (Test-Path $candidate) { return $candidate }
    }
    foreach ($candidate in @((Join-Path (Get-Location) 'git-sizer.exe'), (Join-Path (Get-Location) 'git-sizer'))) {
        if (Test-Path $candidate) { return $candidate }
    }
    foreach ($name in @('git-sizer.exe', 'git-sizer')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Install-GitSizerBinary {
    Write-Step 'Attempting to auto-install git-sizer'

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        try {
            & winget install --id github.git-sizer -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            $found = Find-GitSizerBinary -ExplicitPath ''
            if ($found) { return $found }
        }
        catch { Write-Warn "winget install of git-sizer failed: $($_.Exception.Message)" }
    }

    try {
        Write-Step 'Downloading git-sizer release archive from GitHub'
        $releaseApi = 'https://api.github.com/repos/github/git-sizer/releases/latest'
        $release = Invoke-RestMethod -Uri $releaseApi -Headers @{ 'User-Agent' = 'Get-ADOInventory' }
        $asset = $release.assets | Where-Object { $_.name -match 'windows' -and $_.name -match 'amd64|64' } | Select-Object -First 1
        if ($asset) {
            $downloadDir = Join-Path $env:TEMP "git-sizer-install-$($script:Timestamp)"
            New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
            $zipPath = Join-Path $downloadDir $asset.name
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
            Expand-Archive -Path $zipPath -DestinationPath $downloadDir -Force
            $found = Get-ChildItem -Path $downloadDir -Recurse -Filter 'git-sizer*.exe' | Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }
    catch { Write-Warn "Direct GitHub release download of git-sizer failed: $($_.Exception.Message)" }

    $brew = Get-Command brew -ErrorAction SilentlyContinue
    if ($brew) {
        try {
            & brew install git-sizer 2>&1 | Out-Null
            $found = Find-GitSizerBinary -ExplicitPath ''
            if ($found) { return $found }
        }
        catch { Write-Warn "brew install of git-sizer failed: $($_.Exception.Message)" }
    }

    return $null
}

if ($RunGitSizer) {
    Write-Step 'Checking git availability for -RunGitSizer'
    try {
        $gitVersion = & git --version 2>&1
        Write-Success "git found: $gitVersion"
    }
    catch {
        Write-Warn 'git is not available on PATH - disabling -RunGitSizer'
        $RunGitSizer = $false
    }

    if ($RunGitSizer) {
        $resolvedGitSizer = Find-GitSizerBinary -ExplicitPath $GitSizerPath
        if (-not $resolvedGitSizer) { $resolvedGitSizer = Install-GitSizerBinary }

        if (-not $resolvedGitSizer) {
            Write-Warn 'git-sizer could not be found or installed - disabling -RunGitSizer (inventory will still run)'
            $RunGitSizer = $false
        }
        else {
            $GitSizerPath = $resolvedGitSizer
            Write-Success "Using git-sizer at: $GitSizerPath"
            if (-not (Test-Path $GitSizerWorkDir)) { New-Item -ItemType Directory -Path $GitSizerWorkDir -Force | Out-Null }
        }
    }
}

# --- 3b. GitHub Actions Importer CLI detection (only if requested) ---
$script:ActionsImporterCliAvailable = $false
if ($CheckActionsImporter) {
    Write-Step 'Checking for the gh actions-importer CLI (optional, best-effort)'
    $script:ActionsImporterCliAvailable = Test-ActionsImporterCli
    if ($script:ActionsImporterCliAvailable) {
        Write-Success 'gh actions-importer extension detected - authoritative audits are not run automatically by this script; see README.md section 8 for how to run one alongside this report'
    }
    else {
        Write-Warn 'gh actions-importer CLI not found - falling back to heuristic task-name scan for YAML pipeline readiness (see README.md section 8)'
    }
}

# --- 4. Validate ADO connection ---
Write-Step 'Validating Azure DevOps connection'
try {
    $testUri = "$script:ADOBaseUrl/_apis/projects?api-version=7.1&`$top=1"
    Invoke-ADORestApi -Uri $testUri -Headers $authHeaders -MaxRetries 3 | Out-Null
    Write-Success 'Azure DevOps connection validated'
}
catch {
    Write-Fail "Could not connect to Azure DevOps organisation '$Organisation': $($_.Exception.Message)"
    exit 1
}

# ============================================================================
# ADO API DATA COLLECTION
# ============================================================================

Write-Step 'Fetching projects'

$allProjects = New-Object System.Collections.Generic.List[object]
$continuationToken = $null

do {
    $uri = "$script:ADOBaseUrl/_apis/projects?api-version=7.1&`$top=100"
    if ($continuationToken) { $uri += "&continuationToken=$continuationToken" }

    $resp = Invoke-ADORestApi -Uri $uri -Headers $authHeaders

    $valueProp = $resp.PSObject.Properties['value']
    if ($null -ne $valueProp) { foreach ($p in $valueProp.Value) { $allProjects.Add($p) } }

    $continuationToken = $null
    $ctProp = $resp.PSObject.Properties['continuationToken']
    if ($null -ne $ctProp) { $continuationToken = $ctProp.Value }
}
while ($continuationToken)

if (-not $IncludeDisabledProjects) {
    $allProjects = [System.Collections.Generic.List[object]](@($allProjects | Where-Object { (Get-ObjProp $_ 'state' '') -eq 'wellFormed' }))
}
$allProjects = [System.Collections.Generic.List[object]](@($allProjects | Sort-Object -Property { Get-ObjProp $_ 'name' '' }))

Write-Success "Found $($allProjects.Count) project(s)"

$projectSummary    = New-Object System.Collections.Generic.List[object]
$repoDetailRows    = New-Object System.Collections.Generic.List[object]
$migrationRows     = New-Object System.Collections.Generic.List[object]
$compatibilityRows = New-Object System.Collections.Generic.List[object]
$pipelineRows      = New-Object System.Collections.Generic.List[object]

$totalRepos = 0
$totalBytes = [long]0
$totalMigrationBlockers = 0
$totalMigrationWarnings = 0
$totalBuildPipelines = 0
$totalReleasePipelines = 0
$projIndex = 0
$now = Get-Date

foreach ($project in $allProjects) {
    $projIndex++
    $projName = Get-ObjProp $project 'name' ''
    $projId   = Get-ObjProp $project 'id' ''

    Write-Step "[$projIndex/$($allProjects.Count)] Processing project '$projName'"

    $description   = Get-ObjProp $project 'description' ''
    $visibility    = Get-ObjProp $project 'visibility' ''
    $state         = Get-ObjProp $project 'state' ''
    $lastUpdate    = Get-ObjProp $project 'lastUpdateTime' ''
    $capabilities  = Get-ObjProp $project 'capabilities' $null
    $processTemplate = Get-NestedObjProp $capabilities 'processTemplate.templateName' 'Unknown'
    $vcsType         = Get-NestedObjProp $capabilities 'versioncontrol.sourceControlType' 'Unknown'
    $isTfvc = ($vcsType -eq 'Tfvc')

    # --- Fetch repos for this project ---
    $reposUri = "$script:ADOBaseUrl/$projId/_apis/git/repositories?api-version=7.1"
    $repos = @()
    try {
        $repoResp = Invoke-ADORestApi -Uri $reposUri -Headers $authHeaders
        $rvProp = $repoResp.PSObject.Properties['value']
        if ($null -ne $rvProp) { $repos = @($rvProp.Value) }
    }
    catch {
        Write-Warn "Could not fetch repositories for project '$projName': $($_.Exception.Message)"
        $repos = @()
    }

    if ($ExcludeEmptyRepos) { $repos = @($repos | Where-Object { [long](Get-ObjProp $_ 'size' 0) -gt 0 }) }
    $repos = @($repos | Sort-Object -Property { [long](Get-ObjProp $_ 'size' 0) } -Descending)

    # --- Pipeline inventory for this project (collected once, mapped to repos) ---
    $buildDefsByRepo = @{}
    $releaseDefsByRepo = @{}
    $unmappedReleaseDefs = New-Object System.Collections.Generic.List[object]

    if (-not $SkipPipelineInventory) {
        Write-Step "  Fetching build/release pipelines for project '$projName'"
        $buildDefs = Get-ADOBuildDefinitions -ProjectId $projId -Headers $authHeaders
        foreach ($bd in $buildDefs) {
            $repoId = Get-NestedObjProp $bd 'repository.id' ''
            if ($repoId) {
                if (-not $buildDefsByRepo.ContainsKey($repoId)) { $buildDefsByRepo[$repoId] = New-Object System.Collections.Generic.List[object] }
                $buildDefsByRepo[$repoId].Add($bd)
            }
        }
        $totalBuildPipelines += $buildDefs.Count

        $releaseDefsSummary = Get-ADOReleaseDefinitions -ProjectId $projId -Headers $authHeaders
        foreach ($rdSummary in $releaseDefsSummary) {
            $rdId = Get-ObjProp $rdSummary 'id' ''
            $rdDetail = Get-ADOReleaseDefinitionDetail -ProjectId $projId -DefinitionId $rdId -Headers $authHeaders
            $mappedRepoId = $null
            if ($rdDetail) {
                $artifacts = Get-ObjProp $rdDetail 'artifacts' @()
                foreach ($art in @($artifacts)) {
                    $artType = Get-ObjProp $art 'type' ''
                    if ($artType -eq 'Build') {
                        $buildDefId = Get-NestedObjProp $art 'definitionReference.definition.id' ''
                        $matchingBd = $buildDefs | Where-Object { (Get-ObjProp $_ 'id' '') -eq $buildDefId } | Select-Object -First 1
                        if ($matchingBd) { $mappedRepoId = Get-NestedObjProp $matchingBd 'repository.id' '' }
                    }
                    elseif ($artType -match 'Git') {
                        $candidateRepoId = Get-NestedObjProp $art 'definitionReference.definition.id' ''
                        if ($candidateRepoId) { $mappedRepoId = $candidateRepoId }
                    }
                    if ($mappedRepoId) { break }
                }
            }

            $rdObj = [PSCustomObject]@{ Definition = $rdSummary; RepoId = $mappedRepoId }
            if ($mappedRepoId) {
                if (-not $releaseDefsByRepo.ContainsKey($mappedRepoId)) { $releaseDefsByRepo[$mappedRepoId] = New-Object System.Collections.Generic.List[object] }
                $releaseDefsByRepo[$mappedRepoId].Add($rdSummary)
            }
            else {
                $unmappedReleaseDefs.Add($rdSummary)
            }
        }
        $totalReleasePipelines += $releaseDefsSummary.Count

        # Record unmapped release pipelines directly into the pipeline inventory
        foreach ($rd in $unmappedReleaseDefs) {
            $rdId = Get-ObjProp $rd 'id' ''
            $rdName = Get-ObjProp $rd 'name' ''
            $latestRel = Get-ADOLatestRelease -ProjectId $projId -DefinitionId $rdId -Headers $authHeaders
            $lastRelDate = ConvertTo-SafeDate (Get-ObjProp $latestRel 'createdOn' $null)
            $lastRelStatus = Get-ObjProp $latestRel 'status' 'Unknown'

            $pipelineRows.Add([PSCustomObject]@{
                'Project Name'                = $projName
                'Repository Name'             = 'Unmapped / Multiple'
                'Pipeline Name'               = $rdName
                'Pipeline Type'               = 'Release (Classic)'
                'Definition Type'             = 'Classic Release'
                'Last Run Date'               = $(if ($lastRelDate) { $lastRelDate.ToString('yyyy-MM-dd') } else { 'Never run' })
                'Last Run Result'             = $lastRelStatus
                'Enabled'                     = $true
                'Actions Importer Readiness'  = 'Manual - Release pipelines require re-implementation as GitHub Actions environments/deployment jobs'
                'Notes'                       = 'Could not automatically map this release pipeline to a single source repository'
            })
        }
    }

    $projectTotalBytes = [long]0
    $projectBlockerCount = 0
    $repoRank = 0

    foreach ($repo in $repos) {
        $repoRank++
        $repoName    = Get-ObjProp $repo 'name' ''
        $repoId      = Get-ObjProp $repo 'id' ''
        $defaultBranch = Get-ObjProp $repo 'defaultBranch' ''
        $sizeBytes   = [long](Get-ObjProp $repo 'size' 0)
        $isDisabled  = [bool](Get-ObjProp $repo 'isDisabled' $false)
        $isFork      = ($null -ne (Get-ObjProp $repo 'isFork' $null))
        $remoteUrl   = Get-ObjProp $repo 'remoteUrl' ''
        $sshUrl      = Get-ObjProp $repo 'sshUrl' ''

        $branchName = 'main'
        if ($defaultBranch) { $branchName = ($defaultBranch -replace '^refs/heads/', '') }

        # --- Last commit date (best-effort) ---
        $lastCommitDate = $null
        try {
            $commitsUri = "$script:ADOBaseUrl/$projId/_apis/git/repositories/$repoId/commits?searchCriteria.itemVersion.version=$branchName&searchCriteria.`$top=1&api-version=7.1"
            $commitResp = Invoke-ADORestApi -Uri $commitsUri -Headers $authHeaders -MaxRetries 2
            $cvProp = $commitResp.PSObject.Properties['value']
            if ($null -ne $cvProp -and @($cvProp.Value).Count -gt 0) {
                $firstCommit = @($cvProp.Value)[0]
                $committerDate = Get-NestedObjProp $firstCommit 'committer.date' ''
                if ($committerDate) { $lastCommitDate = ConvertTo-SafeDate $committerDate }
            }
        }
        catch { }

        $projectTotalBytes += $sizeBytes

        # --- Active pull requests (best-effort) ---
        $activePRs = Get-ADOActivePullRequests -ProjectId $projId -RepoId $repoId -Headers $authHeaders
        $activePRCount = @($activePRs).Count
        $oldestActivePRDays = $null
        if ($activePRCount -gt 0) {
            $creationDates = @($activePRs | ForEach-Object { ConvertTo-SafeDate (Get-ObjProp $_ 'creationDate' $null) } | Where-Object { $_ })
            if ($creationDates.Count -gt 0) {
                $oldestDate = ($creationDates | Sort-Object)[0]
                $oldestActivePRDays = [int]($now - $oldestDate).TotalDays
            }
        }

        # --- Pipeline data for this repo ---
        $repoBuildDefs = @()
        if ($buildDefsByRepo.ContainsKey($repoId)) { $repoBuildDefs = $buildDefsByRepo[$repoId] }
        $repoReleaseDefs = @()
        if ($releaseDefsByRepo.ContainsKey($repoId)) { $repoReleaseDefs = $releaseDefsByRepo[$repoId] }

        $buildPipelineCount = @($repoBuildDefs).Count
        $releasePipelineCount = @($repoReleaseDefs).Count
        $lastPipelineDate = $null
        $lastPipelineResult = ''
        $worstActionsImporterReadiness = ''
        $importerReviewTaskSet = New-Object System.Collections.Generic.List[string]

        foreach ($bd in $repoBuildDefs) {
            $bdId = Get-ObjProp $bd 'id' ''
            $bdName = Get-ObjProp $bd 'name' ''
            $processType = Get-NestedObjProp $bd 'process.type' 1
            $isYaml = ([int]$processType -eq 2)
            $defTypeText = if ($isYaml) { 'YAML' } else { 'Classic (Designer)' }
            $queueStatus = Get-ObjProp $bd 'queueStatus' 'enabled'

            $latestBuild = Get-ADOLatestBuild -ProjectId $projId -DefinitionId $bdId -Headers $authHeaders
            $buildDate = $null
            $buildResult = 'Never run'
            if ($latestBuild) {
                $buildDate = ConvertTo-SafeDate (Get-ObjProp $latestBuild 'finishTime' (Get-ObjProp $latestBuild 'queueTime' $null))
                $buildResult = Get-ObjProp $latestBuild 'result' (Get-ObjProp $latestBuild 'status' 'Unknown')
            }
            if ($buildDate -and (-not $lastPipelineDate -or $buildDate -gt $lastPipelineDate)) {
                $lastPipelineDate = $buildDate
                $lastPipelineResult = $buildResult
            }

            $readinessText = 'Manual - Classic pipeline (no YAML source available for review)'
            if ($isYaml) {
                if ($CheckActionsImporter) {
                    $yamlPath = Get-NestedObjProp $bd 'process.yamlFilename' $null
                    $yamlContent = Get-ADOYamlContent -ProjectId $projId -RepoId $repoId -Path $yamlPath -Headers $authHeaders
                    $readiness = Get-YamlActionsImporterReadiness -YamlContent $yamlContent
                    $readinessText = $readiness.Readiness
                    foreach ($t in $readiness.ReviewTasks) { if (-not $importerReviewTaskSet.Contains($t)) { $importerReviewTaskSet.Add($t) } }
                }
                else {
                    $readinessText = 'Not checked (re-run with -CheckActionsImporter)'
                }
            }

            if ($readinessText -match 'Needs Manual Review' -or $readinessText -match 'Manual -') {
                $worstActionsImporterReadiness = $readinessText
            }
            elseif (-not $worstActionsImporterReadiness) {
                $worstActionsImporterReadiness = $readinessText
            }

            $pipelineRows.Add([PSCustomObject]@{
                'Project Name'               = $projName
                'Repository Name'            = $repoName
                'Pipeline Name'              = $bdName
                'Pipeline Type'              = 'Build'
                'Definition Type'            = $defTypeText
                'Last Run Date'              = $(if ($buildDate) { $buildDate.ToString('yyyy-MM-dd') } else { 'Never run' })
                'Last Run Result'            = $buildResult
                'Enabled'                    = ($queueStatus -eq 'enabled')
                'Actions Importer Readiness' = $readinessText
                'Notes'                      = ''
            })
        }

        foreach ($rd in $repoReleaseDefs) {
            $rdId = Get-ObjProp $rd 'id' ''
            $rdName = Get-ObjProp $rd 'name' ''
            $latestRel = Get-ADOLatestRelease -ProjectId $projId -DefinitionId $rdId -Headers $authHeaders
            $relDate = $null
            $relStatus = 'Never run'
            if ($latestRel) {
                $relDate = ConvertTo-SafeDate (Get-ObjProp $latestRel 'createdOn' $null)
                $relStatus = Get-ObjProp $latestRel 'status' 'Unknown'
            }
            if ($relDate -and (-not $lastPipelineDate -or $relDate -gt $lastPipelineDate)) {
                $lastPipelineDate = $relDate
                $lastPipelineResult = $relStatus
            }

            $releaseReadiness = 'Manual - Release pipelines require re-implementation as GitHub Actions environments/deployment jobs'
            $worstActionsImporterReadiness = $releaseReadiness

            $pipelineRows.Add([PSCustomObject]@{
                'Project Name'               = $projName
                'Repository Name'            = $repoName
                'Pipeline Name'              = $rdName
                'Pipeline Type'              = 'Release (Classic)'
                'Definition Type'            = 'Classic Release'
                'Last Run Date'              = $(if ($relDate) { $relDate.ToString('yyyy-MM-dd') } else { 'Never run' })
                'Last Run Result'            = $relStatus
                'Enabled'                    = $true
                'Actions Importer Readiness' = $releaseReadiness
                'Notes'                      = ''
            })
        }

        if (-not $worstActionsImporterReadiness) {
            $worstActionsImporterReadiness = if ($buildPipelineCount -eq 0 -and $releasePipelineCount -eq 0) { 'N/A - no pipelines found' } else { 'Not checked' }
        }

        # --- Last Used / activity status ---
        $activityCandidates = @()
        if ($lastCommitDate) { $activityCandidates += $lastCommitDate }
        if ($lastPipelineDate) { $activityCandidates += $lastPipelineDate }
        $lastUsedDate = $null
        if ($activityCandidates.Count -gt 0) { $lastUsedDate = ($activityCandidates | Sort-Object -Descending)[0] }
        $daysSinceActivity = $null
        if ($lastUsedDate) { $daysSinceActivity = [int]($now - $lastUsedDate).TotalDays }
        $activityStatus = Get-ActivityStatus -DaysSinceActivity $daysSinceActivity -StaleThreshold $InactivityThresholdDays

        # --- Size category ---
        if ($sizeBytes -ge 5GB) { $sizeCategory = '[LARGE] Large (>=5 GB)' }
        elseif ($sizeBytes -ge 1GB) { $sizeCategory = '[MEDIUM] Medium (1-5 GB)' }
        elseif ($sizeBytes -ge 100MB) { $sizeCategory = '[SMALL] Small (100 MB-1 GB)' }
        else { $sizeCategory = '[TINY] Tiny (<100 MB)' }

        # --- API-level quick checks ---
        $quickBlockers = New-Object System.Collections.Generic.List[string]
        $quickWarnings = New-Object System.Collections.Generic.List[string]

        if ($isTfvc) { $quickBlockers.Add('Project uses TFVC version control - GEI only migrates Git repositories') }
        if ($sizeBytes -ge $GH_REPO_MAX_BYTES) {
            $quickBlockers.Add("Repository size $(Format-Bytes $sizeBytes) exceeds GEI limit of $(Format-Bytes $GH_REPO_MAX_BYTES)")
        }
        elseif ($sizeBytes -ge $GH_REPO_WARN_BYTES) {
            $quickWarnings.Add("Repository size $(Format-Bytes $sizeBytes) is approaching the GEI limit of $(Format-Bytes $GH_REPO_MAX_BYTES)")
        }
        elseif ($sizeBytes -ge $GH_REPO_INFO_BYTES) {
            $quickWarnings.Add('Repository may contain large files - recommend running git-sizer for a full analysis')
        }
        if ($releasePipelineCount -gt 0) {
            $quickWarnings.Add("$releasePipelineCount classic Release pipeline(s) reference this repo - these need manual re-implementation as GitHub Actions deployment jobs")
        }
        if ($activePRCount -gt 0) {
            $prAgeNote = if ($null -ne $oldestActivePRDays) { ", oldest open $oldestActivePRDays day(s)" } else { '' }
            $quickWarnings.Add("$activePRCount active pull request(s) open on this repo$prAgeNote - coordinate a freeze/cutover window before migrating")
        }

        # --- Optional git-sizer analysis ---
        $gs = $null
        if ($RunGitSizer -and -not $isTfvc -and $sizeBytes -gt 0) {
            $cloneUrl = if ($remoteUrl) { $remoteUrl } else { $sshUrl }
            $gs = Invoke-GitSizerAnalysis -RepoName "$projName/$repoName" -CloneUrl $cloneUrl -WorkDir $GitSizerWorkDir -GitSizerBin $GitSizerPath -PlainPat $plainPat -RepoSizeBytes $sizeBytes
        }

        $blockersDetail  = New-Object System.Collections.Generic.List[string]
        $warningsDetail  = New-Object System.Collections.Generic.List[string]
        $recommendations = New-Object System.Collections.Generic.List[string]
        foreach ($b in $quickBlockers) { $blockersDetail.Add($b) }
        foreach ($w in $quickWarnings) { $warningsDetail.Add($w) }
        if ($gs -and $gs.Analysed) {
            foreach ($b in $gs.Blockers) { $blockersDetail.Add($b) }
            foreach ($w in $gs.Warnings) { $warningsDetail.Add($w) }
            foreach ($r in $gs.Recommendations) { $recommendations.Add($r) }
        }
        elseif ($gs -and $gs.Error) {
            foreach ($w in $gs.Warnings) { $warningsDetail.Add($w) }
            foreach ($b in $gs.Blockers) { $blockersDetail.Add($b) }
            foreach ($r in $gs.Recommendations) { $recommendations.Add($r) }
        }

        $blockerCount = $blockersDetail.Count
        $warningCount = $warningsDetail.Count
        $projectBlockerCount += $blockerCount
        $totalMigrationBlockers += $blockerCount
        $totalMigrationWarnings += $warningCount

        if ($blockerCount -gt 0) { $ghStatus = '[BLOCKED] BLOCKED' }
        elseif ($warningCount -gt 0) { $ghStatus = '[WARN] NEEDS REVIEW' }
        else { $ghStatus = '[OK] READY' }

        if ($blockerCount -gt 0) { $migPriority = '1 - Fix Before Migration' }
        elseif ($sizeBytes -ge 5GB) { $migPriority = '2 - Migrate with Care' }
        elseif ($sizeBytes -ge 1GB) { $migPriority = '3 - Standard (Large)' }
        else { $migPriority = '4 - Standard Migration' }

        if ($blockerCount -gt 0) { $migEffort = 'High - Remediation Required' }
        elseif ($warningCount -gt 0) { $migEffort = 'Medium - Review Required' }
        elseif ($sizeBytes -ge 1GB) { $migEffort = 'Medium' }
        else { $migEffort = 'Low' }

        $migBatch = Get-MigrationBatch -BlockerCount $blockerCount -WarningCount $warningCount -SizeBytes $sizeBytes `
            -PipelineCount $buildPipelineCount -ReleasePipelineCount $releasePipelineCount -ActivityStatus $activityStatus `
            -IsFork $isFork -ActivePRCount $activePRCount

        $repoDetailRows.Add([PSCustomObject]@{
            'Project Name'                = $projName
            'Rank in Project'             = $repoRank
            'Repository Name'             = $repoName
            'Default Branch'              = $branchName
            'Size'                        = Format-Bytes $sizeBytes
            'Size (Bytes)'                = $sizeBytes
            'Size Category'               = $sizeCategory
            'Last Commit Date'            = $(if ($lastCommitDate) { $lastCommitDate.ToString('yyyy-MM-dd') } else { 'Unknown' })
            'Build Pipeline Count'        = $buildPipelineCount
            'Release Pipeline Count'      = $releasePipelineCount
            'Last Pipeline Run'           = $(if ($lastPipelineDate) { $lastPipelineDate.ToString('yyyy-MM-dd') } else { 'Never / N-A' })
            'Last Used'                   = $(if ($lastUsedDate) { $lastUsedDate.ToString('yyyy-MM-dd') } else { 'Unknown' })
            'Activity Status'             = $activityStatus
            'Active PRs'                  = $activePRCount
            'Oldest Active PR (days)'     = $(if ($null -ne $oldestActivePRDays) { $oldestActivePRDays } else { '' })
            'Is Disabled'                 = $isDisabled
            'Is Fork'                     = $isFork
            'GH Migration Status'         = $ghStatus
            'Blockers'                    = $blockerCount
            'Warnings'                    = $warningCount
            'Actions Importer Readiness'  = $worstActionsImporterReadiness
            'Remote URL (HTTPS)'          = $remoteUrl
            'SSH URL'                     = $sshUrl
            'Repository ID'               = $repoId
        })

        $migrationRows.Add([PSCustomObject]@{
            'Project Name'         = $projName
            'Repository Name'      = $repoName
            'Size'                 = Format-Bytes $sizeBytes
            'Size (Bytes)'         = $sizeBytes
            'Size Category'        = $sizeCategory
            'GH Migration Status'  = $ghStatus
            'Blocker Count'        = $blockerCount
            'Warning Count'        = $warningCount
            'Build Pipelines'      = $buildPipelineCount
            'Release Pipelines'    = $releasePipelineCount
            'Last Used'            = $(if ($lastUsedDate) { $lastUsedDate.ToString('yyyy-MM-dd') } else { 'Unknown' })
            'Activity Status'      = $activityStatus
            'Active PRs'           = $activePRCount
            'Is Fork'              = $isFork
            'Migration Priority'   = $migPriority
            'Estimated Effort'     = $migEffort
            'Migration Batch'      = $migBatch
            'Migration Status'     = 'Pending'
            'Assigned To'          = ''
            'Notes'                = ''
            'Remote URL (HTTPS)'   = $remoteUrl
        })

        if ($blockerCount -gt 0 -or $warningCount -gt 0 -or ($gs -and $gs.Analysed) -or $worstActionsImporterReadiness -match 'Needs Manual Review|Manual -') {
            $totalBlobSize = if ($gs) { $gs.TotalBlobSizeBytes } else { 0 }
            $maxBlobSize   = if ($gs) { $gs.MaxBlobSizeBytes } else { 0 }
            $maxBlobName   = if ($gs) { $gs.MaxBlobName } else { '' }
            $maxCommitSize = if ($gs) { $gs.MaxCommitSizeBytes } else { 0 }
            $maxRefBytes   = if ($gs) { $gs.MaxRefNameBytes } else { 0 }
            $commitCount   = if ($gs) { $gs.CommitCount } else { 0 }
            $usesLfs       = if ($gs) { $gs.HasLFS } else { $false }
            $gsRun         = [bool]($gs -and $gs.Analysed)

            $compatibilityRows.Add([PSCustomObject]@{
                'Project Name'                = $projName
                'Repository Name'             = $repoName
                'Repo Size'                   = Format-Bytes $sizeBytes
                'GH Migration Status'         = $ghStatus
                'Blocker Count'               = $blockerCount
                'Warning Count'               = $warningCount
                'git-sizer Run'               = $gsRun
                'Total Blob Size'             = Format-Bytes $totalBlobSize
                'Largest File'                = Format-Bytes $maxBlobSize
                'Largest File Name'           = $maxBlobName
                'Largest Commit'              = Format-Bytes $maxCommitSize
                'Longest Ref (bytes)'         = $maxRefBytes
                'Commit Count'                = $commitCount
                'Uses LFS'                    = $usesLfs
                'Actions Importer Readiness'  = $worstActionsImporterReadiness
                'Blockers Detail'             = ($blockersDetail -join ' | ')
                'Warnings Detail'             = ($warningsDetail -join ' | ')
                'Recommendations'             = ($recommendations -join ' | ')
            })
        }

        $totalRepos++
    }

    $totalBytes += $projectTotalBytes
    $ghRepoLimitOk = -not (@($repos | Where-Object { [long](Get-ObjProp $_ 'size' 0) -ge $GH_REPO_MAX_BYTES }).Count)
    $projBuildCount = (@($repoDetailRows | Where-Object { $_.'Project Name' -eq $projName }) | Measure-Object -Property 'Build Pipeline Count' -Sum)
    $projBuildCountSum = if ($null -ne $projBuildCount.Sum) { [int]$projBuildCount.Sum } else { 0 }
    $projReleaseCount = (@($repoDetailRows | Where-Object { $_.'Project Name' -eq $projName }) | Measure-Object -Property 'Release Pipeline Count' -Sum)
    $projReleaseCountSum = if ($null -ne $projReleaseCount.Sum) { [int]$projReleaseCount.Sum } else { 0 }

    $projectSummary.Add([PSCustomObject]@{
        '#'                     = $projIndex
        'Project Name'          = $projName
        'Description'           = $description
        'Visibility'            = $visibility
        'Process Template'      = $processTemplate
        'Version Control'       = $vcsType
        'State'                 = $state
        'Repository Count'      = $repos.Count
        'Build Pipeline Count'  = $projBuildCountSum
        'Release Pipeline Count'= $projReleaseCountSum
        'Total Size'            = Format-Bytes $projectTotalBytes
        'Total Size (Bytes)'    = $projectTotalBytes
        'GH Repo Limit OK'      = $ghRepoLimitOk
        'TFVC Warning'          = $isTfvc
        'Created Date'          = $lastUpdate
        'ADO Project URL'       = "$script:ADOBaseUrl/$projName"
    })
}

Write-Success "Collected data for $totalRepos repositories across $($allProjects.Count) projects"
if (-not $SkipPipelineInventory) {
    Write-Success "Collected $totalBuildPipelines build pipeline definition(s) and $totalReleasePipelines release pipeline definition(s)"
}

# ============================================================================
# BATCH SUMMARY (for the Migration Batches sheet)
# ============================================================================

$batchGroups = $migrationRows | Group-Object -Property 'Migration Batch' | Sort-Object -Property Name
$batchSummaryRows = New-Object System.Collections.Generic.List[object]
foreach ($grp in $batchGroups) {
    $sizeSum = ($grp.Group | Measure-Object -Property 'Size (Bytes)' -Sum)
    $sizeSumBytes = if ($null -ne $sizeSum.Sum) { [long]$sizeSum.Sum } else { 0 }
    $blockerSum = ($grp.Group | Measure-Object -Property 'Blocker Count' -Sum)
    $blockerSumCount = if ($null -ne $blockerSum.Sum) { [int]$blockerSum.Sum } else { 0 }

    $batchSummaryRows.Add([PSCustomObject]@{
        'Batch'            = $grp.Name
        'Repository Count' = $grp.Count
        'Total Size'       = Format-Bytes $sizeSumBytes
        'Total Blockers'   = $blockerSumCount
        'Sample Repos'     = (($grp.Group | Select-Object -First 5 | ForEach-Object { "$($_.'Project Name')/$($_.'Repository Name')" }) -join ', ')
    })
}

# ============================================================================
# EXCEL WORKBOOK GENERATION
# ============================================================================

Write-Step "Building Excel workbook at $OutputPath"

if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }

$excelPkg = Open-ExcelPackage -Path $OutputPath -Create

# ----------------------------------------------------------------------
# SHEET 1 - LEADERSHIP SUMMARY (showcase page)
# ----------------------------------------------------------------------
$ws1 = $excelPkg.Workbook.Worksheets.Add('Leadership Summary')
$ws1.View.ShowGridLines = $false
$ws1.Cells.Style.Font.Name = 'Calibri'

Write-SheetHeader -ws $ws1 -title "GitHub Enterprise Migration Readiness: $Organisation" -colSpan 8 -bgColor $colNavy

$gitSizerStatusText = if ($RunGitSizer) { 'git-sizer: ENABLED' } else { 'git-sizer: NOT RUN' }
$importerStatusText = if ($CheckActionsImporter) { 'Actions Importer check: ENABLED' } else { 'Actions Importer check: NOT RUN' }
$ws1.Cells[2, 1, 2, 8].Merge = $true
Set-Cell -ws $ws1 -row 2 -col 1 -value "Organisation: $Organisation   |   Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')   |   $gitSizerStatusText   |   $importerStatusText" -bgColor $colAccent -fgColor $colWhite -bold $true -hAlign 'Left'
$ws1.Row(2).Height = 20
$ws1.Row(3).Height = 8

$ws1.Cells[4, 1, 4, 8].Merge = $true
Set-Cell -ws $ws1 -row 4 -col 1 -value 'READINESS AT A GLANCE' -bgColor $colLightBlue -fgColor $colNavy -bold $true -hAlign 'Left'
$ws1.Row(5).Height = 4

$readyCount = @($migrationRows | Where-Object { $_.'GH Migration Status' -eq '[OK] READY' }).Count
$reviewCount = @($migrationRows | Where-Object { $_.'GH Migration Status' -eq '[WARN] NEEDS REVIEW' }).Count
$blockedCount = @($migrationRows | Where-Object { $_.'GH Migration Status' -eq '[BLOCKED] BLOCKED' }).Count
$readyPct = if ($totalRepos -gt 0) { [Math]::Round((($readyCount + $reviewCount) / $totalRepos) * 100, 0) } else { 0 }

$kpis = @(
    @{ Label = 'Total Projects';        Value = "$($allProjects.Count)" },
    @{ Label = 'Total Repositories';    Value = "$totalRepos" },
    @{ Label = 'Total Storage';         Value = (Format-Bytes $totalBytes) },
    @{ Label = 'Migration-Ready Now';   Value = "$readyPct%" }
)

$tileStartCol = 1
foreach ($kpi in $kpis) {
    $endCol = $tileStartCol + 1
    $tileBg = $colLightBlue
    if ($kpi.Label -eq 'Migration-Ready Now') {
        $tileBg = if ($readyPct -ge 75) { $colGreenLight } elseif ($readyPct -ge 40) { $colYellowLight } else { $colRedLight }
    }

    $ws1.Cells[6, $tileStartCol, 6, $endCol].Merge = $true
    Set-Cell -ws $ws1 -row 6 -col $tileStartCol -value $kpi.Label -bgColor $tileBg -fgColor $colNavy -bold $true -hAlign 'Center'
    $ws1.Row(6).Height = 22
    $ws1.Cells[7, $tileStartCol, 7, $endCol].Merge = $true
    Set-Cell -ws $ws1 -row 7 -col $tileStartCol -value '' -bgColor $tileBg
    $ws1.Row(7).Height = 14
    $ws1.Cells[8, $tileStartCol, 8, $endCol].Merge = $true
    Set-Cell -ws $ws1 -row 8 -col $tileStartCol -value $kpi.Value -bgColor $tileBg -fgColor $colNavy -bold $true -fontSize 26 -hAlign 'Center'
    $ws1.Row(8).Height = 38
    $ws1.Cells[9, $tileStartCol, 9, $endCol].Merge = $true
    Set-Cell -ws $ws1 -row 9 -col $tileStartCol -value '' -bgColor $tileBg
    $ws1.Row(9).Height = 14
    $tileStartCol = $endCol + 1
}

$ws1.Row(10).Height = 8
$ws1.Cells[11, 1, 11, 8].Merge = $true
Set-Cell -ws $ws1 -row 11 -col 1 -value 'MIGRATION STATUS BREAKDOWN' -bgColor $colTeal -fgColor $colWhite -bold $true -hAlign 'Left'

$statusBreakdown = @(
    [PSCustomObject]@{ Status = '[OK] Ready to migrate now';        Count = $readyCount;   Color = $colGreenLight }
    [PSCustomObject]@{ Status = '[WARN] Needs review before migrating'; Count = $reviewCount;  Color = $colYellowLight }
    [PSCustomObject]@{ Status = '[BLOCKED] Blocked - remediation required'; Count = $blockedCount; Color = $colRedLight }
)
$row = 12
Write-TableHeaders -ws $ws1 -row $row -headers @('Status', 'Repository Count', '% of Total') -bgColor $colNavy
$row++
foreach ($sb in $statusBreakdown) {
    $pct = if ($totalRepos -gt 0) { [Math]::Round(($sb.Count / $totalRepos) * 100, 0) } else { 0 }
    Set-Cell -ws $ws1 -row $row -col 1 -value $sb.Status -bgColor $sb.Color
    Set-Cell -ws $ws1 -row $row -col 2 -value $sb.Count -hAlign 'Center' -bgColor $sb.Color
    Set-Cell -ws $ws1 -row $row -col 3 -value "$pct%" -hAlign 'Center' -bgColor $sb.Color
    for ($c = 1; $c -le 3; $c++) { Set-Border -ws $ws1 -row $row -col $c }
    $row++
}

$row += 1
$ws1.Cells[$row, 1, $row, 8].Merge = $true
Set-Cell -ws $ws1 -row $row -col 1 -value 'PIPELINE FOOTPRINT' -bgColor $colTeal -fgColor $colWhite -bold $true -hAlign 'Left'
$row++
Write-TableHeaders -ws $ws1 -row $row -headers @('Metric', 'Value') -bgColor $colNavy
$row++
$pipelineMetrics = @(
    @{ M = 'Total Build Pipelines';           V = "$totalBuildPipelines" }
    @{ M = 'Total Classic Release Pipelines';  V = "$totalReleasePipelines" }
    @{ M = 'Repos with 3+ pipelines (complex)'; V = "$(@($repoDetailRows | Where-Object { ($_.'Build Pipeline Count' + $_.'Release Pipeline Count') -ge 3 }).Count)" }
    @{ M = 'Repos with no pipelines detected'; V = "$(@($repoDetailRows | Where-Object { $_.'Build Pipeline Count' -eq 0 -and $_.'Release Pipeline Count' -eq 0 }).Count)" }
)
foreach ($pm in $pipelineMetrics) {
    Set-Cell -ws $ws1 -row $row -col 1 -value $pm.M
    Set-Cell -ws $ws1 -row $row -col 2 -value $pm.V -hAlign 'Center'
    for ($c = 1; $c -le 2; $c++) { Set-Border -ws $ws1 -row $row -col $c }
    $row++
}

$row += 1
$ws1.Cells[$row, 1, $row, 8].Merge = $true
Set-Cell -ws $ws1 -row $row -col 1 -value 'OPEN WORK (COORDINATION RISK)' -bgColor $colTeal -fgColor $colWhite -bold $true -hAlign 'Left'
$row++
Write-TableHeaders -ws $ws1 -row $row -headers @('Metric', 'Value') -bgColor $colNavy
$row++
$totalActivePRs = (@($repoDetailRows) | Measure-Object -Property 'Active PRs' -Sum)
$totalActivePRsSum = if ($null -ne $totalActivePRs.Sum) { [int]$totalActivePRs.Sum } else { 0 }
$reposWithOpenPRs = @($repoDetailRows | Where-Object { [int]$_.'Active PRs' -gt 0 }).Count
$openWorkMetrics = @(
    @{ M = 'Total open pull requests org-wide'; V = "$totalActivePRsSum" }
    @{ M = 'Repos with at least one open PR';   V = "$reposWithOpenPRs" }
)
foreach ($om in $openWorkMetrics) {
    Set-Cell -ws $ws1 -row $row -col 1 -value $om.M
    Set-Cell -ws $ws1 -row $row -col 2 -value $om.V -hAlign 'Center'
    for ($c = 1; $c -le 2; $c++) { Set-Border -ws $ws1 -row $row -col $c }
    $row++
}

$row += 1
$ws1.Cells[$row, 1, $row, 8].Merge = $true
Set-Cell -ws $ws1 -row $row -col 1 -value 'RECOMMENDED MIGRATION BATCHES' -bgColor $colOrange -fgColor $colWhite -bold $true -hAlign 'Left'
$row++
Write-TableHeaders -ws $ws1 -row $row -headers @('Batch', 'Repository Count', 'Total Size', 'Total Blockers') -bgColor $colNavy
$row++
foreach ($b in $batchSummaryRows) {
    Set-Cell -ws $ws1 -row $row -col 1 -value $b.Batch
    Set-Cell -ws $ws1 -row $row -col 2 -value $b.'Repository Count' -hAlign 'Center'
    Set-Cell -ws $ws1 -row $row -col 3 -value $b.'Total Size' -hAlign 'Center'
    Set-Cell -ws $ws1 -row $row -col 4 -value $b.'Total Blockers' -hAlign 'Center'
    for ($c = 1; $c -le 4; $c++) { Set-Border -ws $ws1 -row $row -col $c }
    $row++
}
$row += 1
$ws1.Cells[$row, 1, $row, 8].Merge = $true
Set-Cell -ws $ws1 -row $row -col 1 -value 'See "Migration Batches" and "Migration Planner" sheets for the full repo-level breakdown and sequencing rationale.' -hAlign 'Left'

$ws1.Column(1).Width = 30
for ($c = 2; $c -le 8; $c++) { $ws1.Column($c).Width = 18 }
try { $ws1.TabColor = [System.Drawing.ColorTranslator]::FromHtml("#$colNavy") } catch { }

# ----------------------------------------------------------------------
# SHEET 2 - PROJECT SUMMARY
# ----------------------------------------------------------------------
$ws2 = $excelPkg.Workbook.Worksheets.Add('Project Summary')
$ws2.View.ShowGridLines = $false
try { $ws2.TabColor = [System.Drawing.ColorTranslator]::FromHtml("#$colAccent") } catch { }

$projHeaders = @('#', 'Project Name', 'Description', 'Visibility', 'Process Template', 'Version Control', 'State',
    'Repository Count', 'Build Pipeline Count', 'Release Pipeline Count', 'Total Size', 'Total Size (Bytes)',
    'GH Repo Limit OK', 'TFVC Warning', 'Created Date', 'ADO Project URL')
Write-TableHeaders -ws $ws2 -row 1 -headers $projHeaders -bgColor $colAccent

$r = 3
$grandRepoCount = 0
$grandTotalBytes = [long]0
$idx = 0
foreach ($p in $projectSummary) {
    $idx++
    $rowBg = if ($idx % 2 -eq 0) { $colLightBlue } else { $colWhite }
    $vals = @($p.'#', $p.'Project Name', $p.'Description', $p.'Visibility', $p.'Process Template', $p.'Version Control',
        $p.'State', $p.'Repository Count', $p.'Build Pipeline Count', $p.'Release Pipeline Count', $p.'Total Size',
        $p.'Total Size (Bytes)', $p.'GH Repo Limit OK', $p.'TFVC Warning', $p.'Created Date', $p.'ADO Project URL')
    for ($c = 1; $c -le $vals.Count; $c++) {
        Set-Cell -ws $ws2 -row $r -col $c -value $vals[$c - 1] -bgColor $rowBg
        Set-Border -ws $ws2 -row $r -col $c
    }
    if ([long]$p.'Total Size (Bytes)' -ge $GH_REPO_MAX_BYTES) {
        $ws2.Cells[$r, 11].Style.Font.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml("#$colRed"))
        $ws2.Cells[$r, 11].Style.Font.Bold = $true
    }
    if ($p.'TFVC Warning') {
        $ws2.Cells[$r, 6].Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
        $ws2.Cells[$r, 6].Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml("#$colRedLight"))
    }
    $grandRepoCount += $p.'Repository Count'
    $grandTotalBytes += [long]$p.'Total Size (Bytes)'
    $r++
}

Set-Cell -ws $ws2 -row $r -col 1 -value 'TOTAL' -bold $true -bgColor $colNavy -fgColor $colWhite
Set-Cell -ws $ws2 -row $r -col 8 -value $grandRepoCount -bold $true -bgColor $colNavy -fgColor $colWhite
Set-Cell -ws $ws2 -row $r -col 11 -value (Format-Bytes $grandTotalBytes) -bold $true -bgColor $colNavy -fgColor $colWhite
Set-Cell -ws $ws2 -row $r -col 12 -value $grandTotalBytes -bold $true -bgColor $colNavy -fgColor $colWhite

$ws2.View.FreezePanes(3, 1)
$widths2 = @(5, 32, 36, 14, 20, 16, 12, 16, 16, 16, 16, 18, 16, 14, 14, 45)
for ($c = 1; $c -le $widths2.Count; $c++) { $ws2.Column($c).Width = $widths2[$c - 1] }

# ----------------------------------------------------------------------
# SHEET 3 - REPOSITORY DETAIL
# ----------------------------------------------------------------------
$ws3 = $excelPkg.Workbook.Worksheets.Add('Repository Detail')
$ws3.View.ShowGridLines = $false
try { $ws3.TabColor = [System.Drawing.ColorTranslator]::FromHtml("#$colGreen") } catch { }

$repoHeaders = @('Project Name', 'Rank in Project', 'Repository Name', 'Default Branch', 'Size', 'Size (Bytes)',
    'Size Category', 'Last Commit Date', 'Build Pipeline Count', 'Release Pipeline Count', 'Last Pipeline Run',
    'Last Used', 'Activity Status', 'Active PRs', 'Oldest Active PR (days)', 'Is Disabled', 'Is Fork', 'GH Migration Status', 'Blockers', 'Warnings',
    'Actions Importer Readiness', 'Remote URL (HTTPS)', 'SSH URL', 'Repository ID')
Write-TableHeaders -ws $ws3 -row 1 -headers $repoHeaders -bgColor $colGreen

$r = 3
$reposByProject = $repoDetailRows | Group-Object -Property 'Project Name'
foreach ($grp in $reposByProject) {
    $ws3.Cells[$r, 1, $r, $repoHeaders.Count].Merge = $true
    Set-Cell -ws $ws3 -row $r -col 1 -value "$($grp.Name)  ($($grp.Count) repositories)" -bgColor $colAccent -fgColor $colWhite -bold $true -hAlign 'Left'
    $r++
    foreach ($repo in $grp.Group) {
        $vals = @($repo.'Project Name', $repo.'Rank in Project', $repo.'Repository Name', $repo.'Default Branch',
            $repo.'Size', $repo.'Size (Bytes)', $repo.'Size Category', $repo.'Last Commit Date', $repo.'Build Pipeline Count',
            $repo.'Release Pipeline Count', $repo.'Last Pipeline Run', $repo.'Last Used', $repo.'Activity Status',
            $repo.'Active PRs', $repo.'Oldest Active PR (days)', $repo.'Is Disabled', $repo.'Is Fork', $repo.'GH Migration Status',
            $repo.'Blockers', $repo.'Warnings', $repo.'Actions Importer Readiness', $repo.'Remote URL (HTTPS)', $repo.'SSH URL', $repo.'Repository ID')
        for ($c = 1; $c -le $vals.Count; $c++) {
            Set-Cell -ws $ws3 -row $r -col $c -value $vals[$c - 1] -wrapText $true
            Set-Border -ws $ws3 -row $r -col $c
        }

        $sizeCatText = $repo.'Size Category'
        if ($sizeCatText -match 'Large') { $sizeCatColor = 'FFC7CE' }
        elseif ($sizeCatText -match 'Medium') { $sizeCatColor = 'FFEB9C' }
        elseif ($sizeCatText -match 'Small') { $sizeCatColor = 'FFFF99' }
        else { $sizeCatColor = 'C6EFCE' }
        $ws3.Cells[$r, 7].Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
        $ws3.Cells[$r, 7].Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml("#$sizeCatColor"))

        $ghStatusText = $repo.'GH Migration Status'
        if ($ghStatusText -match 'BLOCKED') { $ghStatusColor = 'FFC7CE' }
        elseif ($ghStatusText -match 'NEEDS REVIEW') { $ghStatusColor = 'FFEB9C' }
        else { $ghStatusColor = 'C6EFCE' }
        $ws3.Cells[$r, 18].Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
        $ws3.Cells[$r, 18].Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml("#$ghStatusColor"))

        $activityText = $repo.'Activity Status'
        if ($activityText -match 'STALE') { $activityColor = 'FCE4D6' }
        elseif ($activityText -match 'DORMANT') { $activityColor = 'FFEB9C' }
        elseif ($activityText -match 'ACTIVE') { $activityColor = 'E2EFDA' }
        else { $activityColor = $null }
        if ($activityColor) {
            $ws3.Cells[$r, 13].Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
            $ws3.Cells[$r, 13].Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml("#$activityColor"))
        }

        if ([int]$repo.'Active PRs' -gt 0) {
            $ws3.Cells[$r, 14].Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
            $ws3.Cells[$r, 14].Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml("#$colYellowLight"))
            $ws3.Cells[$r, 14].Style.Font.Bold = $true
        }

        $r++
    }
}

$ws3.View.FreezePanes(3, 1)
$widths3 = @(24, 8, 28, 14, 12, 14, 20, 14, 12, 12, 14, 12, 22, 10, 12, 10, 8, 18, 10, 10, 46, 42, 42, 34)
for ($c = 1; $c -le $widths3.Count; $c++) { $ws3.Column($c).Width = $widths3[$c - 1] }

# ----------------------------------------------------------------------
# SHEET 4 - PIPELINE INVENTORY
# ----------------------------------------------------------------------
$ws4 = $excelPkg.Workbook.Worksheets.Add('Pipeline Inventory')
$ws4.View.ShowGridLines = $false
try { $ws4.TabColor = [System.Drawing.ColorTranslator]::FromHtml("#$colPurple") } catch { }

$pipeHeaders = @('Project Name', 'Repository Name', 'Pipeline Name', 'Pipeline Type', 'Definition Type',
    'Last Run Date', 'Last Run Result', 'Enabled', 'Actions Importer Readiness', 'Notes')

$ws4.Cells[1, 1, 1, $pipeHeaders.Count].Merge = $true
Set-Cell -ws $ws4 -row 1 -col 1 -value 'Pipeline Inventory - Build and Release Pipelines' -bgColor $colPurple -fgColor $colWhite -bold $true -fontSize 14 -hAlign 'Left'
$ws4.Cells[2, 1, 2, $pipeHeaders.Count].Merge = $true
$importerNote = if ($CheckActionsImporter) { 'Actions Importer Readiness is a heuristic scan of YAML task names unless the gh actions-importer CLI was detected; see README.md section 8.' } else { 'Run with -CheckActionsImporter to populate Actions Importer readiness for YAML build pipelines.' }
Set-Cell -ws $ws4 -row 2 -col 1 -value $importerNote -bgColor $colYellow -hAlign 'Left'

Write-TableHeaders -ws $ws4 -row 3 -headers $pipeHeaders -bgColor $colPurple

$r = 4
if ($pipelineRows.Count -eq 0) {
    $ws4.Cells[$r, 1, $r, $pipeHeaders.Count].Merge = $true
    $msg = if ($SkipPipelineInventory) { 'Pipeline inventory was skipped (-SkipPipelineInventory).' } else { 'No build or release pipelines were found.' }
    Set-Cell -ws $ws4 -row $r -col 1 -value $msg -bgColor $colYellowLight -bold $true -hAlign 'Center'
    $r++
}
else {
    $sortedPipelines = @($pipelineRows | Sort-Object -Property 'Project Name', 'Repository Name', 'Pipeline Type')
    foreach ($p in $sortedPipelines) {
        $bgColor = $colWhite
        if ($p.'Actions Importer Readiness' -match 'Needs Manual Review|Manual -') { $bgColor = $colYellowLight }
        elseif ($p.'Actions Importer Readiness' -match 'Likely Automatable') { $bgColor = $colGreenLight }

        $vals = @($p.'Project Name', $p.'Repository Name', $p.'Pipeline Name', $p.'Pipeline Type', $p.'Definition Type',
            $p.'Last Run Date', $p.'Last Run Result', $p.'Enabled', $p.'Actions Importer Readiness', $p.'Notes')
        for ($c = 1; $c -le $vals.Count; $c++) {
            Set-Cell -ws $ws4 -row $r -col $c -value $vals[$c - 1] -bgColor $bgColor -wrapText $true
            Set-Border -ws $ws4 -row $r -col $c
        }
        $r++
    }
}

$ws4.View.FreezePanes(4, 1)
$widths4 = @(24, 28, 34, 18, 20, 16, 16, 10, 50, 40)
for ($c = 1; $c -le $widths4.Count; $c++) { $ws4.Column($c).Width = $widths4[$c - 1] }

# ----------------------------------------------------------------------
# SHEET 5 - GITHUB COMPATIBILITY
# ----------------------------------------------------------------------
$ws5 = $excelPkg.Workbook.Worksheets.Add('GitHub Compatibility')
$ws5.View.ShowGridLines = $false
try { $ws5.TabColor = [System.Drawing.ColorTranslator]::FromHtml("#$colRed") } catch { }

$compatHeaders = @('Project Name', 'Repository Name', 'Repo Size', 'GH Migration Status', 'Blocker Count', 'Warning Count',
    'git-sizer Run', 'Total Blob Size', 'Largest File', 'Largest File Name', 'Largest Commit', 'Longest Ref (bytes)',
    'Commit Count', 'Uses LFS', 'Actions Importer Readiness', 'Blockers Detail', 'Warnings Detail', 'Recommendations')

$ws5.Cells[1, 1, 1, $compatHeaders.Count].Merge = $true
Set-Cell -ws $ws5 -row 1 -col 1 -value 'GitHub Compatibility - Migration Blockers and Warnings' -bgColor $colRed -fgColor $colWhite -bold $true -fontSize 14 -hAlign 'Left'
$ws5.Cells[2, 1, 2, $compatHeaders.Count].Merge = $true
Set-Cell -ws $ws5 -row 2 -col 1 -value 'Sorted by Blocker Count (descending). Review every BLOCKED repo before migrating with GEI.' -bgColor $colYellow -hAlign 'Left'

Write-TableHeaders -ws $ws5 -row 3 -headers @('Limit', 'Threshold', 'Scope', 'Impact', 'Notes') -bgColor $colNavy
Set-Cell -ws $ws5 -row 4 -col 1 -value 'Repo size / File size / Commit size / Ref length / VCS type / Release pipelines'
Set-Cell -ws $ws5 -row 4 -col 2 -value '40GB / 400MB / 2GB / 255 bytes / Git only / n-a'
Set-Cell -ws $ws5 -row 4 -col 3 -value 'See Leadership Summary for the full reference table'
Set-Cell -ws $ws5 -row 4 -col 4 -value 'BLOCKER or WARNING per row below'
Set-Cell -ws $ws5 -row 4 -col 5 -value ''
for ($c = 1; $c -le 5; $c++) { Set-Border -ws $ws5 -row 4 -col $c }
$ws5.Row(5).Height = 6
Write-TableHeaders -ws $ws5 -row 6 -headers $compatHeaders -bgColor $colRed

$r = 7
if ($compatibilityRows.Count -eq 0) {
    $ws5.Cells[$r, 1, $r, $compatHeaders.Count].Merge = $true
    Set-Cell -ws $ws5 -row $r -col 1 -value 'No GitHub Enterprise Importer compatibility issues found.' -bgColor $colGreenLight -bold $true -hAlign 'Center'
    $r++
}
else {
    $sortedCompat = @($compatibilityRows | Sort-Object -Property @{Expression = 'Blocker Count'; Descending = $true}, 'Project Name', 'Repository Name')
    foreach ($row in $sortedCompat) {
        $bgColor = $colGreenLight
        if ($row.'Blocker Count' -gt 0) { $bgColor = $colRedLight }
        elseif ($row.'Warning Count' -gt 0) { $bgColor = $colYellowLight }

        $vals = @($row.'Project Name', $row.'Repository Name', $row.'Repo Size', $row.'GH Migration Status', $row.'Blocker Count',
            $row.'Warning Count', $row.'git-sizer Run', $row.'Total Blob Size', $row.'Largest File', $row.'Largest File Name',
            $row.'Largest Commit', $row.'Longest Ref (bytes)', $row.'Commit Count', $row.'Uses LFS', $row.'Actions Importer Readiness',
            $row.'Blockers Detail', $row.'Warnings Detail', $row.'Recommendations')
        for ($c = 1; $c -le $vals.Count; $c++) {
            Set-Cell -ws $ws5 -row $r -col $c -value $vals[$c - 1] -bgColor $bgColor -wrapText $true
            Set-Border -ws $ws5 -row $r -col $c
        }
        if ($row.'Blocker Count' -gt 0) {
            $ws5.Cells[$r, 5].Style.Font.Bold = $true
            $ws5.Cells[$r, 5].Style.Font.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml("#$colRed"))
        }
        $r++
    }
}

$ws5.View.FreezePanes(7, 1)
$widths5 = @(24, 28, 14, 20, 14, 14, 16, 16, 16, 36, 16, 18, 14, 12, 46, 50, 50, 60)
for ($c = 1; $c -le $widths5.Count; $c++) { $ws5.Column($c).Width = $widths5[$c - 1] }

# ----------------------------------------------------------------------
# SHEET 6 - MIGRATION PLANNER
# ----------------------------------------------------------------------
$ws6 = $excelPkg.Workbook.Worksheets.Add('Migration Planner')
$ws6.View.ShowGridLines = $false
try { $ws6.TabColor = [System.Drawing.ColorTranslator]::FromHtml("#$colOrange") } catch { }

$migHeaders = @('Project Name', 'Repository Name', 'Size', 'Size (Bytes)', 'Size Category', 'GH Migration Status',
    'Blocker Count', 'Warning Count', 'Build Pipelines', 'Release Pipelines', 'Last Used', 'Activity Status', 'Active PRs', 'Is Fork',
    'Migration Priority', 'Estimated Effort', 'Migration Batch', 'Migration Status', 'Assigned To', 'Notes', 'Remote URL (HTTPS)')

$ws6.Cells[1, 1, 1, $migHeaders.Count].Merge = $true
Set-Cell -ws $ws6 -row 1 -col 1 -value 'Migration Planner - Batch Tracking Sheet' -bgColor $colOrange -fgColor $colWhite -bold $true -fontSize 14 -hAlign 'Left'
$ws6.Cells[2, 1, 2, $migHeaders.Count].Merge = $true
Set-Cell -ws $ws6 -row 2 -col 1 -value 'Use Migration Status / Assigned To / Notes to track progress. Sorted by Migration Batch, then Blocker Count, then Size. Repos with open PRs need a coordinated freeze/cutover window.' -bgColor $colYellow -hAlign 'Left'

Write-TableHeaders -ws $ws6 -row 3 -headers $migHeaders -bgColor $colOrange

$r = 4
$sortedMig = @($migrationRows | Sort-Object -Property 'Migration Batch', @{Expression = 'Blocker Count'; Descending = $true}, @{Expression = 'Size (Bytes)'; Descending = $true})
$migByProject = $sortedMig | Group-Object -Property 'Project Name'
foreach ($grp in $migByProject) {
    $ws6.Cells[$r, 1, $r, $migHeaders.Count].Merge = $true
    Set-Cell -ws $ws6 -row $r -col 1 -value $grp.Name -bgColor $colAccent -fgColor $colWhite -bold $true -hAlign 'Left'
    $r++
    foreach ($row in $grp.Group) {
        $bgColor = $colWhite
        if ($row.'Blocker Count' -gt 0) { $bgColor = $colRedLight }
        elseif ($row.'Warning Count' -gt 0) { $bgColor = $colYellowLight }

        $vals = @($row.'Project Name', $row.'Repository Name', $row.'Size', $row.'Size (Bytes)', $row.'Size Category',
            $row.'GH Migration Status', $row.'Blocker Count', $row.'Warning Count', $row.'Build Pipelines', $row.'Release Pipelines',
            $row.'Last Used', $row.'Activity Status', $row.'Active PRs', $row.'Is Fork', $row.'Migration Priority', $row.'Estimated Effort',
            $row.'Migration Batch', $row.'Migration Status', $row.'Assigned To', $row.'Notes', $row.'Remote URL (HTTPS)')
        for ($c = 1; $c -le $vals.Count; $c++) {
            Set-Cell -ws $ws6 -row $r -col $c -value $vals[$c - 1] -bgColor $bgColor
            Set-Border -ws $ws6 -row $r -col $c
        }
        if ([int]$row.'Active PRs' -gt 0) {
            $ws6.Cells[$r, 13].Style.Font.Bold = $true
            $ws6.Cells[$r, 13].Style.Font.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml("#$colOrange"))
        }
        $r++
    }
}

$ws6.View.FreezePanes(4, 1)
$widths6 = @(24, 28, 12, 14, 20, 20, 12, 12, 12, 12, 14, 22, 10, 8, 24, 24, 30, 16, 16, 36, 42)
for ($c = 1; $c -le $widths6.Count; $c++) { $ws6.Column($c).Width = $widths6[$c - 1] }

# ----------------------------------------------------------------------
# SHEET 7 - MIGRATION BATCHES
# ----------------------------------------------------------------------
$ws7 = $excelPkg.Workbook.Worksheets.Add('Migration Batches')
$ws7.View.ShowGridLines = $false
try { $ws7.TabColor = [System.Drawing.ColorTranslator]::FromHtml("#$colTeal") } catch { }

$ws7.Cells[1, 1, 1, 5].Merge = $true
Set-Cell -ws $ws7 -row 1 -col 1 -value 'Recommended Migration Batches' -bgColor $colTeal -fgColor $colWhite -bold $true -fontSize 14 -hAlign 'Left'
$ws7.Cells[2, 1, 2, 5].Merge = $true
Set-Cell -ws $ws7 -row 2 -col 1 -value 'Batches are a starting recommendation based on blockers, size, pipeline complexity, and recent activity. Adjust in the Migration Planner sheet as needed.' -bgColor $colYellow -hAlign 'Left'

$batchExplain = @(
    'Batch 0 - Remediate First: has one or more GEI blockers; must be fixed before it can be migrated.'
    'Batch 1 - Pilot: low risk, low activity, single pipeline, under 1 GB - good candidates for a first test wave.'
    'Batch 2 - Standard: no blockers, simple pipeline footprint - standard migration wave.'
    'Batch 3 - Complex: has release pipelines, 3+ pipelines, or open warnings - needs coordinated pipeline cutover.'
    'Batch 4 - Forks: confirm ownership/need before migrating.'
)
$row = 4
foreach ($line in $batchExplain) {
    $ws7.Cells[$row, 1, $row, 5].Merge = $true
    Set-Cell -ws $ws7 -row $row -col 1 -value $line -hAlign 'Left'
    $row++
}
$row += 1

Write-TableHeaders -ws $ws7 -row $row -headers @('Batch', 'Repository Count', 'Total Size', 'Total Blockers', 'Sample Repos (first 5)') -bgColor $colTeal
$row++
foreach ($b in $batchSummaryRows) {
    Set-Cell -ws $ws7 -row $row -col 1 -value $b.Batch
    Set-Cell -ws $ws7 -row $row -col 2 -value $b.'Repository Count' -hAlign 'Center'
    Set-Cell -ws $ws7 -row $row -col 3 -value $b.'Total Size' -hAlign 'Center'
    Set-Cell -ws $ws7 -row $row -col 4 -value $b.'Total Blockers' -hAlign 'Center'
    Set-Cell -ws $ws7 -row $row -col 5 -value $b.'Sample Repos' -wrapText $true
    for ($c = 1; $c -le 5; $c++) { Set-Border -ws $ws7 -row $row -col $c }
    $row++
}

$row += 2
Write-TableHeaders -ws $ws7 -row $row -headers @('Batch', 'Project Name', 'Repository Name', 'Size', 'Blocker Count', 'Active PRs', 'Activity Status') -bgColor $colNavy
$row++
foreach ($m in $sortedMig) {
    Set-Cell -ws $ws7 -row $row -col 1 -value $m.'Migration Batch'
    Set-Cell -ws $ws7 -row $row -col 2 -value $m.'Project Name'
    Set-Cell -ws $ws7 -row $row -col 3 -value $m.'Repository Name'
    Set-Cell -ws $ws7 -row $row -col 4 -value $m.'Size'
    Set-Cell -ws $ws7 -row $row -col 5 -value $m.'Blocker Count' -hAlign 'Center'
    Set-Cell -ws $ws7 -row $row -col 6 -value $m.'Active PRs' -hAlign 'Center'
    Set-Cell -ws $ws7 -row $row -col 7 -value $m.'Activity Status'
    for ($c = 1; $c -le 7; $c++) { Set-Border -ws $ws7 -row $row -col $c }
    $row++
}

$widths7 = @(30, 24, 28, 14, 14, 12, 24)
for ($c = 1; $c -le $widths7.Count; $c++) { $ws7.Column($c).Width = $widths7[$c - 1] }

# ----------------------------------------------------------------------
# SHEET 8 - RAW DATA
# ----------------------------------------------------------------------
$ws8 = $excelPkg.Workbook.Worksheets.Add('Raw Data')
try { $ws8.TabColor = [System.Drawing.ColorTranslator]::FromHtml("#$colGrey") } catch { }

$rawHeaders = @('Project Name', 'Repository Name', 'Size (Bytes)', 'Size Category', 'GH Migration Status',
    'Blocker Count', 'Warning Count', 'Build Pipeline Count', 'Release Pipeline Count', 'Active PRs', 'Oldest Active PR (days)',
    'Last Used', 'Activity Status', 'Is Disabled', 'Is Fork', 'Default Branch', 'Last Commit Date', 'Remote URL (HTTPS)', 'SSH URL', 'Repository ID')
for ($c = 1; $c -le $rawHeaders.Count; $c++) { Set-Cell -ws $ws8 -row 1 -col $c -value $rawHeaders[$c - 1] -bold $true }

$r = 2
$migLookup = @{}
foreach ($m in $migrationRows) { $migLookup["$($m.'Project Name')|$($m.'Repository Name')"] = $m }

foreach ($repo in $repoDetailRows) {
    $key = "$($repo.'Project Name')|$($repo.'Repository Name')"
    $migMatch = $migLookup[$key]
    $blockerCount = if ($migMatch) { $migMatch.'Blocker Count' } else { 0 }
    $warningCount = if ($migMatch) { $migMatch.'Warning Count' } else { 0 }

    $vals = @($repo.'Project Name', $repo.'Repository Name', $repo.'Size (Bytes)', $repo.'Size Category', $repo.'GH Migration Status',
        $blockerCount, $warningCount, $repo.'Build Pipeline Count', $repo.'Release Pipeline Count', $repo.'Active PRs',
        $repo.'Oldest Active PR (days)', $repo.'Last Used', $repo.'Activity Status', $repo.'Is Disabled', $repo.'Is Fork',
        $repo.'Default Branch', $repo.'Last Commit Date', $repo.'Remote URL (HTTPS)', $repo.'SSH URL', $repo.'Repository ID')
    for ($c = 1; $c -le $vals.Count; $c++) { Set-Cell -ws $ws8 -row $r -col $c -value $vals[$c - 1] }
    $r++
}
for ($c = 1; $c -le $rawHeaders.Count; $c++) { $ws8.Column($c).AutoFit() }

Close-ExcelPackage $excelPkg
Write-Success "Excel workbook saved: $OutputPath"

# ============================================================================
# JSON EXPORT
# ============================================================================

$jsonPath = [System.IO.Path]::ChangeExtension($OutputPath, '.json')
Write-Step "Writing JSON sidecar to $jsonPath"

$jsonObject = [PSCustomObject]@{
    Organisation             = $Organisation
    GeneratedAt              = (Get-Date).ToString('o')
    GitSizerAnalysis         = [bool]$RunGitSizer
    ActionsImporterChecked   = [bool]$CheckActionsImporter
    PipelineInventoryRun     = -not $SkipPipelineInventory
    TotalProjects            = $allProjects.Count
    TotalRepos               = $totalRepos
    TotalBytes               = $totalBytes
    TotalSizeFormatted       = Format-Bytes $totalBytes
    TotalMigrationBlockers   = $totalMigrationBlockers
    TotalMigrationWarnings   = $totalMigrationWarnings
    TotalBuildPipelines      = $totalBuildPipelines
    TotalReleasePipelines    = $totalReleasePipelines
    TotalActivePullRequests  = $totalActivePRsSum
    ReposWithOpenPullRequests= $reposWithOpenPRs
    MigrationReadyPercent    = $readyPct
    Projects                 = $projectSummary
    Repositories             = $repoDetailRows
    Pipelines                = $pipelineRows
    CompatibilityIssues      = $compatibilityRows
    MigrationBatches         = $batchSummaryRows
}

$jsonObject | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding utf8
Write-Success "JSON sidecar saved: $jsonPath"

# ============================================================================
# CONSOLE SUMMARY
# ============================================================================

Write-Host ''
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host " ADO INVENTORY SUMMARY - $Organisation" -ForegroundColor Cyan
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host "Projects:            $($allProjects.Count)"
Write-Host "Repositories:        $totalRepos"
Write-Host "Total Storage:       $(Format-Bytes $totalBytes)"
Write-Host "Build Pipelines:     $totalBuildPipelines"
Write-Host "Release Pipelines:   $totalReleasePipelines"
Write-Host "Open Pull Requests:  $totalActivePRsSum (across $reposWithOpenPRs repo(s))"
Write-Host "Migration Ready:     $readyPct% ($readyCount ready, $reviewCount need review)"

if ($totalMigrationBlockers -gt 0) { Write-Host "Migration Blockers:  $totalMigrationBlockers" -ForegroundColor Red }
else { Write-Host "Migration Blockers:  0" -ForegroundColor Green }

if ($totalMigrationWarnings -gt 0) { Write-Host "Migration Warnings:  $totalMigrationWarnings" -ForegroundColor Yellow }
else { Write-Host "Migration Warnings:  0" -ForegroundColor Green }

if ($RunGitSizer) { Write-Host 'git-sizer Analysis:  Enabled' } else { Write-Host 'git-sizer Analysis:  Not run - re-run with -RunGitSizer for full compatibility data' }
if ($CheckActionsImporter) { Write-Host 'Actions Importer:    Checked' } else { Write-Host 'Actions Importer:    Not checked - re-run with -CheckActionsImporter for pipeline readiness data' }

Write-Host "Output file:         $OutputPath"
Write-Host "JSON sidecar:        $jsonPath"
Write-Host '=========================================================' -ForegroundColor Cyan

if ($totalMigrationBlockers -gt 0) {
    Write-Fail "$totalMigrationBlockers migration blocker(s) found - review the 'GitHub Compatibility' sheet before migrating"
}
if (-not $RunGitSizer) { Write-Warn 'Re-run with -RunGitSizer for deep per-repo blob/commit/ref analysis (git-sizer)' }
if (-not $CheckActionsImporter) { Write-Warn 'Re-run with -CheckActionsImporter for GitHub Actions Importer readiness data on YAML pipelines' }

# ============================================================================
# CLEANUP
# ============================================================================

if ($RunGitSizer -and -not $KeepClones) {
    try {
        if ((Test-Path $GitSizerWorkDir) -and (@(Get-ChildItem -Path $GitSizerWorkDir -Force -ErrorAction SilentlyContinue)).Count -eq 0) {
            Remove-Item -LiteralPath $GitSizerWorkDir -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
}
