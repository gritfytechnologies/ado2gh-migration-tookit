from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv


class ConfigError(Exception):
    """Raised when required configuration is missing or invalid."""


@dataclass(frozen=True)
class Config:
    ado_organization: str
    ado_project: str
    ado_pat: str
    ado_instance_url: str

    github_org: str | None
    github_instance_url: str

    max_retries: int
    initial_backoff_seconds: float
    max_concurrency: int
    min_request_interval_seconds: float

    @classmethod
    def from_env(cls, env_file: str | None = None) -> "Config":
        """
        Loads configuration from environment variables, optionally after
        loading a .env-style file first (does not override variables already
        set in the real environment, matching standard dotenv precedence).
        """
        if env_file and Path(env_file).exists():
            load_dotenv(env_file, override=False)
        else:
            # Best-effort: pick up a .env in the current working directory
            load_dotenv(override=False)

        missing: list[str] = []

        def require(name: str) -> str:
            value = os.environ.get(name, "").strip()
            if not value:
                missing.append(name)
            return value

        ado_org = require("ADO_ORGANIZATION")
        ado_project = require("ADO_PROJECT")
        ado_pat = require("ADO_PAT")
        ado_instance_url = os.environ.get("ADO_INSTANCE_URL", "https://dev.azure.com").strip()

        github_org = os.environ.get("GITHUB_ORG", "").strip() or None
        github_instance_url = os.environ.get("GITHUB_INSTANCE_URL", "https://github.com").strip()

        if missing:
            raise ConfigError(
                "Missing required environment variable(s): "
                + ", ".join(missing)
                + ". Copy .env.example to .env and fill in real values, "
                "or export them in your shell."
            )

        def _int(name: str, default: int) -> int:
            raw = os.environ.get(name)
            return int(raw) if raw else default

        def _float(name: str, default: float) -> float:
            raw = os.environ.get(name)
            return float(raw) if raw else default

        return cls(
            ado_organization=ado_org,
            ado_project=ado_project,
            ado_pat=ado_pat,
            ado_instance_url=ado_instance_url,
            github_org=github_org,
            github_instance_url=github_instance_url,
            max_retries=_int("ADOGAP_MAX_RETRIES", 5),
            initial_backoff_seconds=_float("ADOGAP_INITIAL_BACKOFF_SECONDS", 10.0),
            max_concurrency=_int("ADOGAP_MAX_CONCURRENCY", 3),
            min_request_interval_seconds=_float("ADOGAP_MIN_REQUEST_INTERVAL_SECONDS", 1.0),
        )
