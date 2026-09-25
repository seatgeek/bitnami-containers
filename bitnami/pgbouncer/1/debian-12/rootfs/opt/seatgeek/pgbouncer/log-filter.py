#!/usr/bin/env python3
"""Normalize process-compose JSON log lines for the PgBouncer sidecar."""

import json
import re
import sys

# CSI SGR and related ANSI/VT100 control sequences.
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\].*?(?:\x1b\\|\x07)")

# Bitnami liblog.sh: "pgbouncer 02:55:37.38 INFO \x1b[0m ==> ** Starting ... **"
BITNAMI_RE = re.compile(
    r"^pgbouncer \d{2}:\d{2}:\d{2}\.\d{2}\s+"
    r"(INFO|WARN|WARNING|ERROR|DEBUG|TRACE)\s+"
    r"(?:\x1b\[[0-9;]*m\s*)?"
    r"(?:==>\s*)?"
    r"(.*)$",
    re.IGNORECASE,
)

# PgBouncer server log: "2026-09-09 02:55:39.402 UTC [419] LOG listening on ..."
PGBOUNCER_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ UTC \[\d+\] "
    r"(LOG|WARNING|ERROR|FATAL|PANIC) "
    r"(.*)$",
)


def normalize_level(level: str) -> str:
    level = level.upper()
    if level in ("WARN", "WARNING"):
        return "warn"
    if level == "LOG":
        return "info"
    if level in ("FATAL", "PANIC"):
        return "error"
    return level.lower()


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text).strip()


def refine_message(message: str):
    message = strip_ansi(message)

    match = BITNAMI_RE.match(message)
    if match:
        return normalize_level(match.group(1)), match.group(2).strip()

    match = PGBOUNCER_RE.match(message)
    if match:
        return normalize_level(match.group(1)), match.group(2).strip()

    return None, message


def emit(record: dict) -> None:
    payload = {key: record[key] for key in ("time", "level", "process", "message") if key in record}
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main() -> None:
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue

        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
            continue

        record.pop("replica", None)

        message = record.get("message", "")
        if isinstance(message, str):
            detected_level, cleaned = refine_message(message)
            record["message"] = cleaned
            if detected_level:
                record["level"] = detected_level

        emit(record)


if __name__ == "__main__":
    main()
