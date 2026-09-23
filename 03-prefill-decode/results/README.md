# TP1 GPU/NIC alignment results

With identical Qwen3.8-27B TP1 workloads, same-root GPU/NIC placement delivered
**2.15x effective KV-transfer throughput** and **53.6% lower mean transfer
latency** than cross-NUMA placement.

See the [full comparison and validation evidence](COMPARISON.md). Raw aligned
and cross-NUMA logs, GuideLLM results, Prometheus snapshots, allocation
reports, manifests, and collection tools are retained in their respective
subdirectories.
