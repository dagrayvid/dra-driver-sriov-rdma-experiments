#!/usr/bin/env bash
# Run one deterministic GPUDirect RDMA ib_write_bw topology case and collect
# raw output, DRA allocation evidence, and a machine-readable summary.

set -euo pipefail

usage() {
  echo "Usage: $0 <aligned|same-numa|cross-numa> [output-directory]" >&2
  exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
CASE=$1
[[ "$CASE" == aligned || "$CASE" == same-numa || "$CASE" == cross-numa ]] || usage

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NS=${NS:-dra-sriov-test}
RUNS=${RUNS:-10}
MESSAGE_SIZE=${MESSAGE_SIZE:-8388608}
ITERATIONS=${ITERATIONS:-5000}
BASE_PORT=${BASE_PORT:-18515}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT=${2:-$SCRIPT_DIR/results/ib-write-bw/$STAMP-$CASE}

for command in oc python3; do
  command -v "$command" >/dev/null || {
    echo "error: required command not found: $command" >&2
    exit 1
  }
done
[[ -n "${KUBECONFIG:-}" ]] || {
  echo "error: export KUBECONFIG before running this script" >&2
  exit 1
}
[[ ! -e "$OUT" ]] || {
  echo "error: output path already exists: $OUT" >&2
  exit 1
}

case "$CASE" in
  aligned)
    MANIFEST=ib-write-bw-aligned-pods.yaml
    TEMPLATE=ib-write-bw-aligned
    SERVER=ib-write-bw-aligned-server
    CLIENT=ib-write-bw-aligned-client
    GPU_BDF=0000:0a:00.0
    GPU_ROOT=pci0000:00
    GPU_NUMA=0
    ;;
  same-numa)
    MANIFEST=ib-write-bw-same-numa-pods.yaml
    TEMPLATE=ib-write-bw-misaligned-same-numa
    SERVER=ib-write-bw-same-numa-server
    CLIENT=ib-write-bw-same-numa-client
    GPU_BDF=0000:4b:00.0
    GPU_ROOT=pci0000:3e
    GPU_NUMA=0
    ;;
  cross-numa)
    MANIFEST=ib-write-bw-misaligned-pods.yaml
    TEMPLATE=ib-write-bw-misaligned-cross-numa
    SERVER=ib-write-bw-misaligned-server
    CLIENT=ib-write-bw-misaligned-client
    GPU_BDF=0000:c3:00.0
    GPU_ROOT=pci0000:b9
    GPU_NUMA=1
    ;;
esac
VF_BDF=0000:11:00.1
PF_BDF=0000:11:00.0
VF_ROOT=pci0000:00
VF_NUMA=0

# Refuse to benchmark alongside another GPU or DRA workload on either node.
PODS_TMP=$(mktemp)
COMPETING_TMP=$(mktemp)
trap 'rm -f "$PODS_TMP" "$COMPETING_TMP"' EXIT
oc get pods -A -o json > "$PODS_TMP"
if ! python3 - "$PODS_TMP" "$NS/$SERVER" "$NS/$CLIENT" \
  > "$COMPETING_TMP" <<'PY'
import json, sys
pods = json.load(open(sys.argv[1])).get("items", [])
allowed = set(sys.argv[2:])
competitors = []
for pod in pods:
    spec = pod.get("spec", {})
    if spec.get("nodeName") not in {"a100-04", "a100-06"}:
        continue
    identity = f"{pod['metadata'].get('namespace', 'default')}/{pod['metadata']['name']}"
    if identity in allowed or pod.get("status", {}).get("phase") in {"Succeeded", "Failed"}:
        continue
    reasons = []
    if spec.get("resourceClaims"):
        reasons.append("DRA resourceClaims")
    containers = spec.get("initContainers", []) + spec.get("containers", [])
    if any(
        float(c.get("resources", {}).get(kind, {}).get("nvidia.com/gpu", 0)) > 0
        for c in containers for kind in ("requests", "limits")
    ):
        reasons.append("nvidia.com/gpu")
    if reasons:
        competitors.append(f"{identity}\tnode={spec.get('nodeName')}\t{','.join(reasons)}")
if competitors:
    print("Potentially competing workloads:")
    print("\n".join(sorted(competitors)))
    raise SystemExit(1)
print("No other active GPU- or DRA-consuming pods found on the benchmark nodes.")
PY
then
  echo "error: competing workloads found:" >&2
  cat "$COMPETING_TMP" >&2
  exit 1
fi

mkdir -p "$OUT/runs"
mv "$COMPETING_TMP" "$OUT/competing-workloads.txt"

oc apply -f "$SCRIPT_DIR/ib-write-bw-device-claims.yaml"
oc apply -f "$SCRIPT_DIR/$MANIFEST"
oc wait -n "$NS" --for=condition=Ready "pod/$SERVER" "pod/$CLIENT" --timeout=5m

oc get pods "$SERVER" "$CLIENT" -n "$NS" -o yaml > "$OUT/pods.yaml"
oc get resourceclaims -n "$NS" -o yaml > "$OUT/resourceclaims.yaml"
oc get resourceclaimtemplate "$TEMPLATE" -n "$NS" -o yaml > "$OUT/resourceclaimtemplate.yaml"
oc get pods -A --field-selector spec.nodeName=a100-04 -o wide > "$OUT/node-workloads-a100-04.txt"
oc get pods -A --field-selector spec.nodeName=a100-06 -o wide > "$OUT/node-workloads-a100-06.txt"

for entry in "server:$SERVER" "client:$CLIENT"; do
  role=${entry%%:*}
  pod=${entry#*:}
  set +e
  oc exec -i -n "$NS" "$pod" -- bash -s \
    < "$SCRIPT_DIR/validate-pod-gpu-nic-alignment.sh" \
    > "$OUT/topology-$role.txt" 2>&1
  validator_status=$?
  set -e
  echo "validator_exit_status=$validator_status" >> "$OUT/topology-$role.txt"
  if [[ "$CASE" == aligned && $validator_status -ne 0 ]]; then
    echo "error: aligned topology validator failed for $pod" >&2
    exit 1
  fi
  if [[ "$CASE" != aligned && $validator_status -eq 0 ]]; then
    echo "error: deliberately misaligned topology unexpectedly passed for $pod" >&2
    exit 1
  fi
  grep -Eq "GPU0.*${GPU_BDF}.*${GPU_ROOT}.*${GPU_NUMA}" "$OUT/topology-$role.txt" || {
    echo "error: unexpected GPU topology for $pod; see topology-$role.txt" >&2
    exit 1
  }
  grep -Eq "net1.*${VF_BDF}.*${PF_BDF}.*${VF_ROOT}.*${VF_NUMA}" "$OUT/topology-$role.txt" || {
    echo "error: unexpected VF topology for $pod; see topology-$role.txt" >&2
    exit 1
  }
  oc exec -n "$NS" "$pod" -- bash -lc '
    echo "ib_write_bw: $(ib_write_bw --version 2>&1 | head -1)"
    echo "HCA: $(ls /sys/class/net/net1/device/infiniband)"
    echo "GPU: $(nvidia-smi --query-gpu=name,pci.bus_id --format=csv,noheader)"
    ibstat "$(ls /sys/class/net/net1/device/infiniband)" 2>/dev/null || true
  ' > "$OUT/environment-$role.txt" 2>&1
done

SERVER_IP=$(oc get pod "$SERVER" -n "$NS" -o jsonpath='{.status.podIP}')
{
  echo "case=$CASE"
  echo "server=$NS/$SERVER"
  echo "client=$NS/$CLIENT"
  echo "server_ip=$SERVER_IP"
  echo "runs=$RUNS"
  echo "message_size_bytes=$MESSAGE_SIZE"
  echo "iterations=$ITERATIONS"
  echo "gpu_bdf=$GPU_BDF"
  echo "gpu_root=$GPU_ROOT"
  echo "gpu_numa=$GPU_NUMA"
  echo "vf_bdf=$VF_BDF"
  echo "pf_bdf=$PF_BDF"
  echo "vf_root=$VF_ROOT"
  echo "vf_numa=$VF_NUMA"
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/run-metadata.txt"

: > "$OUT/client-all.txt"
: > "$OUT/server-all.txt"
server_exec_pid=""
cleanup_server() {
  if [[ -n "$server_exec_pid" ]] && kill -0 "$server_exec_pid" 2>/dev/null; then
    kill "$server_exec_pid" 2>/dev/null || true
  fi
  rm -f "$PODS_TMP" "$COMPETING_TMP"
}
trap cleanup_server EXIT

run=1
while [[ $run -le $RUNS ]]; do
  run_id=$(printf '%02d' "$run")
  port=$((BASE_PORT + run - 1))
  server_log="$OUT/runs/$run_id-server.txt"
  client_log="$OUT/runs/$run_id-client.txt"
  echo "Running $CASE measurement $run/$RUNS on port $port..."

  oc exec -i -n "$NS" "$SERVER" -- bash -lc '
    HCA=$(ls /sys/class/net/net1/device/infiniband)
    exec env MLX5_SCATTER_TO_CQE=0 ib_write_bw -d "$HCA" --use_cuda=0 \
      --perform_warm_up --report_gbits -F -s "$1" -n "$2" -p "$3"
  ' _ "$MESSAGE_SIZE" "$ITERATIONS" "$port" > "$server_log" 2>&1 &
  server_exec_pid=$!
  sleep 2

  set +e
  oc exec -i -n "$NS" "$CLIENT" -- bash -lc '
    HCA=$(ls /sys/class/net/net1/device/infiniband)
    exec env MLX5_SCATTER_TO_CQE=0 ib_write_bw -d "$HCA" --use_cuda=0 \
      --perform_warm_up --report_gbits -F -s "$1" -n "$2" -p "$3" "$4"
  ' _ "$MESSAGE_SIZE" "$ITERATIONS" "$port" "$SERVER_IP" > "$client_log" 2>&1
  client_status=$?
  wait "$server_exec_pid"
  server_status=$?
  set -e
  server_exec_pid=""
  if [[ $client_status -ne 0 || $server_status -ne 0 ]]; then
    echo "error: run $run failed (client=$client_status server=$server_status)" >&2
    exit 1
  fi
  {
    echo "### run $run"
    cat "$client_log"
  } >> "$OUT/client-all.txt"
  {
    echo "### run $run"
    cat "$server_log"
  } >> "$OUT/server-all.txt"
  run=$((run + 1))
done

"$SCRIPT_DIR/summarize-ib-write-bw.py" "$OUT/client-all.txt" \
  --message-size "$MESSAGE_SIZE" --iterations "$ITERATIONS" \
  --expected-runs "$RUNS" > "$OUT/summary.json"
"$SCRIPT_DIR/summarize-ib-write-bw.py" "$OUT/client-all.txt" \
  --message-size "$MESSAGE_SIZE" --iterations "$ITERATIONS" \
  --expected-runs "$RUNS" --format markdown --label "$CASE" > "$OUT/summary.md"
echo "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT/run-metadata.txt"

cp "$SCRIPT_DIR/ib-write-bw-device-claims.yaml" "$OUT/"
cp "$SCRIPT_DIR/$MANIFEST" "$OUT/"
cp "$SCRIPT_DIR/run-ib-write-bw-benchmark.sh" "$OUT/"
cp "$SCRIPT_DIR/summarize-ib-write-bw.py" "$OUT/"
cp "$SCRIPT_DIR/validate-pod-gpu-nic-alignment.sh" "$OUT/"

echo
echo "Result bundle complete: $OUT"
cat "$OUT/summary.md"
