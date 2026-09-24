# Cluster configuration

A100-exact bootstrap manifests used for the `dra-driver-sriov` / NVIDIA GPU
DRA experiments on workers `a100-04` and `a100-06`. These files document what
was installed; applying them to a production cluster is a cluster-owner
decision.

Observed devices from the cluster lives under [`observed/`](observed/).
Workloads are in [`../02-ib-write-bw/`](../02-ib-write-bw/)
and [`../03-prefill-decode/`](../03-prefill-decode/).

[`pcie-gpu-nic-tree.sh`](pcie-gpu-nic-tree.sh) prints the sysfs PCIe root (plus
root port and switch) for every GPU and RDMA device. Compare those values with
`resource.kubernetes.io/pcieRoot` in GPU and SR-IOV `ResourceSlice` objects.

## What was tested

| Item | Value |
|---|---|
| OpenShift | 4.22.2 |
| Allowed workers | `a100-04`, `a100-06` |
| Isolation label | `dra-sriov-cx6=true` |
| NICs | ConnectX-6 IB (`15b3:101b`), eight PFs per node |
| VF count | `numVfs: 1` (one VF per PF → eight VFs per node) |
| SR-IOV pool / DRA resource | `cx6_vfs` |
| Test namespace / NAD | `dra-sriov-test` / `cx6-vf` (`ib-sriov`) |
| DeviceClasses | `sriovnetwork.k8snetworkplumbingwg.io`, `gpu.nvidia.com` |
| Aligned claim | [`gpu-nic-aligned`](../02-ib-write-bw/aligned-resourceclaimtemplate.yaml) (`pcieRoot` match) |

## Layout

| Path | Purpose |
|---|---|
| [`00-prerequisites/`](00-prerequisites/) | Node label isolation |
| [`01-sriov-network-operator/`](01-sriov-network-operator/) | `SriovNetworkNodePolicy` |
| [`02-dra-driver-sriov/`](02-dra-driver-sriov/) | `DeviceAttributes` + `SriovResourcePolicy` |
| [`03-network-attachment/`](03-network-attachment/) | Namespace + InfiniBand NAD (`dra-sriov-test` / `cx6-vf`) |
| [`observed/`](observed/) | Read-only `ResourceSlice` samples |

Assume `dra-driver-sriov` and the NVIDIA GPU DRA driver are already installed
on the labeled workers before applying the CRs below.

## Bootstrap order

Apply in this order on a cluster that already has the SR-IOV Network Operator,
`dra-driver-sriov`, and (for GPU) NVIDIA drivers / GPU Operator + GPU DRA.

1. **OpenShift / DRA readiness** — confirm the API version and DeviceClasses
   (after drivers are installed, `gpu.nvidia.com` and
   `sriovnetwork.k8snetworkplumbingwg.io` should exist).
2. **Label workers** — [`00-prerequisites/node-labels.md`](00-prerequisites/node-labels.md).
   Verify only the intended nodes match `dra-sriov-cx6=true`.
3. **SR-IOV VFs** — review then apply
   [`01-sriov-network-operator/sriovnetworknodepolicy-cx6-vfs.yaml`](01-sriov-network-operator/sriovnetworknodepolicy-cx6-vfs.yaml).
   Enabling Mellanox VFs may require `mlxconfig` and a reboot.
4. **Advertise VFs to DRA** — apply
   [`deviceattributes-cx6-vfs-attrs.yaml`](02-dra-driver-sriov/deviceattributes-cx6-vfs-attrs.yaml)
   and
   [`sriovresourcepolicy-cx6-advertise-vfs.yaml`](02-dra-driver-sriov/sriovresourcepolicy-cx6-advertise-vfs.yaml).
5. **NAD** — apply
   [`03-network-attachment/namespace.yaml`](03-network-attachment/namespace.yaml)
   and
   [`networkattachmentdefinition-cx6-vf.yaml`](03-network-attachment/networkattachmentdefinition-cx6-vf.yaml).
6. **Aligned claim** — apply the portable template from workloads:
   [`../02-ib-write-bw/aligned-resourceclaimtemplate.yaml`](../02-ib-write-bw/aligned-resourceclaimtemplate.yaml).

## Verify

```bash
# Isolation
oc get nodes -l dra-sriov-cx6=true

# Drivers
oc -n dra-driver-sriov get pods,ds -o wide
oc -n nvidia-dra-driver-gpu get pods,ds -o wide

# Classes and inventory
oc get deviceclass
oc get resourceslices -o wide
```

Confirm InfiniBand VF readiness only after a pod attaches via `ib-sriov` with
`link_state: enable` (see READMEs).

