from __future__ import annotations

import concurrent.futures
import json
import sys
import time
import uuid
from pathlib import Path

import click
from rich.console import Console
from rich.table import Table

from . import __version__
from .ado_client import AdoClient
from .config import Config, ConfigError
from .extractor import extract, load_release_definition_json
from .logging_utils import setup_logging
from .rate_limit import RateLimiter
from .report import write_combined_report
from .scaffolder import scaffold
from .verifier import verify

console = Console()


def _init_config(env_file: str | None) -> Config:
    try:
        return Config.from_env(env_file)
    except ConfigError as exc:
        console.print(f"[bold red]Configuration error:[/bold red] {exc}")
        sys.exit(2)


@click.group()
@click.version_option(__version__, prog_name="adogap")
def main() -> None:
    """adogap — gap-filler toolkit for ADO classic release -> GitHub Actions migrations.

    Fills what gh actions-importer does not convert: approvals, gates,
    service connections, and variable group secrets. Run 'extract',
    'scaffold', and 'verify' independently, or 'run-all' / 'batch' to do
    all three in one pass.
    """


@main.command(name="extract")
@click.option("--release-id", type=int, help="Azure DevOps release definition ID.")
@click.option("--source-file", type=click.Path(exists=True), help="Local JSON export instead of a live ADO pull.")
@click.option("--output-dir", type=click.Path(), default="./adogap-output", show_default=True)
@click.option("--env-file", type=click.Path(), default=None, help="Path to a .env file (default: .env in CWD).")
def extract_cmd(release_id: int | None, source_file: str | None, output_dir: str, env_file: str | None) -> None:
    """Extract approvals/gates/service connections/variable groups from a release definition."""
    run_id = uuid.uuid4().hex[:8]
    out = Path(output_dir)
    logger = setup_logging(out, run_id)

    ado_client = None
    if not source_file:
        config = _init_config(env_file)
        ado_client = AdoClient(config)

    raw = load_release_definition_json(definition_id=release_id, source_file=source_file, ado_client=ado_client)
    release_def = extract(raw)

    pipeline_dir = out / release_def.name.replace("/", "-")
    pipeline_dir.mkdir(parents=True, exist_ok=True)
    extracted_path = pipeline_dir / "extracted.json"
    extracted_path.write_text(
        json.dumps(_release_def_to_dict(release_def), indent=2), encoding="utf-8"
    )

    counts = release_def.summary_counts()
    logger.info("Extracted %s: %s", release_def.name, counts)
    console.print(f"[green]Extraction complete[/green] -> {extracted_path}")
    _print_counts_table(release_def.name, counts)


@main.command(name="scaffold")
@click.option("--release-id", type=int, help="Azure DevOps release definition ID.")
@click.option("--source-file", type=click.Path(exists=True), help="Local JSON export instead of a live ADO pull.")
@click.option("--github-org", required=True, help="Target GitHub org/user for the repo.")
@click.option("--repo-name", required=True, help="Target GitHub repository name (for OIDC subject claims).")
@click.option("--output-dir", type=click.Path(), default="./adogap-output", show_default=True)
@click.option("--env-file", type=click.Path(), default=None)
def scaffold_cmd(
    release_id: int | None,
    source_file: str | None,
    github_org: str,
    repo_name: str,
    output_dir: str,
    env_file: str | None,
) -> None:
    """Generate GitHub Environment config, OIDC credentials, and checklists from a release definition."""
    run_id = uuid.uuid4().hex[:8]
    out = Path(output_dir)
    logger = setup_logging(out, run_id)

    ado_client = None
    if not source_file:
        config = _init_config(env_file)
        ado_client = AdoClient(config)

    raw = load_release_definition_json(definition_id=release_id, source_file=source_file, ado_client=ado_client)
    release_def = extract(raw)

    pipeline_dir = out / release_def.name.replace("/", "-")
    artifacts = scaffold(release_def, github_org, repo_name, pipeline_dir / "scaffold")
    write_combined_report(release_def, artifacts, None, pipeline_dir)

    console.print(f"[green]Scaffolding complete[/green] -> {pipeline_dir / 'scaffold'}")
    for label, path in artifacts.items():
        console.print(f"  - {label}: {path}")


@main.command(name="verify")
@click.option("--release-id", type=int, help="Azure DevOps release definition ID.")
@click.option("--source-file", type=click.Path(exists=True), help="Local JSON export instead of a live ADO pull.")
@click.option("--workflow-file", required=True, type=click.Path(exists=True), help="Converted GitHub Actions workflow YAML from gh actions-importer.")
@click.option("--output-dir", type=click.Path(), default="./adogap-output", show_default=True)
@click.option("--env-file", type=click.Path(), default=None)
@click.option("--fail-on-warn", is_flag=True, help="Exit non-zero on WARN as well as FAIL.")
def verify_cmd(
    release_id: int | None,
    source_file: str | None,
    workflow_file: str,
    output_dir: str,
    env_file: str | None,
    fail_on_warn: bool,
) -> None:
    """Verify that gh actions-importer's output didn't silently drop approvals/gates/etc."""
    run_id = uuid.uuid4().hex[:8]
    out = Path(output_dir)
    logger = setup_logging(out, run_id)

    ado_client = None
    if not source_file:
        config = _init_config(env_file)
        ado_client = AdoClient(config)

    raw = load_release_definition_json(definition_id=release_id, source_file=source_file, ado_client=ado_client)
    release_def = extract(raw)

    report = verify(release_def, Path(workflow_file))

    pipeline_dir = out / release_def.name.replace("/", "-")
    write_combined_report(release_def, None, report, pipeline_dir)

    _print_verification_table(report)

    if report.overall_status == "FAIL" or (fail_on_warn and report.overall_status == "WARN"):
        sys.exit(1)


@main.command(name="run-all")
@click.option("--release-id", type=int, help="Azure DevOps release definition ID.")
@click.option("--source-file", type=click.Path(exists=True), help="Local JSON export instead of a live ADO pull.")
@click.option("--github-org", required=True)
@click.option("--repo-name", required=True)
@click.option("--workflow-file", type=click.Path(exists=True), help="Converted workflow YAML, if already generated. Skips verification if omitted.")
@click.option("--output-dir", type=click.Path(), default="./adogap-output", show_default=True)
@click.option("--env-file", type=click.Path(), default=None)
def run_all_cmd(
    release_id: int | None,
    source_file: str | None,
    github_org: str,
    repo_name: str,
    workflow_file: str | None,
    output_dir: str,
    env_file: str | None,
) -> None:
    """Run extract -> scaffold -> verify in one pass for a single release pipeline."""
    run_id = uuid.uuid4().hex[:8]
    out = Path(output_dir)
    logger = setup_logging(out, run_id)

    ado_client = None
    if not source_file:
        config = _init_config(env_file)
        ado_client = AdoClient(config)

    raw = load_release_definition_json(definition_id=release_id, source_file=source_file, ado_client=ado_client)
    release_def = extract(raw)

    pipeline_dir = out / release_def.name.replace("/", "-")
    artifacts = scaffold(release_def, github_org, repo_name, pipeline_dir / "scaffold")

    report = None
    if workflow_file:
        report = verify(release_def, Path(workflow_file))
        _print_verification_table(report)
    else:
        console.print("[yellow]No --workflow-file provided — skipping verification step.[/yellow]")

    summary_path = write_combined_report(release_def, artifacts, report, pipeline_dir)
    console.print(f"[green]Done.[/green] Summary: {summary_path}")

    if report and report.overall_status == "FAIL":
        sys.exit(1)


@main.command()
@click.option("--inventory", required=True, type=click.Path(exists=True), help="JSON inventory (same schema as Get-ADOInventory.ps1 / Invoke-GHActionsImporterMigration.ps1).")
@click.option("--github-org", required=True)
@click.option("--workflow-search-root", type=click.Path(), default=None,
              help="Root dir to look for converted workflows, expected layout "
                   "<root>/<repo>/Release-<id>/*.yml (matches the PowerShell "
                   "migration script's artifact directory structure).")
@click.option("--output-dir", type=click.Path(), default="./adogap-output", show_default=True)
@click.option("--env-file", type=click.Path(), default=None)
@click.option("--max-concurrency", type=int, default=None, help="Overrides ADOGAP_MAX_CONCURRENCY.")
def batch(
    inventory: str,
    github_org: str,
    workflow_search_root: str | None,
    output_dir: str,
    env_file: str | None,
    max_concurrency: int | None,
) -> None:
    """Run extract -> scaffold -> (verify) for every release pipeline in an inventory file."""
    run_id = uuid.uuid4().hex[:8]
    out = Path(output_dir)
    logger = setup_logging(out, run_id)

    config = _init_config(env_file)
    concurrency = max_concurrency or config.max_concurrency
    rate_limiter = RateLimiter(config.min_request_interval_seconds)
    ado_client = AdoClient(config, rate_limiter=rate_limiter)

    inventory_data = json.loads(Path(inventory).read_text(encoding="utf-8"))
    repos = inventory_data.get("Repositories", [])

    work_items = []
    for repo in repos:
        repo_name = repo.get("RepoName")
        for release_id in repo.get("ReleasePipelineIds", []) or []:
            work_items.append((repo_name, release_id))

    if not work_items:
        console.print("[yellow]No release pipelines found in inventory (check ReleasePipelineIds).[/yellow]")
        return

    console.print(f"Processing {len(work_items)} release pipeline(s) across "
                  f"{len({r for r, _ in work_items})} repo(s) with concurrency={concurrency}...")

    results = []

    def process_one(repo_name: str, release_id: int) -> dict:
        try:
            raw = load_release_definition_json(definition_id=release_id, source_file=None, ado_client=ado_client)
            release_def = extract(raw)

            pipeline_dir = out / repo_name / f"release-{release_id}"
            artifacts = scaffold(release_def, github_org, repo_name, pipeline_dir / "scaffold")

            report = None
            if workflow_search_root:
                candidate_dir = Path(workflow_search_root) / repo_name / f"Release-{release_id}"
                yml_files = list(candidate_dir.glob("*.yml")) + list(candidate_dir.glob("*.yaml"))
                if yml_files:
                    report = verify(release_def, yml_files[0])

            write_combined_report(release_def, artifacts, report, pipeline_dir)

            return {
                "repo": repo_name,
                "release_id": release_id,
                "status": "OK",
                "verification_status": report.overall_status if report else "NOT_RUN",
            }
        except Exception as exc:  # noqa: BLE001
            logger.error("Failed processing %s / release %s: %s", repo_name, release_id, exc)
            return {"repo": repo_name, "release_id": release_id, "status": "ERROR", "error": str(exc)}

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = {executor.submit(process_one, repo, rid): (repo, rid) for repo, rid in work_items}
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())

    _print_batch_summary(results)

    summary_json_path = out / f"batch-summary-{run_id}.json"
    summary_json_path.write_text(json.dumps(results, indent=2), encoding="utf-8")
    console.print(f"\nBatch summary written to {summary_json_path}")

    error_count = sum(1 for r in results if r["status"] == "ERROR")
    fail_count = sum(1 for r in results if r.get("verification_status") == "FAIL")
    if error_count or fail_count:
        sys.exit(1)


def _release_def_to_dict(release_def) -> dict:
    """Best-effort JSON-serializable dump of a ReleaseDefinition (dataclasses
    aren't JSON-serializable by default)."""
    import dataclasses

    def convert(obj):
        if dataclasses.is_dataclass(obj):
            return {k: convert(v) for k, v in dataclasses.asdict(obj).items()}
        if isinstance(obj, list):
            return [convert(v) for v in obj]
        return obj

    return convert(release_def)


def _print_counts_table(name: str, counts: dict) -> None:
    table = Table(title=f"Extraction summary — {name}")
    table.add_column("Construct")
    table.add_column("Count", justify="right")
    for k, v in counts.items():
        table.add_row(k, str(v))
    console.print(table)


def _print_verification_table(report) -> None:
    icon = {"PASS": "[green]PASS[/green]", "WARN": "[yellow]WARN[/yellow]", "FAIL": "[red]FAIL[/red]"}
    table = Table(title=f"Verification — {report.release_name} (overall: {report.overall_status})")
    table.add_column("Check")
    table.add_column("Status")
    table.add_column("Detail", overflow="fold")
    for c in report.checks:
        table.add_row(c.name, icon[c.status], c.detail)
    console.print(table)


def _print_batch_summary(results: list[dict]) -> None:
    table = Table(title="Batch summary")
    table.add_column("Repo")
    table.add_column("Release ID")
    table.add_column("Status")
    table.add_column("Verification")
    for r in results:
        status_style = "green" if r["status"] == "OK" else "red"
        table.add_row(
            r["repo"], str(r["release_id"]),
            f"[{status_style}]{r['status']}[/{status_style}]",
            r.get("verification_status", "-"),
        )
    console.print(table)


if __name__ == "__main__":
    main()
