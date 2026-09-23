#!/usr/bin/env python3
"""Report pod-level TP GPU locality and rank-level GPU/NIC DRA alignment.

The script is read-only. It joins ResourceClaim allocations to ResourceSlice
attributes and derives GPU NUMA placement from the SR-IOV devices' shared
pcieRoot -> dra.net/numaNode mapping.
"""

from __future__ import annotations

import argparse
import datetime as dt
import itertools
import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from typing import Any


GPU_DRIVER = "gpu.nvidia.com"
SRIOV_DRIVER = "sriovnetwork.k8snetworkplumbingwg.io"
PCIE_ROOT = "resource.kubernetes.io/pcieRoot"
PCI_BUS_ID = "resource.kubernetes.io/pciBusID"
NUMA_NODE = "dra.net/numaNode"
PF_PCI = "sriovnetwork.k8snetworkplumbingwg.io/pfPciAddress"


def oc_json(*args: str) -> dict[str, Any]:
    command = ["oc", *args, "-o", "json"]
    try:
        result = subprocess.run(
            command, check=True, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
    except FileNotFoundError:
        raise SystemExit("error: oc was not found in PATH")
    except subprocess.CalledProcessError as exc:
        message = exc.stderr.strip() or exc.stdout.strip()
        raise SystemExit(f"error: {' '.join(command)} failed: {message}")
    return json.loads(result.stdout)


def attr_value(attributes: dict[str, Any], key: str) -> Any:
    value = attributes.get(key)
    if not isinstance(value, dict):
        return None
    for value_type in ("string", "int", "bool", "version", "quantity"):
        if value_type in value:
            return value[value_type]
    return None


def readiness(pod: dict[str, Any]) -> str:
    status = pod.get("status", {})
    statuses = list(status.get("containerStatuses", []))
    # Restartable init containers are sidecars and are included in kubectl/oc's
    # READY denominator (for example, llm-d-routing-sidecar).
    restartable_init_names = {
        container.get("name")
        for container in pod.get("spec", {}).get("initContainers", [])
        if container.get("restartPolicy") == "Always"
    }
    statuses.extend(
        container_status
        for container_status in status.get("initContainerStatuses", [])
        if container_status.get("name") in restartable_init_names
    )
    ready = sum(bool(status.get("ready")) for status in statuses)
    return f"{ready}/{len(statuses)}"


def role_for(pod_name: str) -> str:
    return "prefill" if "-prefill-" in pod_name else "decode"


def request_rank(request: str, kind: str) -> int | None:
    match = re.fullmatch(rf"{kind}(?:-(\d+))?", request)
    if not match:
        return None
    return int(match.group(1) or 0)


def placement_class(gpu: dict[str, Any], vf: dict[str, Any]) -> str:
    if gpu["root"] and gpu["root"] == vf["root"]:
        return "same root"
    if gpu["numa"] is not None and gpu["numa"] == vf["numa"]:
        return "same NUMA, different root"
    if gpu["numa"] is not None and vf["numa"] is not None:
        return "cross NUMA"
    return "unknown"


def analyze(namespace: str, service: str) -> dict[str, Any]:
    pods_json = oc_json("get", "pods", "-n", namespace)
    claims_json = oc_json("get", "resourceclaims", "-n", namespace)
    slices_json = oc_json("get", "resourceslices")

    pods = {
        pod["metadata"]["name"]: pod
        for pod in pods_json.get("items", [])
        if pod["metadata"]["name"].startswith(service + "-")
    }

    devices: dict[tuple[str, str, str], dict[str, Any]] = {}
    root_numa: dict[tuple[str, str], int] = {}
    root_numa_conflicts: list[str] = []

    for resource_slice in slices_json.get("items", []):
        spec = resource_slice.get("spec", {})
        driver = spec.get("driver")
        pool = spec.get("pool", {}).get("name")
        if not driver or not pool:
            continue
        for device in spec.get("devices", []):
            attributes = device.get("attributes", {})
            info = {
                "driver": driver,
                "pool": pool,
                "device": device.get("name"),
                "root": attr_value(attributes, PCIE_ROOT),
                "numa": attr_value(attributes, NUMA_NODE),
                "pci": attr_value(attributes, PCI_BUS_ID),
                "pf": attr_value(attributes, PF_PCI),
            }
            devices[(driver, pool, device.get("name"))] = info
            if info["root"] and info["numa"] is not None:
                key = (pool, info["root"])
                previous = root_numa.get(key)
                if previous is not None and previous != info["numa"]:
                    root_numa_conflicts.append(
                        f"{pool}/{info['root']}: NUMA {previous} and {info['numa']}"
                    )
                root_numa[key] = info["numa"]

    reports = []
    unallocated = []
    for claim in claims_json.get("items", []):
        owners = claim.get("metadata", {}).get("ownerReferences", [])
        pod_name = next(
            (owner.get("name") for owner in owners if owner.get("kind") == "Pod"),
            None,
        )
        if not pod_name or not pod_name.startswith(service + "-"):
            continue

        results = (
            claim.get("status", {}).get("allocation", {})
            .get("devices", {}).get("results", [])
        )
        if not results:
            unallocated.append({"pod": pod_name, "claim": claim["metadata"]["name"]})
            continue

        ranks: dict[int, dict[str, Any]] = defaultdict(dict)
        for result in results:
            driver = result.get("driver")
            kind = "gpu" if driver == GPU_DRIVER else "vf" if driver == SRIOV_DRIVER else None
            if kind is None:
                continue
            rank = request_rank(result.get("request", ""), kind)
            if rank is None:
                continue
            key = (driver, result.get("pool"), result.get("device"))
            info = dict(devices.get(key, {}))
            info.update({
                "driver": driver,
                "pool": result.get("pool"),
                "device": result.get("device"),
                "request": result.get("request"),
            })
            if info.get("numa") is None and info.get("root"):
                info["numa"] = root_numa.get((info["pool"], info["root"]))
            ranks[rank][kind] = info

        rank_reports = []
        for rank in sorted(ranks):
            gpu = ranks[rank].get("gpu")
            vf = ranks[rank].get("vf")
            if not gpu or not vf:
                continue
            rank_reports.append({
                "rank": rank,
                "gpu": gpu,
                "vf": vf,
                "alignment": placement_class(gpu, vf),
            })

        gpu_infos = [rank["gpu"] for rank in rank_reports]
        pair_counts: Counter[str] = Counter()
        for left, right in itertools.combinations(gpu_infos, 2):
            if left.get("root") and left["root"] == right.get("root"):
                pair_counts["same root"] += 1
            elif left.get("numa") is not None and left["numa"] == right.get("numa"):
                pair_counts["same NUMA, different root"] += 1
            elif left.get("numa") is not None and right.get("numa") is not None:
                pair_counts["cross NUMA"] += 1
            else:
                pair_counts["unknown"] += 1

        pod = pods.get(pod_name, {})
        reports.append({
            "role": role_for(pod_name),
            "pod": pod_name,
            "node": pod.get("spec", {}).get("nodeName") or (
                rank_reports[0]["gpu"]["pool"] if rank_reports else "unknown"
            ),
            "ready": readiness(pod) if pod else "unknown",
            "phase": pod.get("status", {}).get("phase", "unknown"),
            "tp": len(rank_reports),
            "gpu_numa": dict(Counter(
                str(gpu.get("numa")) if gpu.get("numa") is not None else "unknown"
                for gpu in gpu_infos
            )),
            "gpu_roots": dict(Counter(gpu.get("root") or "unknown" for gpu in gpu_infos)),
            "gpu_pair_locality": dict(pair_counts),
            "gpu_nic_alignment": dict(Counter(rank["alignment"] for rank in rank_reports)),
            "ranks": rank_reports,
        })

    reports.sort(key=lambda report: (report["role"] != "decode", report["pod"]))
    overall = Counter(
        rank["alignment"] for report in reports for rank in report["ranks"]
    )

    pf_by_node: dict[str, list[str]] = defaultdict(list)
    for report in reports:
        for rank in report["ranks"]:
            pf = rank["vf"].get("pf")
            if pf:
                pf_by_node[report["node"]].append(pf)
    pf_summary = {}
    for node, pfs in sorted(pf_by_node.items()):
        duplicates = sorted(pf for pf, count in Counter(pfs).items() if count > 1)
        pf_summary[node] = {
            "selected": len(pfs), "unique": len(set(pfs)), "duplicates": duplicates
        }

    return {
        "generated_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "namespace": namespace,
        "service": service,
        "pods": reports,
        "overall_gpu_nic_alignment": dict(overall),
        "pf_uniqueness": pf_summary,
        "unallocated_claims": unallocated,
        "root_numa_conflicts": root_numa_conflicts,
    }


def counts_text(counts: dict[str, int], keys: list[str]) -> str:
    return ", ".join(f"{counts.get(key, 0)} {key}" for key in keys)


def markdown(report: dict[str, Any]) -> str:
    alignment_keys = ["same root", "same NUMA, different root", "cross NUMA", "unknown"]
    lines = [
        f"# DRA allocation report: {report['service']}", "",
        f"Generated: `{report['generated_at']}`  ",
        f"Namespace: `{report['namespace']}`", "", "## Pod summary", "",
        "| Role | Pod | Node | Ready | TP | GPU placement | TP GPU-pair locality | GPU/NIC alignment |",
        "|---|---|---|---:|---:|---|---|---|",
    ]
    for pod in report["pods"]:
        numa = ", ".join(
            f"NUMA {numa_node}: {count}"
            for numa_node, count in sorted(pod["gpu_numa"].items())
        )
        roots = ", ".join(f"{root}: {count}" for root, count in sorted(pod["gpu_roots"].items()))
        gpu_placement = f"{numa}; roots {roots}"
        pair_locality = counts_text(pod["gpu_pair_locality"], alignment_keys)
        alignment = counts_text(pod["gpu_nic_alignment"], alignment_keys)
        lines.append(
            f"| {pod['role']} | `{pod['pod']}` | `{pod['node']}` | "
            f"{pod['ready']} | {pod['tp']} | {gpu_placement} | {pair_locality} | {alignment} |"
        )

    lines.extend(["", "## Rank details", ""])
    for pod in report["pods"]:
        lines.extend([
            f"### {pod['role']} `{pod['pod']}`", "",
            "| Rank | GPU | GPU PCI | GPU root/NUMA | VF PCI | PF PCI | VF root/NUMA | Alignment |",
            "|---:|---|---|---|---|---|---|---|",
        ])
        for rank in pod["ranks"]:
            gpu, vf = rank["gpu"], rank["vf"]
            lines.append(
                f"| {rank['rank']} | {gpu['device']} | `{gpu.get('pci') or '-'}` | "
                f"`{gpu.get('root') or '-'}` / {gpu.get('numa')} | "
                f"`{vf.get('pci') or '-'}` | `{vf.get('pf') or '-'}` | "
                f"`{vf.get('root') or '-'}` / {vf.get('numa')} | {rank['alignment']} |"
            )
        lines.append("")

    lines.extend([
        "## Overall GPU/NIC alignment", "",
        counts_text(report["overall_gpu_nic_alignment"], alignment_keys) + ".", "",
        "## PF uniqueness", "",
    ])
    for node, summary in report["pf_uniqueness"].items():
        suffix = (
            f"; duplicate PFs: {', '.join(summary['duplicates'])}"
            if summary["duplicates"] else "; no duplicate PFs"
        )
        lines.append(
            f"- `{node}`: {summary['selected']} selected VFs, "
            f"{summary['unique']} unique PFs{suffix}."
        )
    if report["unallocated_claims"]:
        lines.extend(["", "## Unallocated claims", ""])
        for claim in report["unallocated_claims"]:
            lines.append(f"- `{claim['pod']}`: `{claim['claim']}`")
    if report["root_numa_conflicts"]:
        lines.extend(["", "## Warnings", ""])
        for warning in report["root_numa_conflicts"]:
            lines.append(f"- Conflicting root-to-NUMA mapping: {warning}")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("service", help="LLMInferenceService name / generated pod prefix")
    parser.add_argument("-n", "--namespace", default="dra-sriov-test")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of Markdown")
    args = parser.parse_args()

    report = analyze(args.namespace, args.service)
    if not report["pods"] and not report["unallocated_claims"]:
        raise SystemExit(
            f"error: no generated ResourceClaims found for {args.namespace}/{args.service}"
        )
    if args.json:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        print(markdown(report))


if __name__ == "__main__":
    main()
