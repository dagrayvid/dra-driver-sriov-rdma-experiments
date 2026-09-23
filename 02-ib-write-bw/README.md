# GPU/NIC alignment microbenchmark with `ib_write_bw`

This experiment measures GPUDirect RDMA WRITE bandwidth for three deterministic
GPU/VF relationships. Every case uses the same ConnectX-6 PF and VF on each
node; only the selected GPU changes.

| Case | GPU | VF (PF) | Relationship |
|---|---|---|---|
| Aligned | `0000:0a:00.0`, root `pci0000:00`, NUMA 0 | `0000:11:00.1` (`0000:11:00.0`), root `pci0000:00`, NUMA 0 | Same PCIe root and NUMA |
| Same NUMA | `0000:4b:00.0`, root `pci0000:3e`, NUMA 0 | Same VF/PF | Different PCIe root, same NUMA |
| Cross NUMA | `0000:c3:00.0`, root `pci0000:b9`, NUMA 1 | Same VF/PF | Different PCIe root and NUMA |

For application deployments, use
[`aligned-resourceclaimtemplate.yaml`](aligned-resourceclaimtemplate.yaml).
It requests any available GPU and VF whose
`resource.kubernetes.io/pcieRoot` attributes match; it contains no PCI
addresses.

The three templates in `benchmark-device-claims.yaml` are deliberately
different. They use explicit BDF selectors to hold the physical NIC constant
while changing only the GPU location. This is an experiment control, not a
recommended deployment pattern.

The `cx6-vf` attachment is native InfiniBand without IPAM. RDMA uses the HCA
assigned as `net1`; the regular pod IP is used only for perftest's TCP control
connection, so IPoIB is unnecessary.

The pod manifests use `quay.io/dagray/rdma-tools:tiny`, the image used for the
published results. It contains CUDA-enabled perftest and the NVIDIA utilities
required by the collector. Replace it with an equivalent image if it is not
available to the target cluster.

## Measurement configuration

The collector performs ten independent measurements per topology:

- `ib_write_bw` with one QP and CUDA device memory (`--use_cuda=0`);
- 8 MiB messages (`-s 8388608`);
- 5,000 measured iterations (`-n 5000`);
- an internal warm-up before measurement (`--perform_warm_up`);
- Gbit/s reporting (`--report_gbits`); and
- `MLX5_SCATTER_TO_CQE=0`, as recommended by perftest for GPUDirect tests.

Each measurement gets a fresh server process and TCP control port. The
collector consistently parses the client process's perftest report, retains
both sides' raw output, validates the assigned sysfs devices, and calculates
mean, median, sample standard deviation, range, and coefficient of variation.
In the default forward mode the client initiates RDMA WRITE; `--reversed`
changes the data direction without changing the control roles.

## Preparation

Remove the LLM service and any previous microbenchmark pods. Wait until their
generated ResourceClaims have disappeared before continuing.

```bash
export KUBECONFIG=/path/to/your/kubeconfig
export NS=dra-sriov-test

oc delete llmisvc qwen38-27b-pd-tp1 llama31-70b-pd \
  -n "$NS" --ignore-not-found
oc delete pod -n "$NS" -l app=sriov-test --ignore-not-found
oc delete pod -n "$NS" -l app=ib-write-bw --ignore-not-found
oc get pod,resourceclaim -n "$NS" -w
```

The collector refuses to start if another active pod on `a100-04` or `a100-06`
uses a DRA claim or requests `nvidia.com/gpu`.

## 1. Aligned

```bash
./run-ib-write-bw-benchmark.sh aligned results/aligned
```

Review the result, then release its devices:

```bash
cat results/aligned/summary.md
oc delete -f ib-write-bw-aligned-pods.yaml
oc get resourceclaim -n "$NS" -w
```

## 2. Different root, same NUMA

After the aligned claims disappear:

```bash
./run-ib-write-bw-benchmark.sh same-numa results/same-numa
```

Then release its devices:

```bash
cat results/same-numa/summary.md
oc delete -f ib-write-bw-same-numa-pods.yaml
oc get resourceclaim -n "$NS" -w
```

## 3. Cross NUMA

After the same-NUMA claims disappear:

```bash
./run-ib-write-bw-benchmark.sh cross-numa results/cross-numa
```

Review and clean up:

```bash
cat results/cross-numa/summary.md
oc delete -f ib-write-bw-misaligned-pods.yaml
```

## Comparison and interpretation

Keep message size, iteration count, and all perftest options identical. Compare
medians and variation across the independent runs rather than selecting the
best result. The aligned-versus-same-NUMA result isolates the extra PCIe-root
path within one NUMA node; same-NUMA versus cross-NUMA adds the inter-NUMA
path.

This is a direct perftest GPUDirect RDMA bandwidth measurement, unlike vLLM's
derived NIXL effective-transfer metric. It is still an application-level
perftest result, not a physical-layer counter.

## Reverse-direction check

Set `DIRECTION=reverse` to add perftest's symmetric `--reversed` option on both
sides. Pod roles and topology stay unchanged, but RDMA WRITE data flows from
the server on `a100-04` to the client on `a100-06`:

```bash
DIRECTION=reverse ./run-ib-write-bw-benchmark.sh \
  aligned results/aligned-reverse
```

Repeat with `same-numa` and `cross-numa`, deleting the preceding case's pods
and waiting for its ResourceClaims to disappear exactly as in the forward
workflow. Use distinct output directories so forward results remain intact.
