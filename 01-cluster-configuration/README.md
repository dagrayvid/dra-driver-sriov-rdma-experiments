# Cluster configuration

This section is intentionally a placeholder. The cluster-level installation
was performed by another contributor and should be documented and reviewed by
that owner before publication.

At minimum, this directory should eventually contain or link to:

- the tested OpenShift/Kubernetes version and relevant DRA feature gates;
- installation and version information for `dra-driver-sriov`;
- NVIDIA GPU DRA driver configuration;
- the SR-IOV Network Operator policy and resulting VF configuration;
- the `NetworkAttachmentDefinition` used by the assigned InfiniBand VFs;
- the SR-IOV resource-pool name (`cx6_vfs` in these experiments);
- confirmation that one VF was exposed per PF for the final experiments;
- the device attributes published in `ResourceSlice` objects, especially
  `resource.kubernetes.io/pcieRoot` and `pfPciAddress`; and
- commands for verifying the driver pods, `DeviceClass` objects,
  `ResourceSlice` inventory, VF-to-PF mapping, and InfiniBand link state.

Do not add kubeconfigs, tokens, registry credentials, or pull-secret contents
to this repository.

[`pcie-gpu-nic-tree.sh`](pcie-gpu-nic-tree.sh) prints the sysfs PCIe root in
addition to the root port and switch for every GPU and RDMA device. Compare
those values with the `resource.kubernetes.io/pcieRoot` attributes published
in the GPU and SR-IOV `ResourceSlice` objects.
