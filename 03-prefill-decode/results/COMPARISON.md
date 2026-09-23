# TP1 aligned versus cross-NUMA KV transfer

## Result

| Placement | Transfers | Average payload | Mean latency | Effective throughput |
|---|---:|---:|---:|---:|
| Aligned | 384 | 1175.81 MB | 56.776 ms | 20709.67 MB/s |
| Cross-NUMA | 384 | 1175.81 MB | 122.319 ms | 9612.64 MB/s |

Aligned GPU/NIC placement provided **2.15x effective KV-transfer throughput**
and **53.6% lower mean transfer latency**. Cross-NUMA placement added 65.543 ms
to the mean transfer time. Payload size was identical between placements.

## Per-repetition repeatability

| Repetition | Placement | Transfers | Mean latency | Throughput |
|---:|---|---:|---:|---:|
| 1 | Aligned | 128 | 56.781 ms | 20707.88 MB/s |
| 1 | Cross-NUMA | 128 | 123.001 ms | 9559.39 MB/s |
| 2 | Aligned | 128 | 56.753 ms | 20717.96 MB/s |
| 2 | Cross-NUMA | 128 | 121.541 ms | 9674.21 MB/s |
| 3 | Aligned | 128 | 56.794 ms | 20703.16 MB/s |
| 3 | Cross-NUMA | 128 | 122.417 ms | 9605.00 MB/s |

Across the three paired repetitions, aligned throughput improvement ranged
from **2.14x to 2.17x** and mean-latency reduction ranged from **53.3% to
53.8%**.

## Prometheus cross-check

| Placement | Transfers | Mean latency | Throughput | Failed transfers | Failed notifications |
|---|---:|---:|---:|---:|---:|
| Aligned | 384 | 56.776 ms | 20709.69 MB/s | 0 | 0 |
| Cross-NUMA | 384 | 122.319 ms | 9612.64 MB/s | 0 | 0 |

The before/after NIXL Prometheus histogram deltas independently reproduce the
log-derived mean latency and throughput. The Prometheus transfer-time P90
histogram bucket upper bounds were 75 ms aligned and 200 ms cross-NUMA; these
are bucket bounds, not exact quantiles.

## Experiment controls and evidence

- Model: Qwen3.8-27B with one TP1 prefill pod and one TP1 decode pod.
- Workload: concurrency 10, 128 requests per repetition, target 16,000 input
  tokens and 64 output tokens, three repetitions per placement.
- Actual prompt lengths were 16,051–16,052 tokens after chat templating.
- Repetitions used paired deterministic seeds 42001, 42002, and 42003. The
  serialized request sets matched exactly between placements.
- All 768 GuideLLM requests succeeded: 384 aligned and 384 cross-NUMA, with no
  errored or incomplete requests.
- NIXL transferred the same 1175.81 MB payload with the same 32,976 average
  descriptors per request in both placements.
- The node audit found no other active GPU- or DRA-consuming pods during
  either experiment.
- [Aligned allocation](aligned/allocation.md): both prefill and decode used a
  GPU and VF under `pci0000:00` / NUMA 0.
- [Cross-NUMA allocation](cross-numa/allocation.md): both used a GPU under
  `pci0000:00` / NUMA 0 and a VF under `pci0000:b9` / NUMA 1.
- Raw logs, GuideLLM console output, Prometheus snapshots, manifests, ResourceClaims,
  topology validation, and exact collection tools are retained under
  [aligned](aligned/) and [cross-numa](cross-numa/).

The reported comparison is specifically the combined effect of cross-NUMA
GPU/NIC placement at both the prefill and decode endpoints on these A100
servers. It isolates KV transfer from tensor-parallel communication by using
TP1, but it should not be presented as a universal performance ratio for other
models, server PCIe topologies, or network adapters.

The means above reconstruct vLLM's periodic summaries using successful
transfer counts as weights. A run-wide P90 cannot be reconstructed from the
periodic log P90 values, so no such value is claimed.
