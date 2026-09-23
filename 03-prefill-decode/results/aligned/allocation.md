# DRA allocation report: qwen38-27b-pd-tp1

Generated: `2026-09-17T16:52:15-04:00`  
Namespace: `dra-sriov-test`

## Pod summary

| Role | Pod | Node | Ready | TP | GPU placement | TP GPU-pair locality | GPU/NIC alignment |
|---|---|---|---:|---:|---|---|---|
| decode | `qwen38-27b-pd-tp1-kserve-6697f94486-ptcdt` | `a100-06` | 2/2 | 1 | NUMA 0: 1; roots pci0000:00: 1 | 0 same root, 0 same NUMA, different root, 0 cross NUMA, 0 unknown | 1 same root, 0 same NUMA, different root, 0 cross NUMA, 0 unknown |
| prefill | `qwen38-27b-pd-tp1-kserve-prefill-bcbc95964-7xgj5` | `a100-04` | 1/1 | 1 | NUMA 0: 1; roots pci0000:00: 1 | 0 same root, 0 same NUMA, different root, 0 cross NUMA, 0 unknown | 1 same root, 0 same NUMA, different root, 0 cross NUMA, 0 unknown |

## Rank details

### decode `qwen38-27b-pd-tp1-kserve-6697f94486-ptcdt`

| Rank | GPU | GPU PCI | GPU root/NUMA | VF PCI | PF PCI | VF root/NUMA | Alignment |
|---:|---|---|---|---|---|---|---|
| 0 | gpu-3 | `0000:0a:00.0` | `pci0000:00` / 0 | `0000:0e:00.1` | `0000:0e:00.0` | `pci0000:00` / 0 | same root |

### prefill `qwen38-27b-pd-tp1-kserve-prefill-bcbc95964-7xgj5`

| Rank | GPU | GPU PCI | GPU root/NUMA | VF PCI | PF PCI | VF root/NUMA | Alignment |
|---:|---|---|---|---|---|---|---|
| 0 | gpu-2 | `0000:07:00.0` | `pci0000:00` / 0 | `0000:0e:00.1` | `0000:0e:00.0` | `pci0000:00` / 0 | same root |

## Overall GPU/NIC alignment

2 same root, 0 same NUMA, different root, 0 cross NUMA, 0 unknown.

## PF uniqueness

- `a100-04`: 1 selected VFs, 1 unique PFs; no duplicate PFs.
- `a100-06`: 1 selected VFs, 1 unique PFs; no duplicate PFs.
