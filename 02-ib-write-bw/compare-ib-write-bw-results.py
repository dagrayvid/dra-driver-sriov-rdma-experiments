#!/usr/bin/env python3
"""Compare placement classes for one or both ib_write_bw directions."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("aligned", type=Path)
    parser.add_argument("same_numa", type=Path)
    parser.add_argument("cross_numa", type=Path)
    parser.add_argument("--aligned-reverse", type=Path)
    parser.add_argument("--same-numa-reverse", type=Path)
    parser.add_argument("--cross-numa-reverse", type=Path)
    args = parser.parse_args()

    reverse_paths = (
        args.aligned_reverse,
        args.same_numa_reverse,
        args.cross_numa_reverse,
    )
    if any(reverse_paths) and not all(reverse_paths):
        parser.error("all three --*-reverse summaries must be supplied together")

    rows = [
        ("Aligned", load(args.aligned)),
        ("Different root, same NUMA", load(args.same_numa)),
        ("Cross NUMA", load(args.cross_numa)),
    ]
    aligned_mean = rows[0][1]["bandwidth_gbit_s"]["mean"]

    if all(reverse_paths):
        reverse_rows = [
            ("Aligned", load(args.aligned_reverse)),
            ("Different root, same NUMA", load(args.same_numa_reverse)),
            ("Cross NUMA", load(args.cross_numa_reverse)),
        ]
        print("# GPUDirect RDMA WRITE bandwidth by GPU/NIC placement")
        print()
        print(
            "| Placement | Forward mean | Reverse mean | "
            "Reverse vs. forward | Direction-balanced mean |"
        )
        print("|---|---:|---:|---:|---:|")
        for (label, forward), (_, reverse) in zip(rows, reverse_rows):
            fmean = forward["bandwidth_gbit_s"]["mean"]
            rmean = reverse["bandwidth_gbit_s"]["mean"]
            print(
                f"| {label} | {fmean:.3f} Gbit/s | {rmean:.3f} Gbit/s | "
                f"{100 * (rmean / fmean - 1):+.1f}% | "
                f"{(fmean + rmean) / 2:.3f} Gbit/s |"
            )
        print()
        for direction, direction_rows in (
            ("Forward", rows),
            ("Reverse", reverse_rows),
        ):
            baseline = direction_rows[0][1]["bandwidth_gbit_s"]["mean"]
            same = direction_rows[1][1]["bandwidth_gbit_s"]["mean"]
            cross = direction_rows[2][1]["bandwidth_gbit_s"]["mean"]
            print(
                f"{direction}: aligned was **{baseline / same:.2f}x** same-NUMA "
                f"misaligned and **{baseline / cross:.2f}x** cross-NUMA misaligned."
            )
        return

    print("# GPUDirect RDMA WRITE bandwidth by GPU/NIC placement")
    print()
    print("| Placement | Runs | Mean | Median | Std. dev. | CV | Range |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for label, result in rows:
        bw = result["bandwidth_gbit_s"]
        print(
            f"| {label} | {result['runs']} | {bw['mean']:.3f} Gbit/s | "
            f"{bw['median']:.3f} Gbit/s | {bw['sample_stdev']:.3f} Gbit/s | "
            f"{bw['coefficient_of_variation_percent']:.3f}% | "
            f"{bw['min']:.3f}–{bw['max']:.3f} Gbit/s |"
        )

    print()
    for label, result in rows[1:]:
        mean = result["bandwidth_gbit_s"]["mean"]
        print(
            f"Aligned bandwidth was **{aligned_mean / mean:.2f}x** {label.lower()} "
            f"bandwidth ({100 * (aligned_mean / mean - 1):.1f}% higher)."
        )


if __name__ == "__main__":
    main()
