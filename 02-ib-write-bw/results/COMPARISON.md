# GPUDirect RDMA WRITE bandwidth by GPU/NIC placement

## Result

| Placement | Forward: `a100-06` → `a100-04` | Reverse: `a100-04` → `a100-06` | Reverse vs. forward | Direction-balanced mean |
|---|---:|---:|---:|---:|
| Aligned, same PCIe root | 194.573 Gbit/s | 193.941 Gbit/s | -0.3% | 194.257 Gbit/s |
| Different root, same NUMA | 127.141 Gbit/s | 119.844 Gbit/s | -5.7% | 123.493 Gbit/s |
| Different root, cross NUMA | 110.037 Gbit/s | 92.749 Gbit/s | -15.7% | 101.393 Gbit/s |

The direction-balanced mean is the arithmetic mean of two separately measured
directions; it is not simultaneous bidirectional throughput.

### Placement effect

| Data direction | Aligned vs. same NUMA | Same-NUMA loss | Aligned vs. cross NUMA | Cross-NUMA loss | Additional cross-NUMA loss vs. same NUMA |
|---|---:|---:|---:|---:|---:|
| `a100-06` → `a100-04` | 1.53x | 34.7% | 1.77x | 43.4% | 13.5% |
| `a100-04` → `a100-06` | 1.62x | 38.2% | 2.09x | 52.2% | 22.6% |
| Direction-balanced | 1.57x | 36.4% | 1.92x | 47.8% | 17.9% |

Aligned placement sustained approximately 97% of the nominal 200 Gbit/s link
rate in either direction. Misalignment imposed a large penalty in both
directions, and crossing NUMA was consistently worse than staying within the
same NUMA node.

### Repeatability

Each cell is ten independent client/server process pairs.

| Placement | Forward CV | Reverse CV | Forward range | Reverse range |
|---|---:|---:|---:|---:|
| Aligned | 0.019% | 0.172% | 194.510–194.620 Gbit/s | 193.000–194.100 Gbit/s |
| Same NUMA | 0.189% | 0.142% | 126.560–127.440 Gbit/s | 119.660–120.150 Gbit/s |
| Cross NUMA | 2.561% | 1.244% | 105.950–115.960 Gbit/s | 91.420–94.620 Gbit/s |

## Controlled configuration

Every case used:

- perftest `ib_write_bw` version 6.27 with CUDA device memory;
- the same client process on `a100-06` and server process on `a100-04`;
- one QP, 8 MiB messages, 5,000 measured iterations, and an internal warm-up;
- ten independent client/server process pairs;
- `--use_cuda=0`, `--report_gbits`, `-F`, and `MLX5_SCATTER_TO_CQE=0`;
- HCA `mlx5_9`, VF `0000:11:00.1`, and PF `0000:11:00.0` under
  `pci0000:00` / NUMA 0 on each node; and
- an active native-InfiniBand link reporting a 200 Gbit/s rate.

Forward runs used the default perftest data direction. Reverse runs added
`--reversed` to both endpoints, reversing the RDMA WRITE data path while
retaining the same process roles and all other settings.

Only the A100 GPU changed:

| Placement | GPU BDF | GPU PCIe root | GPU NUMA | VF root/NUMA |
|---|---|---|---:|---|
| Aligned | `0000:0a:00.0` | `pci0000:00` | 0 | `pci0000:00` / 0 |
| Same NUMA | `0000:4b:00.0` | `pci0000:3e` | 0 | `pci0000:00` / 0 |
| Cross NUMA | `0000:c3:00.0` | `pci0000:b9` | 1 | `pci0000:00` / 0 |

The collector found no other active GPU- or DRA-consuming pods on either node
during any of the six cases.

## Evidence

- Forward: [aligned](aligned/summary.md),
  [same NUMA](same-numa/summary.md), and
  [cross NUMA](cross-numa/summary.md)
- Reverse: [aligned](aligned-reverse/summary.md),
  [same NUMA](same-numa-reverse/summary.md), and
  [cross NUMA](cross-numa-reverse/summary.md)

Each placement directory retains raw client and server output, topology
validation, environment and link information, pod and DRA manifests,
ResourceClaims, and the exact collector, validator, and parser used.

## Scope and limitations

This result measures end-to-end GPUDirect RDMA WRITE bandwidth with both
endpoints configured for the named placement class. It does not isolate the
source-side penalty from the destination-side penalty.

The comparison changes physical GPUs because a single GPU cannot occupy three
PCIe locations; all selected devices are NVIDIA A100-SXM4-80GB GPUs. The two
nodes are not identical in every firmware detail, so the directional
difference for misaligned paths should not be attributed to one component
without further isolation. The aligned result's near symmetry shows that this
asymmetry does not materially limit the aligned path.

These values characterize this server topology and should not be generalized
as universal ratios for H100, H200, B-series, or differently wired systems.
