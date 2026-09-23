# TP1 KV-transfer benchmark: cross-numa

This directory is a raw and derived result bundle produced by
`run-tp1-kv-benchmark.sh`.

## Workload

- Concurrency: 10
- Prompt tokens: 16000 (fixed)
- Output tokens: 64 (fixed)
- Requests: 128 per repetition
- Repetitions: 3

## Combined result

| Metric | Value |
|---|---:|
| Complete metric intervals | 151 |
| Successful transfers | 384 |
| Average payload | 1175.81 MB |
| Transfer-count-weighted mean latency | 122.319 ms |
| Aggregate effective throughput | 9612.64 MB/s |
| Transfer-count-weighted post time | 1.386 ms |
| Median interval mean latency | 122.483 ms |
| Weighted average of reported interval P90s* | 128.475 ms |

Metric interval: `09-18 20:58:54` through `09-18 21:25:05`.

\* The weighted average of reported interval P90s is descriptive only; it is not a run-wide P90.

See `allocation.md`, `topology-prefill.txt`, and
`topology-decode.txt` for allocation evidence. Per-repetition raw logs,
GuideLLM output, and summaries are under `repetitions/`.
The node contention audit is in `competing-workloads.txt`; exact copies
of the collection and parsing tools are under `collection-tools/`.

A before/after NIXL histogram delta is available in
`prometheus-summary.json` as an independent check of the log summary.
