#!/usr/bin/env python3
"""Compare an aligned KV-transfer summary with a cross-NUMA summary."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path


def load(path: Path) -> dict:
    with path.open() as stream:
        return json.load(stream)


def repetitions(summary_path: Path) -> list[tuple[str, dict]]:
    root = summary_path.parent / "repetitions"
    return [
        (path.parent.name, load(path))
        for path in sorted(root.glob("*/kv-summary.json"))
    ]


def optional_prometheus(summary_path: Path) -> dict | None:
    path = summary_path.parent / "prometheus-summary.json"
    return load(path) if path.exists() else None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("aligned", type=Path)
    parser.add_argument("cross_numa", type=Path)
    args = parser.parse_args()

    aligned = load(args.aligned)
    remote = load(args.cross_numa)
    latency_ratio = remote["avg_xfer_time_ms"] / aligned["avg_xfer_time_ms"]
    throughput_ratio = (
        aligned["aggregate_throughput_mb_s"]
        / remote["aggregate_throughput_mb_s"]
    )
    latency_reduction = 100 * (
        1 - aligned["avg_xfer_time_ms"] / remote["avg_xfer_time_ms"]
    )
    payload_delta = 100 * abs(
        aligned["avg_mb_per_transfer"] - remote["avg_mb_per_transfer"]
    ) / ((aligned["avg_mb_per_transfer"] + remote["avg_mb_per_transfer"]) / 2)

    print("# Aligned versus cross-NUMA KV transfer")
    print()
    print("| Placement | Transfers | Avg payload | Mean latency | Effective throughput |")
    print("|---|---:|---:|---:|---:|")
    for label, summary in (("Aligned", aligned), ("Cross-NUMA", remote)):
        print(
            f"| {label} | {summary['successful_transfers']} | "
            f"{summary['avg_mb_per_transfer']:.2f} MB | "
            f"{summary['avg_xfer_time_ms']:.3f} ms | "
            f"{summary['aggregate_throughput_mb_s']:.2f} MB/s |"
        )
    print()
    print(
        f"Aligned placement provided **{throughput_ratio:.2f}x effective "
        f"throughput** and **{latency_reduction:.1f}% lower mean transfer "
        f"latency**. Cross-NUMA latency was {latency_ratio:.2f}x aligned "
        f"latency. Average payload sizes differed by {payload_delta:.2f}%."
    )
    print()
    print(
        "Means are reconstructed from vLLM's periodic summaries using "
        "successful-transfer counts as weights. A run-wide P90 cannot be "
        "reconstructed from interval P90 values."
    )

    aligned_reps = repetitions(args.aligned)
    remote_reps = repetitions(args.cross_numa)
    if aligned_reps and len(aligned_reps) == len(remote_reps):
        print()
        print("## Per-repetition results")
        print()
        print("| Repetition | Placement | Transfers | Payload | Mean latency | Throughput |")
        print("|---:|---|---:|---:|---:|---:|")
        throughput_ratios = []
        latency_reductions = []
        for (aligned_id, aligned_rep), (remote_id, remote_rep) in zip(
            aligned_reps, remote_reps
        ):
            if aligned_id != remote_id:
                raise SystemExit(
                    f"error: repetition IDs do not match: {aligned_id}, {remote_id}"
                )
            for label, summary in (("Aligned", aligned_rep), ("Cross-NUMA", remote_rep)):
                print(
                    f"| {aligned_id} | {label} | {summary['successful_transfers']} | "
                    f"{summary['avg_mb_per_transfer']:.2f} MB | "
                    f"{summary['avg_xfer_time_ms']:.3f} ms | "
                    f"{summary['aggregate_throughput_mb_s']:.2f} MB/s |"
                )
            throughput_ratios.append(
                aligned_rep["aggregate_throughput_mb_s"]
                / remote_rep["aggregate_throughput_mb_s"]
            )
            latency_reductions.append(
                100 * (
                    1
                    - aligned_rep["avg_xfer_time_ms"]
                    / remote_rep["avg_xfer_time_ms"]
                )
            )
        print()
        print(
            f"Across {len(throughput_ratios)} paired repetitions, aligned "
            f"throughput improvement averaged **{statistics.mean(throughput_ratios):.2f}x** "
            f"(range {min(throughput_ratios):.2f}–{max(throughput_ratios):.2f}x), "
            f"and mean-latency reduction averaged "
            f"**{statistics.mean(latency_reductions):.1f}%** "
            f"(range {min(latency_reductions):.1f}–{max(latency_reductions):.1f}%)."
        )

    aligned_prom = optional_prometheus(args.aligned)
    remote_prom = optional_prometheus(args.cross_numa)
    if aligned_prom and remote_prom:
        prom_throughput_ratio = (
            aligned_prom["aggregate_throughput_mb_s"]
            / remote_prom["aggregate_throughput_mb_s"]
        )
        prom_latency_reduction = 100 * (
            1 - aligned_prom["avg_xfer_time_ms"] / remote_prom["avg_xfer_time_ms"]
        )
        print()
        print("## Prometheus cross-check")
        print()
        print("| Placement | Transfers | Mean latency | Throughput | Failed transfers |")
        print("|---|---:|---:|---:|---:|")
        for label, summary in (
            ("Aligned", aligned_prom),
            ("Cross-NUMA", remote_prom),
        ):
            print(
                f"| {label} | {summary['successful_transfers']} | "
                f"{summary['avg_xfer_time_ms']:.3f} ms | "
                f"{summary['aggregate_throughput_mb_s']:.2f} MB/s | "
                f"{summary['failed_transfers']} |"
            )
        print()
        print(
            f"The before/after NIXL histogram deltas independently show "
            f"**{prom_throughput_ratio:.2f}x effective throughput** and "
            f"**{prom_latency_reduction:.1f}% lower mean transfer latency** "
            f"for aligned placement."
        )


if __name__ == "__main__":
    main()
