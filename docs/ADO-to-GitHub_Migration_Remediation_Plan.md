# ADO → GitHub Migration — Remediation Plan (Blocked/Warn Repos)

**Context:** `<N>` ADO projects / `<N>` repositories inventoried.
Status: `<N>` READY, `<N>` NEEDS REVIEW (100–400 MiB files), `<N>` BLOCKED
(GEI size violations). Source of truth: `trackers/blocked_repos_tracker.csv`
and `trackers/warn_repos_tracker.csv` (generated from the git-sizer pass).

## Section 1 — Critical Concerns

- **The migration script cannot detect GEI limits.** Individual-file size and
  total-blob limits live in git history, invisible to the ADO REST API the
  script's audit uses. Always pair the script's audit with
  `blocked_repos_tracker.csv` from a `Get-ADOInventory.ps1 -RunGitSizer` pass.
- **`-IncludeLfs` is informational only** — it does not change the
  `gh ado2gh migrate-repo` command. LFS objects migrate automatically.
- **Remediate to the 100 MiB per-file limit, not the 400 MiB migration
  ceiling.** A repo purged to 350 MiB files will migrate — and then every push
  touching those files fails against GitHub's 100 MiB push limit.
- **`region-tilts-repo` (Project A) failed its git-sizer clone** — risk is
  unknown. Handle it as a separate workstream: manual clone attempt, size
  analysis, then classification.

## Section 2 — Must-Purge Repo (special case)

**`large-dataset-repo` (Project A):** 56.08 GB unique blob data — exceeds the
40 GiB GEI repository limit outright; largest file 4.00 GB
(`data/raw_financials.pkl`). A standard purge is unlikely to reach compliance.
Requires a **dedicated workstream**: split the repo (code vs. data), move
datasets to blob storage or LFS-from-scratch, and rebuild history for the code
portion only.

## Section 3 — Remediation Tiers

| Tier | Count | Criteria | Approach |
|---|---|---|---|
| 0 — MUST-SPLIT-OR-DEEP-PURGE | 1 | Total blobs > 40 GiB | Repo split + deep purge (Section 2) |
| 1 — Large-blob-purge | 17 | Largest file 1–4 GB | `git filter-repo` purge, owner sign-off on lost paths |
| 2 — Standard-purge | 15 | Largest file 400 MB–1 GB | Standard purge procedure below |
| Warn-only | 24 | Files 100–400 MiB | Migrate fine; purge or LFS-track to protect future pushes |

## Section 4 — Per-Repo Remediation Procedure

```bash
# Step 1: bare clone the repo
git clone --bare https://dev.azure.com/{org}/{project}/_git/{repo} repo-purge.git
cd repo-purge.git

# Step 2: identify large files
git rev-list --objects --all | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' | awk '/^blob/ {print $3, $4}' | sort -rn | head -20

# Step 3: purge files > 100 MiB
git filter-repo --strip-blobs-bigger-than 100M

# Step 4: verify with git-sizer
git-sizer

# Step 5: push cleaned repo to a NEW ADO repo for validation
#         (never force-push over the original until owners sign off)

# Step 6: hand to Invoke-GHEMigration.ps1 only after git-sizer confirms clean
```

Notes: `git filter-repo` rewrites every SHA — treat the purged repo as a new
repo; open PRs and pipeline commit references to old SHAs will not resolve.
Coordinate a freeze with the owning team before Step 5.

## Section 5 — LFS Introduction Guidance

For repos whose large data files legitimately need to live on: introduce Git
LFS **for new files post-migration**:

```bash
git lfs install
git lfs track "*.pkl" "*.csv"
git add .gitattributes && git commit -m "Track large data formats in LFS"
```

Do **NOT** convert existing history to LFS (`git lfs migrate import`) unless
scoped as a dedicated migration workstream — it rewrites history with the same
blast radius as a purge and doubles storage during transition.
