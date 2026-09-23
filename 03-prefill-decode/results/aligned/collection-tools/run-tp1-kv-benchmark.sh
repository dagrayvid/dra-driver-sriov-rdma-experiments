#!/usr/bin/env bash
# Run one repeatable TP1 KV-transfer benchmark against an already deployed
# aligned or cross-NUMA LLMInferenceService and collect a publishable bundle.

set -euo pipefail

usage() {
  echo "Usage: $0 <aligned|cross-numa> [output-directory]" >&2
  exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
PLACEMENT=$1
[[ "$PLACEMENT" == aligned || "$PLACEMENT" == cross-numa ]] || usage

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NS=${NS:-dra-sriov-test}
SERVICE=${SERVICE:-qwen38-27b-pd-tp1}
CONCURRENCY=${CONCURRENCY:-10}
PROMPT_TOKENS=${PROMPT_TOKENS:-16000}
OUTPUT_TOKENS=${OUTPUT_TOKENS:-64}
REQUESTS=${REQUESTS:-128}
REPETITIONS=${REPETITIONS:-3}
SEED_BASE=${SEED_BASE:-42000}
# KServe/vLLM images have used different serving ports. Try each without
# making Prometheus availability a prerequisite for the log-based result.
METRICS_PORTS=${METRICS_PORTS:-"8000 8001 8080"}
LLMISVC_URL=${LLMISVC_URL:-http://openshift-ai-inference-openshift-default.openshift-ingress.svc.cluster.local/${NS}/${SERVICE}}
GUIDELLM_NS=${GUIDELLM_NS:-$NS}
GUIDELLM_POD=${GUIDELLM_POD:-guidellm}
GUIDELLM_CONTAINER=${GUIDELLM_CONTAINER:-guidellm}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT=${2:-$SCRIPT_DIR/results/tp1-kv/${STAMP}-${PLACEMENT}}

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
mkdir -p "$OUT/repetitions"

oc wait -n "$GUIDELLM_NS" --for=condition=Ready \
  "pod/$GUIDELLM_POD" --timeout=5m
if ! oc exec -n "$GUIDELLM_NS" "$GUIDELLM_POD" \
  -c "$GUIDELLM_CONTAINER" -- guidellm --version \
  > "$OUT/guidellm-version.txt" 2>&1; then
  echo "error: guidellm is unavailable in $GUIDELLM_NS/$GUIDELLM_POD" >&2
  exit 1
fi

run_guidellm() {
  local remote_json=$1
  local local_json=$2
  local local_console=$3
  shift 3

  oc exec -i -n "$GUIDELLM_NS" "$GUIDELLM_POD" \
    -c "$GUIDELLM_CONTAINER" -- \
    guidellm run "$@" --output "kind=json,path=$remote_json" \
    2>&1 | tee "$local_console"
  oc cp -c "$GUIDELLM_CONTAINER" \
    "$GUIDELLM_NS/$GUIDELLM_POD:$remote_json" "$local_json"
  [[ -s "$local_json" ]] || {
    echo "error: GuideLLM JSON was not copied to $local_json" >&2
    exit 1
  }
}

if [[ "$PLACEMENT" == aligned ]]; then
  EXPECTED_TEMPLATE=qwen38-27b-tp1-aligned-roots
  EXPECTED_CLASS="same root"
else
  EXPECTED_TEMPLATE=qwen38-27b-tp1-unaligned-cross-numa-roots
  EXPECTED_CLASS="cross NUMA"
fi

SERVICE_JSON="$OUT/llminferenceservice.json"
oc get llminferenceservice "$SERVICE" -n "$NS" -o json > "$SERVICE_JSON"

python3 - "$SERVICE_JSON" "$EXPECTED_TEMPLATE" <<'PY'
import json, sys
service = json.load(open(sys.argv[1]))
expected = sys.argv[2]
decode = service["spec"]["template"]["resourceClaims"][0]["resourceClaimTemplateName"]
prefill = service["spec"]["prefill"]["template"]["resourceClaims"][0]["resourceClaimTemplateName"]
if decode != expected or prefill != expected:
    raise SystemExit(
        f"error: active service uses decode={decode}, prefill={prefill}; expected {expected}"
    )
PY

PODS_JSON="$OUT/pods-all.json"
POD_MAP="$OUT/pod-map.txt"
oc get pods -n "$NS" -o json > "$PODS_JSON"
python3 - "$PODS_JSON" "$SERVICE" > "$POD_MAP" <<'PY'
import json, sys
service = sys.argv[2]
for pod in json.load(open(sys.argv[1])).get("items", []):
    name = pod["metadata"]["name"]
    claims = pod.get("spec", {}).get("resourceClaims", [])
    if name.startswith(service + "-") and claims:
        role = "prefill" if "-prefill-" in name else "decode"
        print(role, name)
PY

PREFILL_POD=$(awk '$1 == "prefill" {print $2}' "$POD_MAP")
DECODE_POD=$(awk '$1 == "decode" {print $2}' "$POD_MAP")
[[ $(printf '%s\n' "$PREFILL_POD" | sed '/^$/d' | wc -l | tr -d ' ') == 1 ]] || {
  echo "error: expected exactly one prefill pod; see $POD_MAP" >&2
  exit 1
}
[[ $(printf '%s\n' "$DECODE_POD" | sed '/^$/d' | wc -l | tr -d ' ') == 1 ]] || {
  echo "error: expected exactly one decode pod; see $POD_MAP" >&2
  exit 1
}

oc wait -n "$NS" --for=condition=Ready "pod/$PREFILL_POD" "pod/$DECODE_POD" --timeout=10m

PREFILL_NODE=$(oc get pod "$PREFILL_POD" -n "$NS" -o jsonpath='{.spec.nodeName}')
DECODE_NODE=$(oc get pod "$DECODE_POD" -n "$NS" -o jsonpath='{.spec.nodeName}')
GUIDELLM_NODE=$(oc get pod "$GUIDELLM_POD" -n "$GUIDELLM_NS" -o jsonpath='{.spec.nodeName}')
if [[ "$GUIDELLM_NODE" == "$PREFILL_NODE" || "$GUIDELLM_NODE" == "$DECODE_NODE" ]]; then
  echo "error: GuideLLM pod is on benchmark node $GUIDELLM_NODE; move it to another node" >&2
  exit 1
fi
ALL_CLUSTER_PODS_JSON=$(mktemp)
trap 'rm -f "$ALL_CLUSTER_PODS_JSON"' EXIT
oc get pods -A -o json > "$ALL_CLUSTER_PODS_JSON"
if ! python3 - "$ALL_CLUSTER_PODS_JSON" "$PREFILL_NODE" "$DECODE_NODE" \
  "$NS/$PREFILL_POD" "$NS/$DECODE_POD" \
  > "$OUT/competing-workloads.txt" <<'PY'
import json, sys

pods_path, *arguments = sys.argv[1:]
target_nodes = set(arguments[:2])
benchmark_pods = set(arguments[2:])
competitors = []
for pod in json.load(open(pods_path)).get("items", []):
    spec = pod.get("spec", {})
    if spec.get("nodeName") not in target_nodes:
        continue
    identity = f"{pod['metadata'].get('namespace', 'default')}/{pod['metadata']['name']}"
    if identity in benchmark_pods or pod.get("status", {}).get("phase") in {"Succeeded", "Failed"}:
        continue
    reasons = []
    if spec.get("resourceClaims"):
        reasons.append("DRA resourceClaims")
    containers = spec.get("initContainers", []) + spec.get("containers", [])
    if any(
        float(container.get("resources", {}).get(kind, {}).get("nvidia.com/gpu", 0)) > 0
        for container in containers
        for kind in ("requests", "limits")
    ):
        reasons.append("nvidia.com/gpu")
    if reasons:
        competitors.append(
            f"{identity}\tnode={spec.get('nodeName')}\t{','.join(reasons)}"
        )

if competitors:
    print("Potentially competing workloads:")
    print("\n".join(sorted(competitors)))
    raise SystemExit(1)
print("No other active GPU- or DRA-consuming pods found on the two benchmark nodes.")
PY
then
  echo "error: competing workloads found; see $OUT/competing-workloads.txt" >&2
  exit 1
fi

{
  echo "placement=$PLACEMENT"
  echo "namespace=$NS"
  echo "service=$SERVICE"
  echo "prefill_pod=$PREFILL_POD"
  echo "decode_pod=$DECODE_POD"
  echo "prefill_node=$PREFILL_NODE"
  echo "decode_node=$DECODE_NODE"
  echo "llmisvc_url=$LLMISVC_URL"
  echo "guidellm_pod=$GUIDELLM_NS/$GUIDELLM_POD"
  echo "guidellm_node=$GUIDELLM_NODE"
  echo "concurrency=$CONCURRENCY"
  echo "prompt_tokens=$PROMPT_TOKENS"
  echo "prompt_token_distribution=fixed"
  echo "output_tokens=$OUTPUT_TOKENS"
  echo "output_token_distribution=fixed"
  echo "requests_per_repetition=$REQUESTS"
  echo "repetitions=$REPETITIONS"
  echo "seed_base=$SEED_BASE"
  echo "metrics_ports=$METRICS_PORTS"
  echo "expected_claim_template=$EXPECTED_TEMPLATE"
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/run-metadata.txt"

oc version -o yaml > "$OUT/oc-version.yaml" 2>&1 || true
oc get clusterversion -o yaml > "$OUT/cluster-version.yaml" 2>&1 || true
oc get nodes a100-04 a100-06 -o wide > "$OUT/nodes.txt"
{
  oc get pods -A --field-selector "spec.nodeName=$PREFILL_NODE" -o wide
  if [[ "$DECODE_NODE" != "$PREFILL_NODE" ]]; then
    oc get pods -A --field-selector "spec.nodeName=$DECODE_NODE" -o wide
  fi
} > "$OUT/node-workloads.txt"
oc get llminferenceservice "$SERVICE" -n "$NS" -o yaml > "$OUT/llminferenceservice.yaml"
oc get pods "$PREFILL_POD" "$DECODE_POD" -n "$NS" -o yaml > "$OUT/pods.yaml"
oc get pod "$GUIDELLM_POD" -n "$GUIDELLM_NS" -o yaml > "$OUT/guidellm-pod.yaml"
oc get resourceclaims -n "$NS" -o yaml > "$OUT/resourceclaims.yaml"
oc get resourceclaimtemplates "$EXPECTED_TEMPLATE" -n "$NS" -o yaml > "$OUT/resourceclaimtemplate.yaml"

"$SCRIPT_DIR/report-dra-allocation.py" "$SERVICE" -n "$NS" > "$OUT/allocation.md"
"$SCRIPT_DIR/report-dra-allocation.py" "$SERVICE" -n "$NS" --json > "$OUT/allocation.json"

python3 - "$OUT/allocation.json" "$EXPECTED_CLASS" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
expected = sys.argv[2]
pods = report.get("pods", [])
if len(pods) != 2:
    raise SystemExit(f"error: expected two model pods in allocation report, found {len(pods)}")
bad = []
for pod in pods:
    counts = pod.get("gpu_nic_alignment", {})
    if pod.get("tp") != 1 or counts.get(expected, 0) != 1:
        bad.append(f"{pod.get('pod')}: TP={pod.get('tp')} alignment={counts}")
if bad:
    raise SystemExit("error: allocation does not match requested placement:\n" + "\n".join(bad))
PY

for entry in "prefill:$PREFILL_POD" "decode:$DECODE_POD"; do
  role=${entry%%:*}
  pod=${entry#*:}
  set +e
  oc exec -i -n "$NS" "$pod" -c main -- bash -s \
    < "$SCRIPT_DIR/validate-pod-gpu-nic-alignment.sh" \
    > "$OUT/topology-$role.txt" 2>&1
  validation_status=$?
  set -e
  if [[ "$PLACEMENT" == aligned && $validation_status -ne 0 ]]; then
    echo "error: aligned in-pod topology validation failed; see topology-$role.txt" >&2
    exit 1
  fi
  echo "validator_exit_status=$validation_status" >> "$OUT/topology-$role.txt"
done

capture_metrics() {
  local suffix=$1
  set +e
  oc exec -i -n "$NS" "$DECODE_POD" -c main -- \
    python3 - "$METRICS_PORTS" > "$OUT/metrics-$suffix.prom" \
    2> "$OUT/metrics-$suffix.stderr" <<'PY'
import ssl, sys, urllib.request
ports = sys.argv[1].split()
errors = []
found = False
for port in ports:
    for scheme in ("https", "http"):
        url = f"{scheme}://127.0.0.1:{port}/metrics"
        try:
            context = ssl._create_unverified_context() if scheme == "https" else None
            payload = urllib.request.urlopen(url, context=context, timeout=10).read()
            sys.stdout.write(payload.decode())
            sys.stderr.write(f"captured {url}\n")
            found = True
            break
        except Exception as exc:
            errors.append(f"{url}: {exc}")
    if found:
        break
if not found:
    raise SystemExit("; ".join(errors))
PY
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    echo "Prometheus endpoint snapshot unavailable; see metrics-$suffix.stderr" >&2
  fi
}

echo "Running warm-up workload..."
run_guidellm \
  "/results/tp1-kv-${STAMP}-${PLACEMENT}-warmup.json" \
  "$OUT/guidellm-warmup.json" \
  "$OUT/guidellm-warmup.txt" \
  --backend "kind=openai_http,target=$LLMISVC_URL" \
  --profile kind=concurrent,streams=2 \
  --data kind=synthetic_text,prompt_tokens=1024,output_tokens=16 \
  --constraint kind=max_requests,count=8 \
  --seed kind=static,value=41999

# Keep warm-up transfer summaries outside the measured log interval.
sleep 15
capture_metrics before

: > "$OUT/decode-benchmark-all.log"
: > "$OUT/prefill-benchmark-all.log"

rep=1
while [[ $rep -le $REPETITIONS ]]; do
  rep_id=$(printf '%02d' "$rep")
  rep_dir="$OUT/repetitions/$rep_id"
  mkdir -p "$rep_dir"
  start_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  run_seed=$((SEED_BASE + rep))
  echo "$start_time" > "$rep_dir/start-time.txt"
  echo "$run_seed" > "$rep_dir/seed.txt"
  echo "Running measured repetition $rep/$REPETITIONS..."

  run_guidellm \
    "/results/tp1-kv-${STAMP}-${PLACEMENT}-rep-${rep_id}.json" \
    "$rep_dir/guidellm.json" \
    "$rep_dir/guidellm.txt" \
    --backend "kind=openai_http,target=$LLMISVC_URL" \
    --profile "kind=concurrent,streams=$CONCURRENCY" \
    --data "kind=synthetic_text,prompt_tokens=$PROMPT_TOKENS,output_tokens=$OUTPUT_TOKENS" \
    --constraint "kind=max_requests,count=$REQUESTS" \
    --seed "kind=static,value=$run_seed"

  # vLLM emits the KV-transfer summary periodically; allow its last interval
  # to be logged before collecting this repetition.
  sleep 15
  oc logs -n "$NS" "$DECODE_POD" -c main --since-time="$start_time" \
    > "$rep_dir/decode.log"
  oc logs -n "$NS" "$PREFILL_POD" -c main --since-time="$start_time" \
    > "$rep_dir/prefill.log"
  grep 'KV Transfer metrics:' "$rep_dir/decode.log" \
    > "$rep_dir/kv-transfer-lines.txt"
  "$SCRIPT_DIR/summarize-kv-transfer-logs.py" "$rep_dir/decode.log" \
    > "$rep_dir/kv-summary.json"
  "$SCRIPT_DIR/summarize-kv-transfer-logs.py" "$rep_dir/decode.log" \
    --format markdown --label "$PLACEMENT repetition $rep" \
    > "$rep_dir/kv-summary.md"
  printf '\n### repetition %s\n' "$rep" >> "$OUT/decode-benchmark-all.log"
  sed -n '/KV Transfer metrics:/p' "$rep_dir/decode.log" \
    >> "$OUT/decode-benchmark-all.log"
  printf '\n### repetition %s\n' "$rep" >> "$OUT/prefill-benchmark-all.log"
  sed -n '/KV Transfer metrics:/p' "$rep_dir/prefill.log" \
    >> "$OUT/prefill-benchmark-all.log"
  rep=$((rep + 1))
done

capture_metrics after
set +e
"$SCRIPT_DIR/summarize-nixl-prometheus.py" \
  "$OUT/metrics-before.prom" "$OUT/metrics-after.prom" \
  > "$OUT/prometheus-summary.json" 2> "$OUT/prometheus-summary.stderr"
prometheus_summary_status=$?
set -e
if [[ $prometheus_summary_status -ne 0 ]]; then
  rm -f "$OUT/prometheus-summary.json"
  echo "Prometheus NIXL summary unavailable; logs remain the primary source." >&2
fi
oc logs -n "$NS" "$DECODE_POD" -c main > "$OUT/decode-full.log"
oc logs -n "$NS" "$PREFILL_POD" -c main > "$OUT/prefill-full.log"
grep 'KV Transfer metrics:' "$OUT/decode-benchmark-all.log" \
  > "$OUT/kv-transfer-lines.txt"
"$SCRIPT_DIR/summarize-kv-transfer-logs.py" "$OUT/decode-benchmark-all.log" \
  > "$OUT/kv-summary.json"
"$SCRIPT_DIR/summarize-kv-transfer-logs.py" "$OUT/decode-benchmark-all.log" \
  --format markdown --label "$PLACEMENT combined" > "$OUT/kv-summary.md"
oc get events -n "$NS" --sort-by=.lastTimestamp > "$OUT/events.txt" 2>&1 || true
echo "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT/run-metadata.txt"

cp "$SCRIPT_DIR/benchmark-device-claims-tp1.yaml" "$OUT/"
if [[ "$PLACEMENT" == aligned ]]; then
  cp "$SCRIPT_DIR/llmisvc-tp1-aligned.yaml" "$OUT/"
else
  cp "$SCRIPT_DIR/llmisvc-tp1-unaligned.yaml" "$OUT/"
fi
mkdir -p "$OUT/collection-tools"
cp \
  "$SCRIPT_DIR/run-tp1-kv-benchmark.sh" \
  "$SCRIPT_DIR/summarize-kv-transfer-logs.py" \
  "$SCRIPT_DIR/summarize-nixl-prometheus.py" \
  "$SCRIPT_DIR/report-dra-allocation.py" \
  "$SCRIPT_DIR/validate-pod-gpu-nic-alignment.sh" \
  "$OUT/collection-tools/"

{
  echo "# TP1 KV-transfer benchmark: $PLACEMENT"
  echo
  echo "This directory is a raw and derived result bundle produced by"
  echo '`run-tp1-kv-benchmark.sh`.'
  echo
  echo '## Workload'
  echo
  echo "- Concurrency: ${CONCURRENCY}"
  echo "- Prompt tokens: ${PROMPT_TOKENS} (fixed)"
  echo "- Output tokens: ${OUTPUT_TOKENS} (fixed)"
  echo "- Requests: ${REQUESTS} per repetition"
  echo "- Repetitions: ${REPETITIONS}"
  echo
  echo '## Combined result'
  echo
  sed '1,2d' "$OUT/kv-summary.md"
  echo
  echo 'See `allocation.md`, `topology-prefill.txt`, and'
  echo '`topology-decode.txt` for allocation evidence. Per-repetition raw logs,'
  echo 'GuideLLM output, and summaries are under `repetitions/`.'
  echo 'The node contention audit is in `competing-workloads.txt`; exact copies'
  echo 'of the collection and parsing tools are under `collection-tools/`.'
  if [[ -f "$OUT/prometheus-summary.json" ]]; then
    echo
    echo 'A before/after NIXL histogram delta is available in'
    echo '`prometheus-summary.json` as an independent check of the log summary.'
  fi
} > "$OUT/README.md"

echo
echo "Result bundle complete: $OUT"
echo "Combined summary: $OUT/kv-summary.md"
