# Reproducible TP1 KV-transfer comparison

This procedure produces GitHub-ready evidence for the Qwen3.8-27B TP1
same-root versus cross-NUMA KV-transfer comparison. It uses one workload point:

- concurrency 10;
- exactly 16,000 prompt tokens and 64 output tokens per request;
- 128 requests per repetition;
- three repetitions per placement.

The claim templates in this directory deliberately select known PCIe roots so
both placements use the same GPU locality during the controlled comparison.
For a portable application example that simply requests an aligned GPU and VF,
see [`../02-ib-write-bw/aligned-resourceclaimtemplate.yaml`](../02-ib-write-bw/aligned-resourceclaimtemplate.yaml).

The defaults can be overridden with `CONCURRENCY`, `PROMPT_TOKENS`,
`OUTPUT_TOKENS`, `REQUESTS`, `REPETITIONS`, `SEED_BASE`, and `METRICS_PORTS`.
Keep workload settings identical for both placements. Repetition `N` uses seed
`SEED_BASE + N`: prompts therefore differ between repetitions but are exactly
reproducible and paired between the two placements. Prometheus capture tries
ports `8000`, `8001`, and `8080` by default and is optional.

The collector saves raw vLLM logs and GuideLLM output, DRA objects, allocation
reports, in-pod topology validation, software versions, optional before/after
Prometheus endpoint snapshots and their NIXL histogram delta, per-repetition
summaries, and a combined transfer-count-weighted summary. It checks that both
model pods actually have the requested placement before generating results. It
also refuses to run if another active pod on either benchmark node uses a DRA
claim or requests `nvidia.com/gpu`, and saves the node workload listing and
contention-check result.

GuideLLM runs inside the `guidellm` pod in the benchmark namespace. Its console
output is streamed into the local bundle. The large per-request JSON files
remain on the pod's ephemeral `/results` volume and are not copied into the
publication bundle. Override `GUIDELLM_NS`, `GUIDELLM_POD`, or
`GUIDELLM_CONTAINER` if that pod has a different location or name. To avoid
load-generator contention, the collector refuses to run when the GuideLLM pod
is scheduled on either GPU benchmark node.

## One-time setup

This procedure expects an existing `dra-sriov-test` namespace, the cluster
configuration documented in `../01-cluster-configuration/`, KServe
`LLMInferenceService`, and the `lvms-a100-tier1-storage` storage class. Adapt
the namespace, node names, and storage class for another cluster.

```bash
export KUBECONFIG=/path/to/your/kubeconfig
export NS=dra-sriov-test

oc apply -f model-cache-pvcs.yaml
oc apply -f benchmark-device-claims-tp1.yaml
```

Ensure other GPU workloads, including the `sriov-test` and `ib-write-bw` pods,
are absent from `a100-04` and `a100-06`.

Ensure the GuideLLM pod is running in the same namespace:

```bash
oc apply -n "$NS" -f guidellm-pod.yaml
oc wait -n "$NS" --for=condition=Ready pod/guidellm --timeout=5m
```

The provided pod manifest excludes `a100-04` and `a100-06`. If an older
GuideLLM pod already exists on either node, delete it before applying the
updated manifest because pod affinity is immutable.

## Aligned run

Delete any prior service and wait for its generated pods and ResourceClaims to
disappear:

```bash
oc delete llmisvc qwen38-27b-pd-tp1 -n "$NS" --ignore-not-found
oc get pod,resourceclaim -n "$NS" -w
```

Apply the aligned service and wait until both model pods are ready:

```bash
oc apply -f llmisvc-tp1-aligned.yaml
oc get llmisvc,pod,resourceclaim -n "$NS" -w
```

Run the collector. Do not send other requests to this service while it runs.

```bash
./run-tp1-kv-benchmark.sh aligned results/aligned
```

## Cross-NUMA run

Delete the aligned service and wait for all generated claims to disappear,
then apply the cross-NUMA service:

```bash
oc delete llmisvc qwen38-27b-pd-tp1 -n "$NS"
oc get pod,resourceclaim -n "$NS" -w
oc apply -f llmisvc-tp1-unaligned.yaml
oc get llmisvc,pod,resourceclaim -n "$NS" -w
```

Run the identical workload:

```bash
./run-tp1-kv-benchmark.sh cross-numa results/cross-numa
```

## Produce the comparison

```bash
./compare-kv-transfer-results.py \
  results/aligned/kv-summary.json \
  results/cross-numa/kv-summary.json \
  > results/COMPARISON.md
```

Review the allocation and topology files before publishing:

```bash
sed -n '1,240p' results/aligned/allocation.md
sed -n '1,240p' results/cross-numa/allocation.md
cat results/COMPARISON.md
```

The raw decoder logs remain the source data. The summaries reconstruct mean
latency and effective throughput from vLLM's periodic metrics using successful
transfer counts as weights. They intentionally do not claim a run-wide P90,
which cannot be reconstructed from interval P90 values.
