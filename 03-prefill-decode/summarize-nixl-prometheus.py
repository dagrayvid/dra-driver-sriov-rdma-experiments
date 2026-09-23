#!/usr/bin/env python3
"""Summarize the delta between before/after vLLM NIXL metrics snapshots."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import defaultdict
from pathlib import Path


SAMPLE = re.compile(
    r"^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(?P<labels>.*)\})?\s+"
    r"(?P<value>[-+0-9.eE]+|NaN|[+-]Inf)(?:\s+\d+)?$"
)
LE = re.compile(r'(?:^|,)\s*le="(?P<le>[^"]+)"(?:,|$)')


def parse(path: Path) -> tuple[dict[str, float], dict[str, dict[float, float]]]:
    scalars: dict[str, float] = defaultdict(float)
    buckets: dict[str, dict[float, float]] = defaultdict(lambda: defaultdict(float))
    for raw in path.read_text(errors="replace").splitlines():
        if not raw or raw.startswith("#"):
            continue
        match = SAMPLE.match(raw)
        if not match:
            continue
        value = float(match.group("value"))
        if not math.isfinite(value):
            continue
        name = match.group("name")
        labels = match.group("labels") or ""
        if name.endswith("_bucket"):
            le_match = LE.search(labels)
            if le_match:
                upper = float(le_match.group("le").replace("+Inf", "inf"))
                buckets[name][upper] += value
        else:
            scalars[name] += value
    return dict(scalars), {name: dict(values) for name, values in buckets.items()}


def delta(after: dict[str, float], before: dict[str, float], *names: str) -> float:
    for name in names:
        if name in after or name in before:
            return after.get(name, 0.0) - before.get(name, 0.0)
    return 0.0


def histogram(
    before_scalars: dict[str, float], before_buckets: dict[str, dict[float, float]],
    after_scalars: dict[str, float], after_buckets: dict[str, dict[float, float]],
    base: str,
) -> dict:
    count = delta(after_scalars, before_scalars, base + "_count")
    total = delta(after_scalars, before_scalars, base + "_sum")
    bucket_name = base + "_bucket"
    bucket_delta = {
        upper: value - before_buckets.get(bucket_name, {}).get(upper, 0.0)
        for upper, value in after_buckets.get(bucket_name, {}).items()
    }
    p90_upper = None
    if count > 0:
        threshold = count * 0.9
        for upper in sorted(bucket_delta):
            if bucket_delta[upper] >= threshold:
                p90_upper = upper
                break
    return {
        "count": int(round(count)),
        "sum": total,
        "mean": total / count if count > 0 else None,
        "p90_histogram_upper_bound": p90_upper,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    args = parser.parse_args()

    before_scalars, before_buckets = parse(args.before)
    after_scalars, after_buckets = parse(args.after)
    prefix = "vllm:nixl_"
    xfer = histogram(
        before_scalars, before_buckets, after_scalars, after_buckets,
        prefix + "xfer_time_seconds",
    )
    if xfer["count"] <= 0:
        raise SystemExit("error: no NIXL transfer histogram observations in snapshot delta")
    post = histogram(
        before_scalars, before_buckets, after_scalars, after_buckets,
        prefix + "post_time_seconds",
    )
    bytes_moved = histogram(
        before_scalars, before_buckets, after_scalars, after_buckets,
        prefix + "bytes_transferred",
    )
    descriptors = histogram(
        before_scalars, before_buckets, after_scalars, after_buckets,
        prefix + "num_descriptors",
    )
    failed = delta(
        after_scalars, before_scalars,
        prefix + "num_failed_transfers_total",
        prefix + "num_failed_transfers",
    )
    failed_notifications = delta(
        after_scalars, before_scalars,
        prefix + "num_failed_notifications_total",
        prefix + "num_failed_notifications",
    )
    summary = {
        "schema_version": 1,
        "unit_note": (
            "Byte histograms are converted with 2^20 bytes per reported MB "
            "to match vLLM's periodic KV Transfer log values."
        ),
        "successful_transfers": xfer["count"],
        "avg_xfer_time_ms": xfer["mean"] * 1000,
        "xfer_time_p90_histogram_upper_bound_ms": (
            xfer["p90_histogram_upper_bound"] * 1000
            if xfer["p90_histogram_upper_bound"] is not None
            and math.isfinite(xfer["p90_histogram_upper_bound"])
            else None
        ),
        "avg_post_time_ms": post["mean"] * 1000 if post["mean"] is not None else None,
        "avg_mb_per_transfer": (
            bytes_moved["mean"] / (1024 * 1024)
            if bytes_moved["mean"] is not None else None
        ),
        "avg_descriptors": descriptors["mean"],
        "aggregate_throughput_mb_s": (
            bytes_moved["sum"] / (1024 * 1024) / xfer["sum"]
            if xfer["sum"] > 0 else None
        ),
        "failed_transfers": int(round(failed)),
        "failed_notifications": int(round(failed_notifications)),
        "p90_warning": (
            "Histogram P90 is reported as a bucket upper bound, not an exact quantile."
        ),
    }
    json.dump(summary, fp=sys.stdout, indent=2, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
