"""Structured JSON logging, shared by every component.

Fargate ships stdout straight to CloudWatch Logs, so JSON on stdout is the cheapest path to
queryable logs — no sidecar, no agent. Sharing one configuration means a Log Insights query can
filter on ``index_version`` across the API and the ingestion job without accounting for two
different log shapes.
"""

from __future__ import annotations

import logging
import sys

import structlog


def configure_logging(level: str = "INFO") -> None:
    """Configure structlog to emit one JSON object per line on stdout."""
    numeric_level = logging.getLevelNamesMapping().get(level.upper(), logging.INFO)

    logging.basicConfig(format="%(message)s", stream=sys.stdout, level=numeric_level, force=True)

    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso", utc=True),
            structlog.processors.StackInfoRenderer(),
            structlog.processors.format_exc_info,
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(numeric_level),
        logger_factory=structlog.PrintLoggerFactory(file=sys.stdout),
        cache_logger_on_first_use=True,
    )
