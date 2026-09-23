#!/usr/bin/env python3
"""Summarize ib_write_bw --report_gbits client output."""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path


def parse(path: Path, message_size: int, iterations: int) -> list[float]:
    values = []
    for raw in path.read_text(errors="replace").splitlines():
        fields = raw.split()
        if len(fields) < 4:
            continue
        try:
            size = int(fields[0])
            count = int(fields[1])
            average_gbps = float(fields[3])
        except ValueError:
            continue
        if size == message_size and count == iterations:
            values.append(average_gbps)
    return values


def summarize(values: list[float]) -> dict:
    mean = statistics.mean(values)
    stdev = statistics.stdev(values) if len(values) > 1 else 0.0
    return {
        "schema_version": 1,
        "runs": len(values),
        "bandwidth_gbit_s": {
            "mean": mean,
            "median": statistics.median(values),
            "sample_stdev": stdev,
            "coefficient_of_variation_percent": 100 * stdev / mean if mean else None,
            "min": min(values),
            "max": max(values),
            "values": values,
        },
    }


def markdown(summary: dict, label: str) -> str:
    bw = summary["bandwidth_gbit_s"]
    return "\n".join([
        f"# ib_write_bw summary: {label}",
        "",
        "| Metric | Value |",
        "|---|---:|",
        f"| Independent runs | {summary['runs']} |",
        f"| Mean bandwidth | {bw['mean']:.3f} Gbit/s |",
        f"| Median bandwidth | {bw['median']:.3f} Gbit/s |",
        f"| Sample standard deviation | {bw['sample_stdev']:.3f} Gbit/s |",
        f"| Coefficient of variation | {bw['coefficient_of_variation_percent']:.3f}% |",
        f"| Minimum | {bw['min']:.3f} Gbit/s |",
        f"| Maximum | {bw['max']:.3f} Gbit/s |",
        "",
        "Individual runs: " + ", ".join(f"{value:.3f}" for value in bw["values"]) + " Gbit/s.",
    ])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--message-size", type=int, default=8388608)
    parser.add_argument("--iterations", type=int, default=5000)
    parser.add_argument("--expected-runs", type=int, default=10)
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    parser.add_argument("--label", default="run")
    args = parser.parse_args()

    values = parse(args.input, args.message_size, args.iterations)
    if len(values) != args.expected_runs:
        raise SystemExit(
            f"error: expected {args.expected_runs} result rows, found {len(values)}"
        )
    result = summarize(values)
    if args.format == "markdown":
        print(markdown(result, args.label))
    else:
        json.dump(result, sys.stdout, indent=2, sort_keys=True)
        print()


if __name__ == "__main__":
    main()
