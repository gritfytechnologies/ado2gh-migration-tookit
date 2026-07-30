from __future__ import annotations

import logging
from typing import Any

import requests

from .config import Config
from .rate_limit import RateLimiter, retry_with_backoff

logger = logging.getLogger("adogap")

API_VERSION = "7.1"


class AdoClient:
    """
    Thin wrapper over the Azure DevOps REST API, scoped to what adogap needs:
    reading release definitions, service connections, and variable groups.
    Read-only by design — adogap never writes back to Azure DevOps.
    """

    def __init__(self, config: Config, rate_limiter: RateLimiter | None = None):
        self.config = config
        self.rate_limiter = rate_limiter or RateLimiter(config.min_request_interval_seconds)
        self.session = requests.Session()
        self.session.auth = ("", config.ado_pat)  # PAT goes in the password field, empty username
        self.base_url = f"{config.ado_instance_url.rstrip('/')}/{config.ado_organization}/{config.ado_project}"

    def _get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        url = f"{self.base_url}/{path.lstrip('/')}"
        merged_params = {"api-version": API_VERSION}
        if params:
            merged_params.update(params)

        def do_request() -> dict[str, Any]:
            resp = self.session.get(url, params=merged_params, timeout=30)
            resp.raise_for_status()
            return resp.json()

        return retry_with_backoff(
            do_request,
            max_retries=self.config.max_retries,
            initial_backoff_seconds=self.config.initial_backoff_seconds,
            operation_name=f"GET {path}",
            rate_limiter=self.rate_limiter,
        )

    def get_release_definition(self, definition_id: int) -> dict[str, Any]:
        """
        Fetches a single classic release definition, expanded to include
        environments (stages), approvals, gates, and deploy phases/tasks.
        """
        return self._get(
            f"_apis/release/definitions/{definition_id}",
            params={"$expand": "environments"},
        )

    def list_release_definitions(self) -> list[dict[str, Any]]:
        """Lists all release definitions in the configured project (summary only)."""
        result = self._get("_apis/release/definitions")
        return result.get("value", [])

    def get_service_connection(self, connection_id: str) -> dict[str, Any]:
        return self._get(f"_apis/serviceendpoint/endpoints/{connection_id}")

    def get_variable_group(self, group_id: int) -> dict[str, Any]:
        return self._get(f"_apis/distributedtask/variablegroups/{group_id}")

    def get_build_definition(self, definition_id: int) -> dict[str, Any]:
        """Included for parity with build pipelines, in case adogap's checks
        are later extended to cover build-side service connection usage too."""
        return self._get(f"_apis/build/definitions/{definition_id}")
