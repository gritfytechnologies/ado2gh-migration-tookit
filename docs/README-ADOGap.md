# adogap — ADO Release-Pipeline Gap Filler

`tools/adogap/` is a self-contained Python 3.11+ package. Companion to
`gh actions-importer` and `scripts/Invoke-GHActionsImporterMigration.ps1`.

## Why this exists

`gh actions-importer azure-devops release` converts the mechanical shape of
a classic release pipeline — stages, jobs, tasks — into GitHub Actions YAML.
What it does **not** do, and explicitly documents as manual follow-up in
every PR it opens, is:

- Recreate **approvals** as GitHub Environment required reviewers
- Recreate **deployment gates** (no direct equivalent exists in Actions)
- Set up **service connection** replacements (OIDC federated credentials)
- Migrate **variable group secret values**

The importer's own audit report calls a pipeline "Successful" even when
every approval on a production environment was silently dropped, because
structurally the conversion did succeed — it just never carried over
constructs it wasn't designed to carry over. That's the gap `adogap` closes,
and it makes the gap **impossible to miss** by verifying it explicitly
rather than relying on someone reading the PR description carefully.

Only relevant to repos with **classic ADO release pipelines** — build/CI
pipelines converted by `gh actions-importer` don't have this gap.

Three steps:

1. **extract** — parses the source ADO release definition (live API pull or
   local JSON) and pulls out every approval, gate, service connection, and
   variable group reference, per stage.
2. **scaffold** — generates ready-to-review artifacts: GitHub Environment
   config, a `gh api`-based apply script, OIDC federated credential
   templates for Azure, a reviewer identity-mapping CSV, and gates/secrets
   checklists.
3. **verify** — diffs the extraction against the actual converted workflow
   YAML and fails loudly if approvals or gates were dropped, or if
   service-connection auth wasn't addressed.

`adogap` is **read-only against Azure DevOps** and **never writes directly
to GitHub** — every scaffolded artifact is generated to disk for a human to
review, fill in, and apply deliberately.

---

## Installation

Requires Python 3.11+.

```bash
cd tools/adogap
python3 -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\Activate.ps1
pip install -e .
adogap --version
```

Or without installing as a package:

```bash
cd tools/adogap
pip install -r requirements.txt
python -m adogap --help
```

## Configuration

```bash
cd tools/adogap
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

Tuning (optional, sensible defaults):

| Variable | Default | Purpose |
|---|---|---|
| `ADOGAP_MAX_RETRIES` | 5 | Retry attempts on transient/rate-limit failures |
| `ADOGAP_INITIAL_BACKOFF_SECONDS` | 10 | Base for exponential backoff |
| `ADOGAP_MAX_CONCURRENCY` | 3 | Parallel workers in `batch` mode |
| `ADOGAP_MIN_REQUEST_INTERVAL_SECONDS` | 1.0 | Floor spacing between ADO API calls |

If you already ran `gh actions-importer audit`, you have local JSON exports
of your pipelines — pass those via `--source-file` instead of hitting the
ADO API again; no credentials needed for that path.

## Commands

| Command | Purpose |
|---|---|
| `adogap extract` | Pulls approvals/gates/service connections/variable groups into `extracted.json` + summary |
| `adogap scaffold` | Generates environment config, apply script, OIDC templates, checklists |
| `adogap verify` | Diffs extraction against a converted workflow file; PASS/WARN/FAIL per construct |
| `adogap run-all` | Runs all three steps for a single release pipeline in one pass |
| `adogap batch` | Runs extract + scaffold (+ verify) across every release pipeline in an inventory file |

```bash
adogap extract --release-id 17 --output-dir ./out
adogap scaffold --release-id 17 --github-org <github-org> --repo-name payments-api --output-dir ./out
adogap verify --release-id 17 --workflow-file ./workflow-output/release.yml --output-dir ./out
adogap run-all --release-id 17 --github-org <github-org> --repo-name payments-api \
  --workflow-file ./workflow-output/release.yml --output-dir ./out
adogap batch --inventory ../../inventory/ado-inventory.json --github-org <github-org> \
  --workflow-search-root ./ghai-output/artifacts --output-dir ./adogap-output
```

`scaffold` produces, under `<output-dir>/<pipeline-name>/scaffold/`:

| File | Purpose |
|---|---|
| `environments.json` | Structured environment definitions (reviewers, gate counts, service connections, variable groups) |
| `create-environments.sh` | `gh api` script that creates each GitHub Environment with reviewers — **refuses to run until `reviewer-mapping.csv` is fully filled in** |
| `reviewer-mapping.csv` | ADO identity -> GitHub username, blank for you to fill (no safe automated way to resolve this) |
| `oidc-federated-credentials.json` | One entry per service connection, with the `repo:{org}/{repo}:environment:{name}` subject claim pre-built, plus an `az ad app federated-credential create` command template |
| `gates-checklist.md` | Every deployment gate found, with a suggested GitHub-native redesign pattern per gate type |
| `secrets-checklist.md` | Every variable group referenced — values are **never** read or exported by this tool; re-enter them manually |

`verify` exits `1` on FAIL (or on WARN too, with `--fail-on-warn`) — wire
into CI to block a migration from being marked "done" until gaps are
addressed. `batch` expects the same `<root>/<repo>/Release-<id>/*.yml`
artifact layout `Invoke-GHActionsImporterMigration.ps1` produces, and writes
`batch-summary-<runid>.json`, exiting non-zero on any error/failed
verification.

## Rate limiting & reliability

Same defense-in-depth pattern as the PowerShell migration scripts: floor
spacing between ADO API calls, `Retry-After` honored when present,
exponential backoff with full jitter (capped at 5 minutes) on
429/403/503/known throttling text (`TF400733`, "rate limit", "secondary
rate limit", "abuse detection"), and per-item isolation in `batch` mode — one
pipeline's failure doesn't stop the rest of the batch.

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
cd tools/adogap
adogap run-all --release-id 17 --github-org <github-org> --repo-name payments-api \
  --workflow-file ../../gha-out/workflows/release.yml --output-dir ./adogap-out

# 3. Review adogap-out/payments-api-release/SUMMARY.md — the single
#    "is this pipeline actually done" checkpoint, not just the importer's PR.

# 4. Fill in reviewer-mapping.csv, then:
./adogap-out/payments-api-release/scaffold/create-environments.sh <github-org>/payments-api

# 5. Apply OIDC federated credentials via the Azure CLI commands in
#    oidc-federated-credentials.json

# 6. Re-run gh actions-importer migrate to open the PR, then re-run
#    adogap verify against the merged workflow to confirm PASS.
```

## Testing this toolkit yourself

`tools/adogap/fixtures/` has a synthetic ADO release definition with two
stages (Staging, Production), approvals on both, a gate on each, and a
service connection each — plus a matching converted workflow with the
Production Azure auth step deliberately omitted, so `adogap verify` can be
seen catching it:

```bash
cd tools/adogap
adogap run-all --source-file fixtures/sample-release-definition.json \
  --github-org acme-org --repo-name payments-api \
  --workflow-file fixtures/sample-converted-workflow.yml \
  --output-dir /tmp/adogap-test
```

## Known limitations

- **Service connection name/type resolution** — the extractor identifies
  *which* service connection ID is referenced per stage, but resolving its
  friendly name/type requires an additional `_apis/serviceendpoint/endpoints`
  call not yet wired into `extract()` (the `AdoClient.get_service_connection()`
  method exists — easy follow-up if you want names in the OIDC templates
  instead of raw GUIDs).
- **Wait timer vs. approval timeout** — ADO's approval `timeoutInMinutes`
  and GitHub's Environment `wait_timer` are different concepts; the
  scaffolder does not conflate them — `wait_timer_minutes` defaults to 0,
  set it deliberately for a mandatory wait independent of approvals.
- **Identity mapping is manual by design** — no safe way to auto-resolve an
  ADO/Entra identity to a GitHub username without a directory service
  lookup this tool doesn't have access to.
