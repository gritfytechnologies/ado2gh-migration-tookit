"""
adogap — Azure DevOps classic release pipeline gap-filler toolkit.

Companion to `gh actions-importer`. The importer converts the mechanical
structure of a release pipeline (stages -> jobs, tasks -> actions). It does
NOT convert approvals, deployment gates, service connections, or variable
group secret values — these are dropped with a note in the PR description.

adogap fills that gap in three steps:
    1. extract  — parse the source ADO release definition and pull out every
                  approval, gate, service connection, and variable group
                  reference, per stage.
    2. scaffold — generate ready-to-apply GitHub Environment configuration,
                  OIDC federated credential definitions, and a reviewer
                  identity-mapping template from what was extracted.
    3. verify   — diff the extraction against the workflow YAML that
                  gh actions-importer produced, and flag anything that was
                  silently dropped (most commonly: every approval and gate,
                  since the importer does not create Environment protection
                  rules on its own).
"""

__version__ = "1.0.0"
