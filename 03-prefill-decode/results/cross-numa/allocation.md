# DRA allocation report: qwen38-27b-pd-tp1

Generated: `2026-09-18T16:57:48-04:00`  
Namespace: `dra-sriov-test`

## Pod summary

| Role | Pod | Node | Ready | TP | GPU placement | TP GPU-pair locality | GPU/NIC alignment |
|---|---|---|---:|---:|---|---|---|
| decode | `qwen38-27b-pd-tp1-kserve-84cfdbd584-khgd9` | `a100-06` | 2/2 | 1 | NUMA 0: 1; roots pci0000:00: 1 | 0 same root, 0 same NUMA, different root, 0 cross NUMA, 0 unknown | 0 same root, 0 same NUMA, different root, 1 cross NUMA, 0 unknown |
| prefill | `qwen38-27b-pd-tp1-kserve-prefill-69966df4fd-kdjjs` | `a100-04` | 1/1 | 1 | NUMA 0: 1; roots pci0000:00: 1 | 0 same root, 0 same NUMA, different root, 0 cross NUMA, 0 unknown | 0 same root, 0 same NUMA, different root, 1 cross NUMA, 0 unknown |

## Rank details

### decode `qwen38-27b-pd-tp1-kserve-84cfdbd584-khgd9`

| Rank | GPU | GPU PCI | GPU root/NUMA | VF PCI | PF PCI | VF root/NUMA | Alignment |
|---:|---|---|---|---|---|---|---|
| 0 | gpu-2 | `0000:07:00.0` | `pci0000:00` / 0 | `0000:ca:00.1` | `0000:ca:00.0` | `pci0000:b9` / 1 | cross NUMA |

### prefill `qwen38-27b-pd-tp1-kserve-prefill-69966df4fd-kdjjs`

| Rank | GPU | GPU PCI | GPU root/NUMA | VF PCI | PF PCI | VF root/NUMA | Alignment |
|---:|---|---|---|---|---|---|---|
| 0 | gpu-3 | `0000:0a:00.0` | `pci0000:00` / 0 | `0000:c7:00.1` | `0000:c7:00.0` | `pci0000:b9` / 1 | cross NUMA |

## Overall GPU/NIC alignment

0 same root, 0 same NUMA, different root, 2 cross NUMA, 0 unknown.

## PF uniqueness

- `a100-04`: 1 selected VFs, 1 unique PFs; no duplicate PFs.
- `a100-06`: 1 selected VFs, 1 unique PFs; no duplicate PFs.
