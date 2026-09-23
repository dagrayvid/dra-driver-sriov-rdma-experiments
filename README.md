# Topology-aware RDMA for LLM inference

This repository contains the manifests, collection tools, and raw evidence used
to evaluate GPU/NIC topology with `dra-driver-sriov`.

The experiments cover:

1. cluster configuration for GPU and SR-IOV DRA;
2. a deterministic GPUDirect RDMA `ib_write_bw` microbenchmark; and
3. a disaggregated vLLM prefill/decode KV-transfer benchmark.

## Repository layout

- [`01-cluster-configuration/`](01-cluster-configuration/) is reserved for the
  cluster-level `dra-driver-sriov`, SR-IOV, NetworkAttachmentDefinition, and
  GPU DRA configuration. This section is intentionally incomplete pending
  review by the cluster owner who installed the driver.
- [`02-ib-write-bw/`](02-ib-write-bw/) contains a
  [portable aligned claim](02-ib-write-bw/aligned-resourceclaimtemplate.yaml),
  three deterministic benchmark placements, the runner, validation tools, and
  complete results.
- [`03-prefill-decode/`](03-prefill-decode/) contains the aligned and
  cross-NUMA TP1 `LLMInferenceService` deployments, GuideLLM load generator,
  collection tools, and complete results.

## Results at a glance

The forward `ib_write_bw` test measured 194.6 Gbit/s with aligned devices,
127.1 Gbit/s across PCIe roots within one NUMA node, and 110.0 Gbit/s across
NUMA nodes. See the [complete RDMA comparison](02-ib-write-bw/results/COMPARISON.md).

In the TP1 prefill/decode test, aligned placement reduced mean KV-transfer
latency from 122.32 ms to 56.78 ms and delivered 2.15x effective transfer
throughput. See the [complete KV-transfer comparison](03-prefill-decode/results/COMPARISON.md).

## Important portability note

The deliberately controlled benchmark placements use PCI BDFs and node names
from the test cluster and must be adapted to another server's topology. The
portable aligned claim contains no BDFs: it uses the cross-driver
`resource.kubernetes.io/pcieRoot` attribute to express the desired GPU/VF
relationship.

No credentials, pull secrets, Hugging Face tokens, or kubeconfigs are included.
