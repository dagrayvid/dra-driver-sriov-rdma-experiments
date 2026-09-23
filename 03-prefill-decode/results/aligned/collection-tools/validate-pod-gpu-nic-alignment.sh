#!/usr/bin/env bash
# Validate GPU/SR-IOV VF topology from inside a serving container.
#
# Unlike nvidia-smi topo -m, this script only considers:
#   * GPUs exposed to the container by NVIDIA DRA; and
#   * netN interfaces moved into the pod by dra-driver-sriov.
#
# It does not require an IP address and works with native InfiniBand VFs.

set -euo pipefail

normalize_bdf() {
  tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/^00000000:/0000:/'
}

pci_path() {
  readlink -f "/sys/bus/pci/devices/$1"
}

pcie_root() {
  local path part
  path=$(pci_path "$1")
  IFS=/ read -ra parts <<<"${path#/sys/devices/}"
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^pci[0-9a-fA-F]{4}:[0-9a-fA-F]{2}$ ]]; then
      printf '%s\n' "$part"
      return
    fi
  done
  printf '%s\n' unknown
}

numa_node() {
  local value
  value=$(cat "/sys/bus/pci/devices/$1/numa_node" 2>/dev/null || true)
  [[ -n "$value" ]] && printf '%s\n' "$value" || printf '%s\n' unknown
}

declare -a gpu_bdfs=()
while IFS= read -r raw; do
  [[ -n "$raw" ]] && gpu_bdfs+=("$(normalize_bdf "$raw")")
done < <(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader)

declare -a vf_ifaces=()
for path in /sys/class/net/net[0-9]*; do
  [[ -e "$path" ]] || continue
  vf_ifaces+=("$(basename "$path")")
done

if (( ${#gpu_bdfs[@]} == 0 )); then
  echo "No DRA-exposed GPUs found." >&2
  exit 1
fi
if (( ${#vf_ifaces[@]} == 0 )); then
  echo "No DRA-created netN VF interfaces found." >&2
  exit 1
fi

echo "GPU allocations visible to CUDA"
printf '%-6s %-14s %-14s %-6s\n' GPU PCI_BDF PCIE_ROOT NUMA
for i in "${!gpu_bdfs[@]}"; do
  bdf=${gpu_bdfs[$i]}
  printf 'GPU%-3d %-14s %-14s %-6s\n' \
    "$i" "$bdf" "$(pcie_root "$bdf")" "$(numa_node "$bdf")"
done

echo
echo "SR-IOV VFs assigned to this pod"
printf '%-8s %-12s %-14s %-14s %-14s %-6s\n' \
  IFACE HCA VF_BDF PF_BDF PCIE_ROOT NUMA
declare -A pf_uses=()
distinct_pfs=true
for iface in $(printf '%s\n' "${vf_ifaces[@]}" | sort -V); do
  dev_path=$(readlink -f "/sys/class/net/$iface/device")
  bdf=$(basename "$dev_path")
  pf_path=$(readlink -f "/sys/class/net/$iface/device/physfn" 2>/dev/null || true)
  pf_bdf=${pf_path##*/}
  [[ -n "$pf_bdf" ]] || pf_bdf="--"
  if [[ "$pf_bdf" != "--" ]]; then
    pf_uses["$pf_bdf"]="${pf_uses[$pf_bdf]:-} $iface"
  else
    distinct_pfs=false
  fi
  hca=$(find "/sys/class/net/$iface/device/infiniband" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -1 || true)
  printf '%-8s %-12s %-14s %-14s %-14s %-6s\n' \
    "$iface" "${hca:---}" "$bdf" "$pf_bdf" \
    "$(pcie_root "$bdf")" "$(numa_node "$bdf")"
done

echo
echo "Physical-function uniqueness"
if (( ${#pf_uses[@]} == 0 )); then
  echo "FAIL - parent PF could not be resolved for any assigned VF"
fi
for pf_bdf in "${!pf_uses[@]}"; do
  read -ra uses <<<"${pf_uses[$pf_bdf]}"
  if (( ${#uses[@]} > 1 )); then
    printf '%s: FAIL - shared by interfaces %s\n' "$pf_bdf" "${uses[*]}"
    distinct_pfs=false
  else
    printf '%s: PASS - used by %s\n' "$pf_bdf" "${uses[0]}"
  fi
done

echo
echo "Alignment by shared PCIe root (the DRA constraint)"
all_aligned=true
for i in "${!gpu_bdfs[@]}"; do
  gpu_bdf=${gpu_bdfs[$i]}
  gpu_root=$(pcie_root "$gpu_bdf")
  matches=()
  for iface in "${vf_ifaces[@]}"; do
    vf_bdf=$(basename "$(readlink -f "/sys/class/net/$iface/device")")
    if [[ "$(pcie_root "$vf_bdf")" == "$gpu_root" ]]; then
      matches+=("$iface")
    fi
  done
  if (( ${#matches[@]} == 0 )); then
    printf 'GPU%d: FAIL - no assigned VF under %s\n' "$i" "$gpu_root"
    all_aligned=false
  else
    printf 'GPU%d: PASS - root=%s VF=%s\n' \
      "$i" "$gpu_root" "$(IFS=,; echo "${matches[*]}")"
  fi
done

echo
if [[ "$all_aligned" == true && "$distinct_pfs" == true ]]; then
  echo "PASS: every visible GPU has a same-root VF and every VF uses a distinct PF."
else
  echo "FAIL: GPU/VF root alignment or PF uniqueness validation failed." >&2
  exit 1
fi
