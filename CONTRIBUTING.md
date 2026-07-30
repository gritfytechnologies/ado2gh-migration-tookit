# Contributing

## Scope

This is the Enterprise GitHub Migration Toolkit (Internal — see `CLAUDE.md`).
PowerShell orchestration scripts live flat under `scripts/`
(`Invoke-GHEMigration.ps1`, `Get-ADOInventory.ps1`,
`Invoke-GHActionsImporterMigration.ps1`, `4_Rewire-Pipeline.ps1`,
`Invoke-GitHubAudit.ps1`, `Invoke-GitHubRemediate.ps1`), plus one Python
package, `adogap`, under `tools/adogap/`. Keep changes scoped to one script
(or `adogap`) per PR unless you're changing a shared convention (e.g. the
ADO inventory JSON schema consumed by more than one script).

## Before opening a PR

- **PowerShell scripts** (`scripts/*.ps1`): run
  [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) against
  any script you touch:
  ```powershell
  Invoke-ScriptAnalyzer -Path .\scripts\*.ps1 -Severity Warning,Error
  ```
  Verify the script still parses cleanly (the parameter block, i.e.
  `[CmdletBinding()]`/`param(...)`, must be the first statement after any
  `#Requires` lines and comment-based help — nothing else may precede it):
  ```powershell
  $tokens = $null; $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile('scripts\<script>.ps1', [ref]$tokens, [ref]$errors)
  $errors
  ```

- **`adogap`** (Python, under `tools/adogap/`): add/extend tests under
  `tools/adogap/tests/`, and run:
  ```bash
  cd tools/adogap
  pip install -e ".[dev]" 2>/dev/null || pip install -e .
  python -m pytest
  ```
  For a quick syntax check without installing dependencies:
  ```bash
  python -m py_compile tools/adogap/src/adogap/*.py
  ```

## No client- or environment-specific data

Examples, defaults, and fixtures must use generic placeholders (`<ado-org>`,
`<github-org>`, `contoso`, `acme-org`, `payments-api`, etc.), never a real
organisation name, PAT, service connection name, or internal hostname.
Classification is Internal — do not add anything that would make outputs
unsafe to share externally.

## Commit style

Keep commits focused and describe the *why*, not just the *what* — the diff
already shows what changed.
