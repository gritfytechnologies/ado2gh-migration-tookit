# adogap

**A**zure **D**ev**O**ps release-pipeline **gap**-filler. Companion to
`gh actions-importer` and your `Invoke-GHActionsImporterMigration.ps1`.

## Why this exists

`gh actions-importer azure-devops release` already converts the mechanical
shape of a classic release pipeline — stages, jobs, tasks — into GitHub
Actions YAML. What it does **not** do, and explicitly documents as manual
follow-up in every PR it opens, is:

- Recreate **approvals** as GitHub Environment required reviewers
- Recreate **deployment gates** (no direct equivalent exists in Actions)
- Set up **service connection** replacements (OIDC federated credentials)
- Migrate **variable group secret values**

The importer's own audit report will call a pipeline "Successful" even when
every approval on a production environment got silently dropped — because
structurally, the conversion did succeed; it just didn't carry over
constructs it was never designed to carry over. That's a dangerous gap to
miss in a fintech/payments environment where those approvals exist for
compliance reasons, not convenience.

`adogap` closes that gap in three steps, and makes the gap **impossible to
miss** by verifying it explicitly rather than hoping someone reads the PR
description carefully:

1. **extract** — parses the source ADO release definition (live API pull or
   local JSON) and pulls out every approval, gate, service connection, and
   variable group reference, per stage.
2. **scaffold** — generates ready-to-review artifacts: GitHub Environment
   config, an `gh api`-based apply script, OIDC federated credential
   templates for Azure, a reviewer identity-mapping CSV, and gates/secrets
   checklists.
3. **verify** — diffs the extraction against the actual converted workflow
   YAML and fails loudly (not a warning buried in a report) if approvals or
   gates were dropped, or if service-connection auth wasn't addressed.

`adogap` is **read-only against Azure DevOps** and **never writes directly to
GitHub** — every scaffolded artifact is generated to disk for a human to
review, fill in, and apply deliberately. It does not call the Azure or
GitHub write APIs itself.

---

## Installation

Requires Python 3.11+.

```bash
git clone <this-repo>  # or unzip the delivered archive
cd adogap
python3 -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\Activate.ps1
pip install -e .
adogap --version
```

Or without installing as a package:

```bash
pip install -r requirements.txt
python -m adogap --help
```

## Configuration

```bash
cp .env.example .env
# edit .env with real values
```

Required for any command that pulls live from Azure DevOps (`--release-id`
instead of `--source-file`):

| Variable | Purpose |
|---|---|
| `ADO_ORGANIZATION` | Azure DevOps org name |
| `ADO_PROJECT` | Azure DevOps project name |
| `ADO_PAT` | PAT with `Release: Read` scope (read-only is sufficient) |
| `ADO_INSTANCE_URL` | Default `https://dev.azure.com` |
| `GITHUB_ORG` | Used to populate OIDC subject claims in scaffolded credentials |

Tuning (all optional, sensible defaults):

| Variable | Default | Purpose |
|---|---|---|
| `ADOGAP_MAX_RETRIES` | 5 | Retry attempts on transient/rate-limit failures |
| `ADOGAP_INITIAL_BACKOFF_SECONDS` | 10 | Base for exponential backoff |
| `ADOGAP_MAX_CONCURRENCY` | 3 | Parallel workers in `batch` mode |
| `ADOGAP_MIN_REQUEST_INTERVAL_SECONDS` | 1.0 | Floor spacing between ADO API calls |

If you already ran `gh actions-importer audit`, you have local JSON exports
of your pipelines — pass those via `--source-file` instead of hitting the
ADO API again; no credentials needed for that path.

---

## Commands

### `adogap extract`

Pulls out approvals/gates/service connections/variable groups and writes
`extracted.json` plus a summary table.

```bash
adogap extract --release-id 17 --output-dir ./out
adogap extract --source-file ./audit/release-17.json --output-dir ./out
```

### `adogap scaffold`

Generates the environment config, apply script, OIDC templates, and
checklists.

```bash
adogap scaffold --release-id 17 \
  --github-org acme-org --repo-name payments-api \
  --output-dir ./out
```

Produces, under `<output-dir>/<pipeline-name>/scaffold/`:

| File | Purpose |
|---|---|
| `environments.json` | Structured environment definitions (reviewers, gate counts, service connections, variable groups) |
| `create-environments.sh` | `gh api` script that creates each GitHub Environment with reviewers — **refuses to run until `reviewer-mapping.csv` is fully filled in** |
| `reviewer-mapping.csv` | ADO identity -> GitHub username, blank for you to fill (no safe automated way to resolve this) |
| `oidc-federated-credentials.json` | One entry per service connection, with the `repo:{org}/{repo}:environment:{name}` subject claim pre-built, plus an `az ad app federated-credential create` command template |
| `gates-checklist.md` | Every deployment gate found, with a suggested GitHub-native redesign pattern per gate type |
| `secrets-checklist.md` | Every variable group referenced — values are **never** read or exported by this tool; re-enter them manually |

### `adogap verify`

Diffs the extraction against a converted workflow file and reports PASS /
WARN / FAIL per construct.

```bash
adogap verify --release-id 17 --workflow-file ./workflow-output/release.yml --output-dir ./out
```

Exit code `1` on FAIL (or on WARN too, with `--fail-on-warn`) — wire this
into CI to block a migration from being marked "done" until the gaps are
addressed.

### `adogap run-all`

Runs all three steps for a single release pipeline in one pass.

```bash
adogap run-all --release-id 17 \
  --github-org acme-org --repo-name payments-api \
  --workflow-file ./workflow-output/release.yml \
  --output-dir ./out
```

### `adogap batch`

Runs extract + scaffold (+ verify, if workflow files are found) across every
release pipeline in an inventory file — same schema as
`Get-ADOInventory.ps1` / `Invoke-GHActionsImporterMigration.ps1`
(`Repositories[].ReleasePipelineIds`).

```bash
adogap batch \
  --inventory ./ado-inventory.json \
  --github-org acme-org \
  --workflow-search-root ./ghai-output/artifacts \
  --output-dir ./adogap-output
```

`--workflow-search-root` expects the same layout your PowerShell migration
script already produces: `<root>/<repo>/Release-<id>/*.yml`. Point it at
that script's `artifacts/` directory and `batch` will automatically find and
verify against the matching converted workflow for each pipeline — no manual
wiring between the two tools.

Writes a `batch-summary-<runid>.json` with per-pipeline status, and exits
non-zero if anything errored or failed verification (CI-friendly).

---

## Rate limiting & reliability

Same defense-in-depth pattern as the PowerShell migration script:

1. **Floor spacing** (`RateLimiter`) — thread-safe minimum interval between
   any two ADO API calls, enforced across all `batch` workers regardless of
   concurrency.
2. **Retry-After honored** — if ADO/GitHub returns a `Retry-After` header,
   that value is used directly instead of computed backoff.
3. **Exponential backoff with full jitter**, capped at 5 minutes, on 429/403/503
   responses and on known throttling text signatures (`TF400733`, "rate
   limit", "secondary rate limit", "abuse detection") that don't come back
   as a clean HTTP status.
4. **Per-item isolation in `batch`** — one pipeline's failure (rate limit
   exhaustion, malformed definition, network error) is logged and recorded
   as `ERROR` in the summary; it does not stop the rest of the batch.

## Logging & output layout

```
<output-dir>/
  logs/
    adogap-<runid>.log         # human-readable
    adogap-<runid>.jsonl       # structured, one JSON object per line
  <pipeline-name>/
    extracted.json
    SUMMARY.md                 # links every artifact + verification result
    scaffold/
      environments.json
      create-environments.sh
      reviewer-mapping.csv
      oidc-federated-credentials.json
      gates-checklist.md
      secrets-checklist.md
  batch-summary-<runid>.json   # only in batch mode
```

## Recommended workflow, end to end

```bash
# 1. Convert the mechanical structure
gh actions-importer dry-run azure-devops release --pipeline-id 17 --output-dir ./gha-out

# 2. Fill the gap the importer left
adogap run-all --release-id 17 --github-org acme-org --repo-name payments-api \
  --workflow-file ./gha-out/workflows/release.yml --output-dir ./adogap-out

# 3. Review adogap-out/payments-api-release/SUMMARY.md — this is your single
#    "is this pipeline actually done" checkpoint, not just the importer's PR.

# 4. Fill in reviewer-mapping.csv, then:
./adogap-out/payments-api-release/scaffold/create-environments.sh acme-org/payments-api

# 5. Apply OIDC federated credentials via the Azure CLI commands in
#    oidc-federated-credentials.json

# 6. Re-run gh actions-importer migrate to open the PR, then re-run
#    adogap verify against the merged workflow to confirm PASS.
```

## Testing this toolkit yourself

`fixtures/` (if included in your delivery) has a synthetic ADO release
definition with two stages (Staging, Production), approvals on both,
a gate on each, and a service connection each — plus a matching converted
workflow with the Production Azure auth step deliberately omitted, so you
can see `adogap verify` catch it:

```bash
adogap run-all --source-file fixtures/sample-release-definition.json \
  --github-org acme-org --repo-name payments-api \
  --workflow-file fixtures/sample-converted-workflow.yml \
  --output-dir /tmp/adogap-test
```

## Known limitations

- **Service connection name/type resolution**: the extractor identifies
  *which* service connection ID is referenced per stage, but resolving its
  friendly name/type requires an additional `_apis/serviceendpoint/endpoints`
  call this version doesn't wire in automatically (the `AdoClient` has the
  method — `get_service_connection()` — it's just not called from
  `extract()` yet). Easy follow-up if you want names in the OIDC templates
  instead of raw GUIDs.
- **Wait timer vs. approval timeout**: ADO's approval `timeoutInMinutes` and
  GitHub's Environment `wait_timer` are different concepts (one is "how long
  before the approval request expires," the other is "mandatory delay before
  deployment can proceed regardless of approval"). The scaffolder does not
  conflate them — `wait_timer_minutes` is left at 0 by default; set it
  deliberately if you want a mandatory wait independent of approvals.
- **Identity mapping is manual by design**, not a gap to be closed — there's
  no safe way to auto-resolve an ADO/Entra identity to a GitHub username
  without a directory service lookup this tool doesn't have access to.
