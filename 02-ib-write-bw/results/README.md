# GPUDirect RDMA GPU/NIC alignment results

Using the same 200 Gbit/s InfiniBand VF/PF on each node, aligned GPU/NIC
placement achieved **194.573 Gbit/s forward** and **193.941 Gbit/s reverse**.
Different-root/same-NUMA placement achieved 127.141 and 119.844 Gbit/s;
cross-NUMA placement achieved 110.037 and 92.749 Gbit/s.

Across the two separately measured directions, aligned placement delivered
**1.57x** same-NUMA-misaligned bandwidth and **1.92x** cross-NUMA-misaligned
bandwidth.

See the [full comparison, controls, and limitations](COMPARISON.md). Raw
perftest output, topology validation, manifests, ResourceClaims, and collection
tools are retained under each placement directory.
