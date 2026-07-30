# Backlog — Bugs, Gaps, and Missing Features

This is the single, actively-maintained tracker for every defect, dead-code
item, documentation gap, and missing feature found during full-repository
code reviews. It is a superset of the curated "top findings" table in the
root [`README.md`](../README.md#16-known-limitations--gap-analysis) §16 —
every `G-#` ID here matches the ID used there, plus additional lower-severity
items that didn't make that condensed table. When you fix an item, update its
**Status** here rather than deleting the row — keep the history.

**How to use this doc**: pick an item, read its **Evidence** citation before
touching code (file:line, still accurate as of the last full review below),
make the fix, update **Status** to `Fixed` and add the date + what changed.
If a review later finds the item is stale/no-longer-applicable, mark it
`Stale` rather than deleting it, so future reviewers know it was checked.

**Last full-repository review**: 2026-07-30 (three independent code-level
passes covering all 6 PowerShell scripts, the full `tools/adogap/` Python
package, and all 17 documentation files, cross-checked against actual code).

**Status legend**: `Open` · `Fixed` · `Stale` (no longer applicable) ·
`Won't Fix` (accepted trade-off, documented why).

---

## Priority 1 — High severity (functional or security impact)

| ID | Title | Evidence | Impact | Status |
|---|---|---|---|---|
| G-17 | Inventory→conversion pipeline schema mismatch: `Get-ADOInventory.ps1`'s JSON output (`'Repository Name'`, `'Build Pipeline Count'`/`'Release Pipeline Count'`) doesn't match what `Invoke-GHActionsImporterMigration.ps1` and `adogap batch --inventory` both require (`RepoName`, `BuildPipelineIds[]`/`ReleasePipelineIds[]`) | `Get-ADOInventory.ps1:1885-1907` vs `Invoke-GHActionsImporterMigration.ps1:564,579,595` vs `tools/adogap/src/adogap/cli.py:230-237` | The documented 3-tool discovery→conversion→gap-fill pipeline is not actually wired end-to-end; feeding real inventory output into either downstream tool fails or silently finds zero pipelines | Open |
| G-1 | `Invoke-GitHubRemediate.ps1`'s policy-key catalog doesn't match several of `Invoke-GitHubAudit.ps1`'s actual check names; two repo-scoped check names (`secret_scanning`, `dependabot_alerts`) collide with org-scoped catalog entries | `Invoke-GitHubAudit.ps1:150-155,250,257` vs `Invoke-GitHubRemediate.ps1:129,134,224` | Selecting a repo-level `secret_scanning`/`dependabot_alerts` finding from the remediation menu silently changes **org-wide defaults** instead of fixing the flagged repo; several org-level findings never appear in the menu at all | Open |
| G-4 | `Invoke-GHActionsImporterMigration.ps1` reads `$LASTEXITCODE` in the parent scriptblock after a `Start-Job`-based `gh actions-importer` call — a background job runs in a separate process, so this check likely never reflects the job's real exit code | `Invoke-GHActionsImporterMigration.ps1:652-668` | Failed conversions may be misclassified as succeeded in the dashboard/state unless they also trip the separate rate-limit text-pattern match | Open |
| G-3 | Self-service pipeline's Stage 4 (`PostMigrationValidation`) initializes `$fail = 0` but never increments it anywhere — the stage can never fail regardless of what it finds | `pipeline/ado2gh-self-service.yml:281-300` | False sense of a validation gate in CI; missing-branch-protection findings only produce a warning annotation, never block the pipeline | Open |

## Priority 2 — Medium severity (correctness, staleness, security hygiene)

| ID | Title | Evidence | Impact | Status |
|---|---|---|---|---|
| G-2 | `Get-ADOInventory.ps1 -CheckActionsImporter` doc comment claims it uses the real `gh actions-importer` CLI when installed; code always uses a ~29-task regex heuristic (`Get-YamlActionsImporterReadiness`) regardless | `Get-ADOInventory.ps1:401-455,820-830` | Readiness scores are directional only, not authoritative — doc overclaims relative to code | Open |
| G-6 | `Invoke-GHEMigration.ps1`'s `Invoke-WithRetry` helper (exponential backoff, `Retry-After`-aware) is fully implemented but has zero call sites — every real `gh`/API call checks `$LASTEXITCODE` directly instead | `Invoke-GHEMigration.ps1:993-1031` | No automatic retry on transient GitHub/ADO API failures during migration/verification/post-config (only the Actions-Importer script and adogap have working retry) | Open |
| G-14 | No secret-redaction logging control anywhere in `tools/adogap/logging_utils.py` | `tools/adogap/src/adogap/logging_utils.py` (whole file) | No structural defense-in-depth against accidentally logging `config.ado_pat`, unlike the PowerShell side's stated "never log a PAT" convention (`CLAUDE.md`) — no observed leak today, but no filter/handler exists either | Open |
| G-15 | `docs/MIGRATION-FLOW.md`'s diagram is stamped "(v2.7.0)" but its body reflects an earlier feature set — wrong verification CSV filename (`branch-verification-*` instead of `repo-verification-*`), missing Phase 5b LFS entirely, missing per-repo SHA validation and custom-properties steps | `docs/MIGRATION-FLOW.md:87` vs `Invoke-GHEMigration.ps1:1696` | Misleading authoritative-looking flow reference for anyone using it instead of the root README's diagram | Open |
| G-16 | `docs/Migration-Recommendations.md` is anchored to v2.1.0 — its "is this ready for 100 repos" readiness assessment doesn't account for LFS fallback, per-repo validation, custom properties, or resumable state, all added since | `docs/Migration-Recommendations.md:18,29` | Stale go/no-go input for pre-production decisions | Open |
| G-11 | No task-level (ADO task → GitHub Action) mapping table exists anywhere in this repo — that conversion logic lives entirely inside the closed-source `gh actions-importer` CLI extension, not in this codebase | N/A — absence confirmed by exhaustive review | Operators have no repo-local reference for what a specific ADO task becomes; this is a genuine capability gap, not a bug (see [§ By-design constraints](#by-design-constraints--not-bugs)) | Open |
| G-19 | Multiple dead `adogap` code paths: `AdoClient.list_release_definitions()`, `.get_service_connection()`, `.get_build_definition()`, `.get_variable_group()` never called; `ReleaseStage.has_manual_constructs` property never referenced; `extractor.py:25`'s comment describes a `--dump-raw` flag that doesn't exist on `extract` | `tools/adogap/src/adogap/ado_client.py:59-73`, `models.py:53-61`, `extractor.py:25` | Dead code; notably, wiring in the dead `get_service_connection`/`get_variable_group` methods is the direct fix for extraction only ever capturing IDs, never names | Open |
| G-9 | `trackers/blocked_repos_tracker.csv` / `warn_repos_tracker.csv` contain real sample data with a `RemediationTier` vocabulary that no script in this repo produces or reads | Confirmed via repo-wide grep — no script references these filenames or the `RemediationTier` field | Readers may assume these are tool-generated; they're manually maintained spreadsheets living in a directory that implies automation | Open |

## Priority 3 — Low severity (dead code, minor gaps, CLI polish)

| ID | Title | Evidence | Impact | Status |
|---|---|---|---|---|
| G-5 | `bin/`-folder tool auto-discovery is inconsistent — only `Invoke-GHEMigration.ps1` searches it; `Invoke-GitHubAudit.ps1` needs explicit `-ToolsPath`; `Invoke-GitHubRemediate.ps1`/`4_Rewire-Pipeline.ps1` have none | `Invoke-GHEMigration.ps1:348-377` vs `Invoke-GitHubAudit.ps1`'s `Resolve-Tool` vs absence elsewhere | Cached binaries in `bin/` only benefit 1 of 6 scripts without extra flags | Open |
| G-7 | `tools/adogap/README.md` and `docs/README-ADOGap.md` are near-verbatim duplicates | Both files, ~230-276 lines each | Documentation drift risk — a future edit to one won't propagate to the other | Open |
| G-8 | No formal plugin/extension architecture anywhere in the toolkit | N/A — architectural observation | Every extension requires editing existing scripts/modules directly; not a defect at current toolkit size (6 scripts) | Open (informational — see Won't Fix candidates) |
| G-10 | `prompts/RECREATE-REPO-PROMPT.md` is a stub — the file's own text says to paste the canonical recreation prompt below a marker, but no such prompt content exists in the file | `prompts/RECREATE-REPO-PROMPT.md:13-18` | File can't be used for its stated purpose | Open |
| G-12 | `GITHUB_ORG`/`GITHUB_INSTANCE_URL` env vars are parsed into adogap's `Config` dataclass but never actually read anywhere in the codebase — the real `--github-org` CLI flag does that job | `tools/adogap/src/adogap/config.py` vs zero references to `config.github_org` anywhere else | `.env`-only configuration of `GITHUB_ORG` silently has no effect; must always pass `--github-org` explicitly | Open |
| G-13 | `migration.config.json`'s shipped template omits `VerboseMigration` and `SkipExistingRepos` keys even though `Import-ConfigFile` supports loading both | `Invoke-GHEMigration.ps1`'s `$switchFields` list vs `migration.config.json` | Minor incompleteness vs. the file's own "each key matches a switch" comment | Open |
| G-18 | `Invoke-GHEMigration.ps1`'s `Invoke-SingleMigration` function is defined but never called — `Invoke-WaveMigration`'s inline worker scriptblock duplicates the same logic instead | `Invoke-GHEMigration.ps1:1468-1507` vs `1536-1569` | Dead code, no runtime impact | Open |
| G-20 | `adogap`'s `setup_logging()` supports a `verbose` parameter, but no CLI subcommand exposes a `--verbose`/`-v` flag to reach it | `tools/adogap/src/adogap/logging_utils.py:40-61` vs every `cli.py` call site (2 positional args only) | DEBUG-level logging is unreachable from the CLI | Open |
| G-21 | `adogap run-all` has no `--fail-on-warn` option, unlike the standalone `verify` command | `tools/adogap/src/adogap/cli.py:122` (verify) vs `:155-199` (run-all) | Minor CLI inconsistency; low practical impact since approvals/gates already force FAIL rather than WARN when present | Open |
| G-22 | `Get-ADOInventory.ps1` has no `-SkipExcel`/`-JsonOnly` switch — the `ImportExcel` module dependency and 8-sheet workbook are never optional | `Get-ADOInventory.ps1` param block (12 params, none skip Excel) | Forces an `ImportExcel` install even for JSON-only/CI use cases | Open |
| G-23 | `docs/poc-validation-steps.md`'s "Remaining Tests" list has no scenario for `-IncludeLfs`/Phase 5b or `-CustomProperties`/`-SetAdoMetadata` | `docs/poc-validation-steps.md` Part 2 | Test-plan coverage gap, not a code defect | Open |
| G-25 | `scaffolder.py`'s generated apply-script comment and prose docs mention Terraform as an alternative application method for OIDC federated credentials, but no code path ever generates Terraform/Bicep — only a JSON file + an `az ad app federated-credential create` CLI command string | `tools/adogap/src/adogap/scaffolder.py:89,123-159` | Doc/comment overclaim relative to actual generated artifacts | Open |

## Documentation-only fixes already applied during the 2026-07-30 review

Tracked here for traceability — these were found and fixed as part of
writing the consolidated root README, not left open:

| Item | What was wrong | Fix applied |
|---|---|---|
| Root README PowerShell-version undersell | Old root README's single Prerequisites table said `PowerShell 7.0` blanket, undersold `Invoke-GHActionsImporterMigration.ps1`'s actual 7.2+ requirement | New README §7 has a full per-script version-floor table |
| Orphan documentation pages | `docs/REFERENCES.md` and `docs/poc-validation-steps.md` had zero inbound links from any other doc in the repo | Both now linked from README §24 "Further Reading" |
| `CLAUDE.md` blanket PowerShell-version claim (G-24) | Same oversimplification as above, in the AI-instruction file | Replaced with the same per-script breakdown now in README §7 |

---

## Test coverage gaps

| ID | Title | Evidence | Status |
|---|---|---|---|
| G-26 | `tools/adogap/tests/` does not exist at all — the CI workflow's conditional `pytest` step (`.github/workflows/ci.yml:67-73`) always takes the "no tests found, skipping" branch today | `find tools/adogap -type d -name tests` returns nothing | Open |
| — | No PowerShell script in this repo has any unit test — CI is lint (PSScriptAnalyzer) + parse-validation only, never behavioral | `.github/workflows/ci.yml` `powershell-lint` job | Open (accepted at current scale per `CONTRIBUTING.md`'s manual-fixture testing guidance — flagging for visibility, not proposing a new PS test framework unprompted) |
| — | No fully-offline dry-run exists for the PowerShell scripts — `Invoke-GHEMigration.ps1 -DryRun` still requires live ADO/GitHub credentials for its audit/discovery calls before simulating | `Invoke-GHEMigration.ps1` Phase 1–3 always hit real APIs | Open |

---

## By-design constraints — not bugs

These are intentional, already correctly disclosed in code comments and/or
docs. Listed here so a future contributor doesn't "fix" them into something
worse, and so this backlog is genuinely complete per the instruction not to
omit anything found during review.

- **`adogap verify`'s `approvals_carried_over`/`gates_carried_over` checks
  always FAIL when the source pipeline has real approvals/gates**
  (`verifier.py:102-119,121-131`). This is intentional — a PASS requires
  re-verifying against the *post-scaffold-applied* state, not the raw
  importer output. Do not "fix" this to be more lenient; it exists to force
  a human checkpoint before declaring a release-pipeline conversion safe.
- **adogap never calls the GitHub API and never reads secret values.** Both
  are deliberate scope boundaries (read-only ADO access; secrets are never
  retrievable via the ADO API to a read-only PAT in the first place, and the
  tool doesn't attempt to work around that).
- **No task-level ADO→GitHub Actions mapping logic exists in this repo**
  (G-11, listed above under Priority 2 because it's worth actively tracking
  as a documentation gap to close, but the underlying reason — the mapping
  logic is inside a closed-source external tool — is not something this
  repo can fix by writing more code).
- **Deployment gates have no GitHub Actions equivalent.** `adogap` generates
  a manual-redesign checklist instead of attempting an automated mapping —
  correct, since no such construct exists on the GitHub side.
- **Three different concurrency models across three scripts**
  (`RunspacePool` / `ForEach-Object -Parallel` / Python `ThreadPoolExecutor`)
  — each is individually justified by comments in its own script (EMU
  reliability for RunspacePool; `-Parallel`'s `$using:`-only scoping model
  for the Actions-Importer script). Not a defect to unify without cause.

---

## Roadmap sequencing

See root [`README.md` §18](../README.md#18-roadmap-recommendations) for the
priority-ordered rollout plan referencing these IDs. Summary: fix G-17
first (breaks the documented cross-tool pipeline), then the three other
Priority-1 items (G-1, G-3, G-4), then security (G-14) and test-coverage
(G-26) gaps, then the Priority-2/3 backlog opportunistically alongside
related feature work.
