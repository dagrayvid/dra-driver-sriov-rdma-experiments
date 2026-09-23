#!/usr/bin/env python3
"""Aggregate vLLM KV Transfer interval summaries.

Interval averages are weighted by ``Num successful transfers``. Reported
interval P90s are retained only as descriptive interval statistics; they
cannot be combined into a valid run-wide transfer percentile.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from pathlib import Path
from typing import TextIO


PATTERNS = {
    "count": r"Num successful transfers=(\d+)",
    "xfer_ms": r"Avg xfer time \(ms\)=([0-9.]+)",
    "p90_xfer_ms": r"P90 xfer time \(ms\)=([0-9.]+)",
    "post_ms": r"Avg post time \(ms\)=([0-9.]+)",
    "p90_post_ms": r"P90 post time \(ms\)=([0-9.]+)",
    "mb": r"Avg MB per transfer=([0-9.]+)",
    "throughput": r"Throughput \(MB/s\)=([0-9.]+)",
    "descriptors": r"Avg number of descriptors=([0-9.]+)",
}
TIMESTAMP = re.compile(r"INFO (\d\d-\d\d \d\d:\d\d:\d\d)")


def extract(line: str, pattern: str, cast: type = float):
    match = re.search(pattern, line)
    return cast(match.group(1)) if match else None


def parse(stream: TextIO) -> list[dict[str, float | int | str | None]]:
    rows = []
    for line in stream:
        if "KV Transfer metrics:" not in line:
            continue
        row = {
            name: extract(line, pattern, int if name == "count" else float)
            for name, pattern in PATTERNS.items()
        }
        if not all(value is not None for value in row.values()):
            continue
        timestamp = TIMESTAMP.search(line)
        row["timestamp"] = timestamp.group(1) if timestamp else None
        rows.append(row)
    return rows


def summarize(rows: list[dict[str, float | int | str | None]]) -> dict:
    if not rows:
        raise ValueError("no complete KV Transfer metric records found")

    transfers = sum(int(row["count"]) for row in rows)

    def weighted_mean(field: str) -> float:
        return sum(int(row["count"]) * float(row[field]) for row in rows) / transfers

    total_mb = sum(int(row["count"]) * float(row["mb"]) for row in rows)
    total_xfer_ms = sum(
        int(row["count"]) * float(row["xfer_ms"]) for row in rows
    )
    interval_means = [float(row["xfer_ms"]) for row in rows]
    timestamps = [str(row["timestamp"]) for row in rows if row["timestamp"]]

    return {
        "schema_version": 1,
        "first_metric_timestamp": timestamps[0] if timestamps else None,
        "last_metric_timestamp": timestamps[-1] if timestamps else None,
        "intervals": len(rows),
        "successful_transfers": transfers,
        "avg_xfer_time_ms": weighted_mean("xfer_ms"),
        "avg_post_time_ms": weighted_mean("post_ms"),
        "avg_mb_per_transfer": weighted_mean("mb"),
        "aggregate_throughput_mb_s": total_mb / (total_xfer_ms / 1000),
        "avg_descriptors": weighted_mean("descriptors"),
        "interval_avg_xfer_time_ms": {
            "min": min(interval_means),
            "median": statistics.median(interval_means),
            "max": max(interval_means),
        },
        "weighted_avg_reported_interval_p90_xfer_ms": weighted_mean(
            "p90_xfer_ms"
        ),
        "percentile_warning": (
            "The weighted average of reported interval P90s is descriptive only; "
            "it is not a run-wide P90."
        ),
    }


def markdown(summary: dict, label: str) -> str:
    return "\n".join([
        f"# KV-transfer summary: {label}",
        "",
        "| Metric | Value |",
        "|---|---:|",
        f"| Complete metric intervals | {summary['intervals']} |",
        f"| Successful transfers | {summary['successful_transfers']} |",
        f"| Average payload | {summary['avg_mb_per_transfer']:.2f} MB |",
        f"| Transfer-count-weighted mean latency | {summary['avg_xfer_time_ms']:.3f} ms |",
        f"| Aggregate effective throughput | {summary['aggregate_throughput_mb_s']:.2f} MB/s |",
        f"| Transfer-count-weighted post time | {summary['avg_post_time_ms']:.3f} ms |",
        f"| Median interval mean latency | {summary['interval_avg_xfer_time_ms']['median']:.3f} ms |",
        f"| Weighted average of reported interval P90s* | {summary['weighted_avg_reported_interval_p90_xfer_ms']:.3f} ms |",
        "",
        f"Metric interval: `{summary['first_metric_timestamp']}` through "
        f"`{summary['last_metric_timestamp']}`.",
        "",
        f"\* {summary['percentile_warning']}",
    ])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "input", nargs="?", type=Path,
        help="log file to parse; reads stdin when omitted",
    )
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    parser.add_argument("--label", default="run")
    args = parser.parse_args()

    if args.input:
        with args.input.open(encoding="utf-8", errors="replace") as stream:
            rows = parse(stream)
    else:
        rows = parse(sys.stdin)

    try:
        summary = summarize(rows)
    except ValueError as exc:
        raise SystemExit(f"error: {exc}") from exc

    if args.format == "markdown":
        print(markdown(summary, args.label))
    else:
        json.dump(summary, sys.stdout, indent=2, sort_keys=True)
        print()


if __name__ == "__main__":
    main()
