from __future__ import annotations

from pathlib import Path

from .models import ReleaseDefinition
from .verifier import VerificationReport, report_to_markdown


def write_combined_report(
    release_def: ReleaseDefinition,
    scaffold_artifacts: dict[str, Path] | None,
    verification: VerificationReport | None,
    output_dir: Path,
) -> Path:
    """Writes a single human-readable Markdown summary for one release
    pipeline's gap-fill run, linking out to every generated artifact."""
    output_dir.mkdir(parents=True, exist_ok=True)
    report_path = output_dir / "SUMMARY.md"

    counts = release_def.summary_counts()

    lines = [
        f"# adogap summary — {release_def.name} (ID {release_def.id})\n",
        "## Extracted from source ADO release definition\n",
        f"- Stages: {counts['stages']}",
        f"- Required approvals: {counts['approvals']}",
        f"- Deployment gates: {counts['gates']}",
        f"- Unique service connections: {counts['service_connections']}",
        f"- Unique variable groups: {counts['variable_groups']}\n",
    ]

    if scaffold_artifacts:
        lines.append("## Scaffolded artifacts (review before applying)\n")
        for label, path in scaffold_artifacts.items():
            lines.append(f"- **{label}**: `{path}`")
        lines.append("")
        lines.append(
            "Run order: fill in `reviewer-mapping.csv` -> review `create-environments.sh` -> "
            "run it against the target repo -> work through `gates-checklist.md` and "
            "`secrets-checklist.md` -> apply `oidc-federated-credentials.json` via Azure CLI/Terraform.\n"
        )

    if verification:
        lines.append("## Verification against converted workflow\n")
        lines.append(report_to_markdown(verification))
        lines.append("")

    report_path.write_text("\n".join(lines), encoding="utf-8")
    return report_path
