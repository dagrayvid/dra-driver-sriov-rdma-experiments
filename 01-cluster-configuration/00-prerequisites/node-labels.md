# Node isolation labels

The SR-IOV Network Operator policy, `dra-driver-sriov` kubelet plugin, and
NVIDIA GPU DRA kubelet plugin all use the same node selector:

```text
dra-sriov-cx6=true
```

On the experiment cluster this label is present only on:

- `a100-04`
- `a100-06`

## Verify (read-only)

```bash
oc get nodes -l dra-sriov-cx6=true
# expect only: a100-04 a100-06
```

## Apply (cluster owner)

```bash
oc label node a100-04 a100-06 dra-sriov-cx6=true
```

## Undo

```bash
oc label node a100-04 a100-06 dra-sriov-cx6-
```
