from __future__ import annotations

import json
import logging
import sys
import threading
import time
from pathlib import Path

_log_lock = threading.Lock()


class JsonLinesHandler(logging.Handler):
    """
    Thread-safe JSON-lines log handler. Separate from the human-readable
    console/file handler so downstream tooling (Splunk/ELK/Sentinel) can
    ingest structured events without regex-parsing free text.
    """

    def __init__(self, path: Path):
        super().__init__()
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def emit(self, record: logging.LogRecord) -> None:
        entry = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(record.created)),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        extra = getattr(record, "extra_fields", None)
        if extra:
            entry.update(extra)
        with _log_lock:
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(json.dumps(entry) + "\n")


def setup_logging(output_dir: Path, run_id: str, verbose: bool = False) -> logging.Logger:
    logger = logging.getLogger("adogap")
    logger.setLevel(logging.DEBUG if verbose else logging.INFO)
    logger.handlers.clear()

    log_dir = output_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)

    fmt = logging.Formatter("[%(asctime)s] [%(levelname)s] %(message)s", "%Y-%m-%d %H:%M:%S")

    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(fmt)
    logger.addHandler(console)

    file_handler = logging.FileHandler(log_dir / f"adogap-{run_id}.log", encoding="utf-8")
    file_handler.setFormatter(fmt)
    logger.addHandler(file_handler)

    json_handler = JsonLinesHandler(log_dir / f"adogap-{run_id}.jsonl")
    logger.addHandler(json_handler)

    return logger


def log_extra(logger: logging.Logger, level: int, message: str, **fields) -> None:
    """Log a message with structured fields attached for the JSON-lines handler."""
    logger.log(level, message, extra={"extra_fields": fields})
