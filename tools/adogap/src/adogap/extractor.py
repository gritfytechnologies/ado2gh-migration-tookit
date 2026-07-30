from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any

from .models import (
    ApprovalGroup,
    Approver,
    Gate,
    ReleaseDefinition,
    ReleaseStage,
    ServiceConnectionRef,
    VariableGroupRef,
)

logger = logging.getLogger("adogap")

# NOTE ON SCHEMA STABILITY:
# Field names below match the Azure DevOps REST API 7.1 release definitions
# schema as documented by Microsoft (_apis/release/definitions). Microsoft
# has made minor additive schema changes across API versions in the past —
# if a field below comes back empty on a live pull, dump the raw JSON
# (adogap extract --dump-raw) and diff against these paths before assuming
# the construct doesn't exist in that pipeline.


def load_release_definition_json(
    *, definition_id: int | None, source_file: str | None, ado_client=None
) -> dict[str, Any]:
    """Loads a release definition either from a live ADO API call or a local
    JSON export (mirrors the --source-file-path convention used by
    gh actions-importer, so you can extract from the same audit output)."""
    if source_file:
        path = Path(source_file)
        if not path.exists():
            raise FileNotFoundError(f"Source file not found: {source_file}")
        return json.loads(path.read_text(encoding="utf-8"))

    if definition_id is None or ado_client is None:
        raise ValueError("Either --source-file or (--release-id with a configured ADO client) is required.")

    return ado_client.get_release_definition(definition_id)


def _extract_approvals(env: dict[str, Any], kind: str) -> ApprovalGroup | None:
    key = "preDeployApprovals" if kind == "pre" else "postDeployApprovals"
    block = env.get(key)
    if not block:
        return None

    approvals = block.get("approvals", [])
    approvers: list[Approver] = []
    for a in approvals:
        approver_info = a.get("approver") or {}
        # Skip the synthetic "automated" approver ADO inserts when no real
        # approval is configured — it has no displayName/uniqueName worth
        # tracking and would create noise in the reviewer-mapping template.
        if not approver_info.get("displayName") and not approver_info.get("uniqueName"):
            continue
        approvers.append(
            Approver(
                display_name=approver_info.get("displayName", "Unknown"),
                unique_name=approver_info.get("uniqueName"),
                is_required=not a.get("isAutomated", False),
            )
        )

    if not approvers:
        return None

    options = block.get("approvalOptions", {})
    return ApprovalGroup(
        kind=kind,
        approvers=approvers,
        approvals_required=options.get("requiredApproverCount") or len(approvers),
        timeout_minutes=options.get("timeoutInMinutes"),
    )


def _extract_gates(env: dict[str, Any], kind: str) -> list[Gate]:
    key = "preDeploymentGates" if kind == "pre" else "postDeploymentGates"
    block = env.get(key)
    if not block:
        return []

    gates_options = block.get("gatesOptions")
    if not gates_options or not gates_options.get("isEnabled", False):
        return []

    result: list[Gate] = []
    for g in block.get("gates", []):
        task = g.get("tasks", [{}])
        task0 = task[0] if task else {}
        task_ref = task0.get("task", {})
        result.append(
            Gate(
                name=g.get("name") or task_ref.get("name") or "unnamed-gate",
                kind=kind,
                task_type=task_ref.get("name"),
                raw_inputs=task0.get("inputs", {}),
            )
        )
    return result


def _extract_service_connections(env: dict[str, Any]) -> list[ServiceConnectionRef]:
    """
    Service connections show up as task inputs on deploy-phase steps, most
    commonly under keys like 'connectedServiceName', 'connectedServiceNameARM',
    'ConnectedServiceName', or 'azureSubscription' depending on task type.
    This scans all deploy-phase task inputs generically rather than
    hardcoding one key, since task authors are inconsistent about naming.
    """
    connection_input_keys = {
        "connectedServiceName",
        "connectedServiceNameARM",
        "ConnectedServiceName",
        "azureSubscription",
        "ConnectedServiceNameSelector",
        "serviceConnection",
    }

    found: dict[str, ServiceConnectionRef] = {}
    for phase in env.get("deployPhases", []):
        for step in phase.get("workflowTasks", []) or phase.get("deploymentInput", {}).get("workflowTasks", []) or []:
            inputs = step.get("inputs", {})
            for key in connection_input_keys:
                value = inputs.get(key)
                if value and isinstance(value, str):
                    found.setdefault(
                        value,
                        ServiceConnectionRef(id=value, name=None, connection_type=None),
                    )
    return list(found.values())


def _extract_variable_groups(definition: dict[str, Any], env: dict[str, Any]) -> list[VariableGroupRef]:
    ids: set[int] = set()
    for vg_id in definition.get("variableGroups", []) or []:
        ids.add(vg_id)
    for vg_id in env.get("variableGroups", []) or []:
        ids.add(vg_id)
    return [VariableGroupRef(id=vg_id) for vg_id in sorted(ids)]


def extract(raw_definition: dict[str, Any]) -> ReleaseDefinition:
    """Parses a raw ADO release definition JSON payload into a ReleaseDefinition
    focused on the constructs gh actions-importer does not convert."""
    stages: list[ReleaseStage] = []

    for env in raw_definition.get("environments", []):
        stage = ReleaseStage(
            name=env.get("name", "unnamed-stage"),
            rank=env.get("rank", 0),
            pre_approvals=_extract_approvals(env, "pre"),
            post_approvals=_extract_approvals(env, "post"),
            gates=_extract_gates(env, "pre") + _extract_gates(env, "post"),
            service_connections=_extract_service_connections(env),
            variable_groups=_extract_variable_groups(raw_definition, env),
        )
        stages.append(stage)

    stages.sort(key=lambda s: s.rank)

    return ReleaseDefinition(
        id=raw_definition.get("id", 0),
        name=raw_definition.get("name", "unknown"),
        project=raw_definition.get("projectReference", {}).get("name", ""),
        stages=stages,
    )
