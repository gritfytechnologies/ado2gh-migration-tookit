from __future__ import annotations

import logging
import random
import threading
import time
from typing import Callable, TypeVar

import requests

logger = logging.getLogger("adogap")

T = TypeVar("T")

# Known signatures for throttling that doesn't come back as a clean HTTP
# status code (ADO in particular returns 200/203 with an error payload for
# some soft-throttling scenarios).
_RATE_LIMIT_TEXT_SIGNATURES = (
    "TF400733",
    "rate limit",
    "RateLimitExceeded",
    "secondary rate limit",
    "abuse detection",
)


class RateLimiter:
    """
    Thread-safe floor-spacing limiter: guarantees a minimum interval between
    any two calls made through it, regardless of how many worker threads are
    calling concurrently. This is a floor, not the primary defense — the
    primary defense is retry_with_backoff reacting to actual 429s / Retry-After
    headers / known throttle signatures.
    """

    def __init__(self, min_interval_seconds: float = 1.0):
        self.min_interval_seconds = min_interval_seconds
        self._lock = threading.Lock()
        self._last_call: float = 0.0

    def wait(self) -> None:
        with self._lock:
            now = time.monotonic()
            elapsed = now - self._last_call
            if elapsed < self.min_interval_seconds:
                time.sleep(self.min_interval_seconds - elapsed)
            self._last_call = time.monotonic()


def _looks_like_rate_limit(exc: Exception, response_text: str | None) -> tuple[bool, float | None]:
    """Returns (is_rate_limited, retry_after_seconds_if_known)."""
    if isinstance(exc, requests.HTTPError) and exc.response is not None:
        resp = exc.response
        if resp.status_code in (429, 403, 503):
            retry_after = resp.headers.get("Retry-After")
            retry_after_seconds = float(retry_after) if retry_after and retry_after.isdigit() else None
            return True, retry_after_seconds

    if response_text:
        for sig in _RATE_LIMIT_TEXT_SIGNATURES:
            if sig.lower() in response_text.lower():
                return True, None

    return False, None


def retry_with_backoff(
    fn: Callable[[], T],
    *,
    max_retries: int = 5,
    initial_backoff_seconds: float = 10.0,
    operation_name: str = "operation",
    rate_limiter: RateLimiter | None = None,
) -> T:
    """
    Runs fn() with exponential backoff + full jitter on failure, capped at
    5 minutes per wait. Honors Retry-After when the server provides one.
    Re-raises the last exception after max_retries is exhausted.
    """
    attempt = 0
    last_exc: Exception | None = None

    while attempt < max_retries:
        attempt += 1
        if rate_limiter:
            rate_limiter.wait()

        try:
            return fn()
        except Exception as exc:  # noqa: BLE001 - intentionally broad, this is a generic retry wrapper
            last_exc = exc
            response_text = None
            if isinstance(exc, requests.HTTPError) and exc.response is not None:
                response_text = exc.response.text

            is_rate_limited, retry_after = _looks_like_rate_limit(exc, response_text)

            if attempt >= max_retries:
                logger.error("'%s' failed after %d attempts: %s", operation_name, attempt, exc)
                raise

            if retry_after is not None:
                sleep_seconds = retry_after
            else:
                base = initial_backoff_seconds * (2 ** (attempt - 1))
                jitter = random.uniform(0, base * 0.5)
                sleep_seconds = min(300.0, base + jitter)

            level = logging.WARNING if is_rate_limited else logging.WARNING
            logger.log(
                level,
                "'%s' attempt %d/%d failed (%s: %s). Retrying in %.1fs...",
                operation_name,
                attempt,
                max_retries,
                type(exc).__name__,
                exc,
                sleep_seconds,
            )
            time.sleep(sleep_seconds)

    # Unreachable in practice, but keeps type checkers happy
    assert last_exc is not None
    raise last_exc
