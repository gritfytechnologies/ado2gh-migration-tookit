from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

from .models import ReleaseDefinition

logger = logging.getLogger("adogap")


@dataclass
class CheckResult:
    name: str
    status: str  # "PASS" | "WARN" | "FAIL"
    detail: str


@dataclass
class VerificationReport:
    release_id: int
    release_name: str
    workflow_file: str
    checks: list[CheckResult] = field(default_factory=list)

    @property
    def overall_status(self) -> str:
        statuses = {c.status for c in self.checks}
        if "FAIL" in statuses:
            return "FAIL"
        if "WARN" in statuses:
            return "WARN"
        return "PASS"

    def add(self, name: str, status: str, detail: str) -> None:
        self.checks.append(CheckResult(name=name, status=status, detail=detail))


def _load_workflow(workflow_path: Path) -> dict[str, Any]:
    with open(workflow_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def _job_uses_environment_protection(job: dict[str, Any]) -> bool:
    """gh actions-importer does emit `environment:` blocks on jobs (mapping
    ADO's manual-deployment construct), but it does NOT create the actual
    GitHub Environment object with reviewers/protection rules — that object
    is created separately (in the GitHub UI, API, or Terraform) and just
    referenced by name here. So the presence of `environment:` in the
    workflow tells us the *name* was preserved, not that protection exists."""
    return "environment" in job


def verify(release_def: ReleaseDefinition, workflow_path: Path) -> VerificationReport:
    workflow = _load_workflow(workflow_path)
    jobs = workflow.get("jobs", {}) or {}

    report = VerificationReport(
        release_id=release_def.id,
        release_name=release_def.name,
        workflow_file=str(workflow_path),
    )

    # --- Stage / job count -----------------------------------------------
    source_stage_count = len(release_def.stages)
    workflow_job_count = len(jobs)
    if workflow_job_count >= source_stage_count:
        report.add(
            "stage_to_job_mapping", "PASS",
            f"{source_stage_count} source stage(s) -> {workflow_job_count} workflow job(s).",
        )
    else:
        report.add(
            "stage_to_job_mapping", "WARN",
            f"Source has {source_stage_count} stage(s) but workflow only has {workflow_job_count} job(s). "
            "Verify no stage was dropped or merged unexpectedly.",
        )

    # --- Environment name preservation (not protection — see docstring) --
    stage_names = {s.name for s in release_def.stages}
    job_env_names = {
        job.get("environment").get("name") if isinstance(job.get("environment"), dict) else job.get("environment")
        for job in jobs.values()
        if _job_uses_environment_protection(job)
    }
    missing_env_refs = stage_names - {n for n in job_env_names if n}
    if not missing_env_refs:
        report.add(
            "environment_name_preserved", "PASS",
            "Every source stage name is referenced by an `environment:` block in the workflow.",
        )
    else:
        report.add(
            "environment_name_preserved", "WARN",
            f"Stage(s) with no matching `environment:` reference in the workflow: {sorted(missing_env_refs)}. "
            "Deployment history/protection for these stages may not carry over.",
        )

    # --- Approvals: importer never creates protection rules, so this is
    #     effectively always a FAIL unless the scaffold step's apply script
    #     has already been run against the target repo. This check exists to
    #     make that gap impossible to miss, not to pass cleanly by default. --
    stages_with_approvals = [
        s for s in release_def.stages
        if (s.pre_approvals and s.pre_approvals.approvers) or (s.post_approvals and s.post_approvals.approvers)
    ]
    if stages_with_approvals:
        names = ", ".join(s.name for s in stages_with_approvals)
        report.add(
            "approvals_carried_over", "FAIL",
            f"{len(stages_with_approvals)} stage(s) had required approvals in ADO ({names}) that "
            "gh actions-importer does NOT recreate as GitHub Environment reviewers. Run the scaffold "
            "step's create-environments.sh against the target repo before treating this pipeline as migrated.",
        )
    else:
        report.add("approvals_carried_over", "PASS", "No approvals were configured on any stage in the source.")

    # --- Gates: always manual, always flagged if present ------------------
    stages_with_gates = [s for s in release_def.stages if s.gates]
    if stages_with_gates:
        gate_count = sum(len(s.gates) for s in stages_with_gates)
        report.add(
            "gates_carried_over", "FAIL",
            f"{gate_count} deployment gate(s) across {len(stages_with_gates)} stage(s) have no "
            "GitHub Actions equivalent and were silently dropped by the importer. See gates-checklist.md.",
        )
    else:
        report.add("gates_carried_over", "PASS", "No deployment gates were configured on any stage in the source.")

    # --- Service connections: workflow should reference azure/login or
    #     OIDC-style auth somewhere if the source used one -----------------
    stages_with_sc = [s for s in release_def.stages if s.service_connections]
    if stages_with_sc:
        workflow_text = yaml.safe_dump(workflow)
        has_azure_auth_step = "azure/login" in workflow_text or "id-token" in workflow_text
        if has_azure_auth_step:
            report.add(
                "service_connections_addressed", "WARN",
                f"{len(stages_with_sc)} stage(s) used a service connection and the workflow does contain "
                "an Azure auth step, but verify OIDC federated credentials were actually created "
                "(see oidc-federated-credentials.json) — the workflow referencing azure/login does not "
                "by itself prove the federated credential exists in Entra ID.",
            )
        else:
            report.add(
                "service_connections_addressed", "FAIL",
                f"{len(stages_with_sc)} stage(s) used a service connection but no Azure auth step or "
                "'id-token' permission was found in the workflow. Manual setup required — see "
                "oidc-federated-credentials.json.",
            )
    else:
        report.add("service_connections_addressed", "PASS", "No service connections referenced in the source.")

    # --- Variable groups: always manual --------------------------------
    stages_with_vg = [s for s in release_def.stages if s.variable_groups]
    if stages_with_vg:
        report.add(
            "variable_group_secrets_addressed", "WARN",
            f"{len(stages_with_vg)} stage(s) referenced variable groups. Secret values are never migrated "
            "automatically by design — confirm each has been manually recreated as a GitHub secret "
            "(see secrets-checklist.md).",
        )
    else:
        report.add("variable_group_secrets_addressed", "PASS", "No variable groups referenced in the source.")

    return report


def report_to_markdown(report: VerificationReport) -> str:
    icon = {"PASS": "✅", "WARN": "⚠️", "FAIL": "❌"}
    lines = [
        f"# Verification report — {report.release_name} (ID {report.release_id})\n",
        f"**Workflow checked:** `{report.workflow_file}`\n",
        f"**Overall status:** {icon[report.overall_status]} {report.overall_status}\n",
        "| Check | Status | Detail |",
        "|---|---|---|",
    ]
    for c in report.checks:
        lines.append(f"| {c.name} | {icon[c.status]} {c.status} | {c.detail} |")
    return "\n".join(lines)
