#!/usr/bin/env bash
# Print the sysfs PCIe-root and switch topology for GPUs and RDMA NICs.
#
# The "PCIe root" value printed here is the first pciXXXX:XX object in the
# device's sysfs ancestry (for example, pci0000:14). It is the value expected
# to correspond to resource.kubernetes.io/pcieRoot. Confirm the actual value
# published by each DRA driver in its ResourceSlices.

set -euo pipefail

SHOW_VFS=true
for arg in "$@"; do
  case "$arg" in
    --pf-only) SHOW_VFS=false ;;
    *)
      echo "Usage: $0 [--pf-only]" >&2
      exit 2
      ;;
  esac
done

DATA=$(mktemp)
trap 'rm -f "$DATA"' EXIT

strip_domain() { echo "${1#0000:}"; }

gpu_model() {
  case "$1" in
    2901) echo "B200" ;; 2920) echo "B100" ;; 2941) echo "GB200" ;;
    3182) echo "B300" ;; 31a1) echo "GB300" ;;
    2330) echo "H100 SXM5" ;; 2331) echo "H100 PCIe" ;;
    2335) echo "H200 SXM" ;; 233b) echo "H200 NVL" ;;
    20b2) echo "A100 SXM4" ;; 20b5) echo "A100 PCIe" ;;
    26b9) echo "L40S" ;; 27b8) echo "L4" ;;
    *) echo "GPU($1)" ;;
  esac
}

# Trace PCIe hierarchy for a device.
# Returns: sysfs_pcie_root|root_port|switch_upstream|downstream_port
trace_pci() {
  local full_path rel_path n pcie_root root_port switch downstream
  local root_index=-1 i
  local -a parts

  full_path=$(readlink -f "/sys/bus/pci/devices/$1") || return 1
  rel_path=${full_path#/sys/devices/}

  local IFS='/'
  read -ra parts <<< "$rel_path"
  for i in "${!parts[@]}"; do
    case ${parts[$i]} in
      pci????:??)
        root_index=$i
        break
        ;;
    esac
  done

  if [ "$root_index" -lt 0 ]; then
    printf 'unknown|unknown|unknown|unknown\n'
    return
  fi

  pcie_root=${parts[$root_index]}
  n=$((${#parts[@]} - root_index))

  if [ "$n" -ge 5 ]; then
    root_port=${parts[$((root_index + 1))]}
    switch=${parts[$((root_index + 2))]}
    downstream=${parts[$((root_index + 3))]}
  elif [ "$n" -ge 4 ]; then
    root_port=${parts[$((root_index + 1))]}
    switch=${parts[$((root_index + 1))]}
    downstream=${parts[$((root_index + 2))]}
  elif [ "$n" -ge 2 ]; then
    root_port=${parts[$((root_index + 1))]}
    switch=${parts[$((root_index + 1))]}
    downstream=${parts[$((root_index + 1))]}
  else
    root_port=unknown
    switch=unknown
    downstream=unknown
  fi

  printf '%s|%s|%s|%s\n' \
    "$pcie_root" "$root_port" "$switch" "$downstream"
}

# --- Discover GPUs ---
gpu_idx=0
for dev in /sys/bus/pci/devices/*; do
  vendor=$(cat "$dev/vendor" 2>/dev/null || echo none)
  [ "$vendor" != "0x10de" ] && continue
  class=$(cat "$dev/class" 2>/dev/null || echo 0x000000)
  case $class in
    0x030000|0x030200*)
      pci=$(basename "$dev")
      devid=$(cat "$dev/device" 2>/dev/null || echo 0x0000)
      devid=${devid#0x}
      numa=$(cat "$dev/numa_node" 2>/dev/null || echo -1)
      model=$(gpu_model "$devid")

      IFS='|' read -r pcie_root root_port switch downstream \
        <<< "$(trace_pci "$pci")"
      printf '%s|%s|%s|%s|%s|%s|GPU|GPU %d|%s\n' \
        "$numa" "$pcie_root" "$switch" "$root_port" "$downstream" \
        "$pci" "$gpu_idx" "$model" >> "$DATA"
      gpu_idx=$((gpu_idx + 1))
      ;;
  esac
done

# --- Discover RDMA NICs ---
for rd in /sys/class/infiniband/*; do
  [ -d "$rd" ] || continue

  is_vf=false
  [ -L "$rd/device/physfn" ] && is_vf=true
  [ "$is_vf" = true ] && [ "$SHOW_VFS" = false ] && continue

  rdma_dev=$(basename "$rd")
  pci_path=$(readlink -f "$rd/device" 2>/dev/null) || continue
  pci=$(basename "$pci_path")
  link_layer=$(cat "$rd/ports/1/link_layer" 2>/dev/null || echo unknown)
  numa=$(cat "$rd/device/numa_node" 2>/dev/null || echo -1)
  netdev=$(find "$rd/device/net" -mindepth 1 -maxdepth 1 -printf '%f\n' \
    2>/dev/null | sort | head -1 || true)
  [ -z "$netdev" ] && netdev="--"
  speed=$(cat "/sys/class/net/$netdev/speed" 2>/dev/null || echo 0)

  ll_tag="RoCE"
  [ "$link_layer" = "InfiniBand" ] && ll_tag="IB"
  [ "$is_vf" = true ] && ll_tag="$ll_tag/VF"

  if [ "$speed" -gt 0 ] 2>/dev/null; then
    speed_g="$((speed / 1000))G"
  else
    speed_g=""
  fi

  ip=$(ip -4 addr show "$netdev" 2>/dev/null \
    | grep -oP 'inet \K[0-9.]+' | head -1 || true)

  detail="$netdev"
  [ -n "$speed_g" ] && detail="$detail, $speed_g"
  detail="$detail, $ll_tag"
  [ -n "$ip" ] && detail="$detail, $ip"

  IFS='|' read -r pcie_root root_port switch downstream \
    <<< "$(trace_pci "$pci")"
  printf '%s|%s|%s|%s|%s|%s|NIC|%s|%s\n' \
    "$numa" "$pcie_root" "$switch" "$root_port" "$downstream" \
    "$pci" "$rdma_dev" "$detail" >> "$DATA"
done

if [ ! -s "$DATA" ]; then
  echo "No GPUs or RDMA NICs found."
  exit 0
fi

# --- Print tree ---
HOSTNAME=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)
echo "============================================"
echo "  PCIe GPU/NIC Topology: $HOSTNAME"
echo "============================================"
echo

sorted=$(sort -t'|' -k1,1n -k2,2 -k3,3 -k6,6 "$DATA")

prev_numa=""
prev_pcie_root=""
prev_switch=""

while IFS='|' read -r numa pcie_root switch root_port downstream pci dtype name detail; do
  if [ "$numa" != "$prev_numa" ]; then
    [ -n "$prev_numa" ] && echo
    echo "NUMA $numa"
    prev_pcie_root=""
    prev_switch=""
    prev_numa="$numa"
  fi

  if [ "$pcie_root" != "$prev_pcie_root" ]; then
    echo "PCIe root $pcie_root"
    prev_switch=""
    prev_pcie_root="$pcie_root"
  fi

  if [ "$switch" != "$prev_switch" ]; then
    if [ "$switch" = "$root_port" ]; then
      echo "|-- Root port $(strip_domain "$root_port")"
    else
      echo "|-- Switch $(strip_domain "$switch")" \
        "(root port $(strip_domain "$root_port"))"
    fi
    prev_switch="$switch"
  fi

  short_down=$(strip_domain "$downstream")
  short_pci=$(strip_domain "$pci")
  printf '|   |-- %s -> %s  %-7s (%s)\n' \
    "$short_down" "$short_pci" "$name" "$detail"
done <<< "$sorted"

echo "|"
echo
echo "Note: confirm these sysfs roots against the pcieRoot attributes published"
echo "by the GPU and SR-IOV DRA ResourceSlices. A shared PCIe root implies PIX"
echo "only when that root contains a single switch island."
