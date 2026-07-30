from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class Approver:
    display_name: str
    unique_name: str | None  # typically an email/UPN in ADO; used for the reviewer-mapping template
    is_required: bool = True


@dataclass
class ApprovalGroup:
    kind: str  # "pre" or "post"
    approvers: list[Approver] = field(default_factory=list)
    approvals_required: int = 1  # how many of the approvers must approve
    timeout_minutes: int | None = None


@dataclass
class Gate:
    name: str
    kind: str  # "pre" or "post"
    task_type: str | None = None  # e.g. "InvokeRESTAPI", "AzureFunction", "AzureMonitor"
    raw_inputs: dict[str, Any] = field(default_factory=dict)


@dataclass
class ServiceConnectionRef:
    id: str
    name: str | None = None
    connection_type: str | None = None  # e.g. "AzureRM", "GitHub", "generic"


@dataclass
class VariableGroupRef:
    id: int
    name: str | None = None


@dataclass
class ReleaseStage:
    name: str
    rank: int
    pre_approvals: ApprovalGroup | None = None
    post_approvals: ApprovalGroup | None = None
    gates: list[Gate] = field(default_factory=list)
    service_connections: list[ServiceConnectionRef] = field(default_factory=list)
    variable_groups: list[VariableGroupRef] = field(default_factory=list)

    @property
    def has_manual_constructs(self) -> bool:
        return bool(
            (self.pre_approvals and self.pre_approvals.approvers)
            or (self.post_approvals and self.post_approvals.approvers)
            or self.gates
            or self.service_connections
            or self.variable_groups
        )


@dataclass
class ReleaseDefinition:
    id: int
    name: str
    project: str
    stages: list[ReleaseStage] = field(default_factory=list)

    def summary_counts(self) -> dict[str, int]:
        approvals = sum(
            (len(s.pre_approvals.approvers) if s.pre_approvals else 0)
            + (len(s.post_approvals.approvers) if s.post_approvals else 0)
            for s in self.stages
        )
        gates = sum(len(s.gates) for s in self.stages)
        service_connections = len({sc.id for s in self.stages for sc in s.service_connections})
        variable_groups = len({vg.id for s in self.stages for vg in s.variable_groups})
        return {
            "stages": len(self.stages),
            "approvals": approvals,
            "gates": gates,
            "service_connections": service_connections,
            "variable_groups": variable_groups,
        }
