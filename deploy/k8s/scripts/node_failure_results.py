"""Node experiment identity gates and evidence; shared k6 calculations stay in failure_results."""
import copy
import datetime as dt
import json
import pathlib
import re
import sys

import failure_results as f


def target(tf, key):
    apps = [k for k, role in tf["roles"].items() if role == "app"]
    if key not in apps or len(apps) != 2 or len(set(tf["ids"].values())) != len(tf["ids"]) or tf["ids"][key] == tf["cp"]:
        raise ValueError("Target must be one of two distinct Terraform app workers")
    other = next(k for k in apps if k != key)
    result = dict(key=key, instance=tf["ids"][key], node=tf["hosts"][key], other=tf["hosts"][other], ip=tf["ips"][key])
    if not all(re.fullmatch(r"[a-zA-Z0-9.-]+", v) for v in result.values()):
        raise ValueError("Unsafe target identity")
    return result


def quantity(value):
    match = re.fullmatch(r"([0-9.]+)([a-zA-Z]*)", str(value))
    return float(match[1]) * {"": 1, "m": .001, "Ki": 1024, "Mi": 1024**2, "Gi": 1024**3}[match[2]]


def preflight(data, ctx):
    f.state(data)
    deployments = {p["metadata"]["name"]: p for p in data["items"] if p["kind"] == "Deployment"}
    spread = deployments["beach"]["spec"]["template"]["spec"]["topologySpreadConstraints"]
    if not any(s.get("nodeTaintsPolicy") == "Honor" for s in spread):
        raise ValueError("Apply Beach nodeTaintsPolicy Honor before injecting")
    dependency_revision = deployments["postgres"]["spec"]["template"].get("metadata", {}).get("labels", {}).get("dependency-revision")
    if not dependency_revision or deployments["redis"]["spec"]["template"].get("metadata", {}).get("labels", {}).get("dependency-revision") != dependency_revision:
        raise ValueError("Apply matching nonempty dependency revisions before injecting")
    for name in ["postgres", "redis"]:
        spec = deployments[name]["spec"]["template"]["spec"]
        constraints = spec.get("topologySpreadConstraints", [])
        expected = dict(maxSkew=1, topologyKey="kubernetes.io/hostname", whenUnsatisfiable="DoNotSchedule", nodeTaintsPolicy="Honor", matchLabelKeys=["dependency-revision"],
                        labelSelector=dict(matchExpressions=[dict(key="app.kubernetes.io/name", operator="In", values=["postgres", "redis"])]))
        if (len(constraints) != 1 or any(constraints[0].get(k) != v for k, v in expected.items()) or
                constraints[0].get("minDomains", 1) != 1 or
                spec.get("affinity", {}).get("podAntiAffinity", {}).get("requiredDuringSchedulingIgnoredDuringExecution")):
            raise ValueError("Apply joint dependency topology spread with single-node recovery before injecting")
    nodes = {x["metadata"]["name"]: x for x in data["items"] if x["kind"] == "Node"}
    for name in [ctx["node"], ctx["other"]]:
        if nodes[name]["metadata"]["labels"].get("node-role") != "app" or nodes[name].get("spec", {}).get("unschedulable"):
            raise ValueError("Target and survivor must be schedulable app workers")
    if ctx["ip"] not in [a["address"] for a in nodes[ctx["node"]]["status"]["addresses"] if a["type"] == "InternalIP"]:
        raise ValueError("Terraform and Kubernetes target IP differ")
    deps = [p for p in data["items"] if p["kind"] == "Pod" and p["metadata"]["labels"].get("app.kubernetes.io/name") in ("postgres", "redis")]
    if len(deps) != 2 or {p["spec"]["nodeName"] for p in deps} != {ctx["node"], ctx["other"]} or not all(ready(p) for p in deps):
        raise ValueError("Dependencies must be ready and distributed")
    pods = [p for p in data["all_pods"] if p.get("status", {}).get("phase") not in ("Failed", "Succeeded") and
            (p["spec"].get("nodeName") == ctx["other"] or (p["spec"].get("nodeName") == ctx["node"] and not any(o["kind"] == "DaemonSet" for o in p["metadata"].get("ownerReferences", []))))]
    for resource in ["cpu", "memory", "pods"]:
        needed = 0
        for pod in pods:
            requests = lambda c: quantity(c.get("resources", {}).get("requests", {}).get(resource, "0"))
            steady = sum(requests(c) for c in pod["spec"].get("containers", []))
            initial = max([requests(c) for c in pod["spec"].get("initContainers", [])] + [0])
            needed += 1 if resource == "pods" else max(steady, initial) + quantity(pod["spec"].get("overhead", {}).get(resource, "0"))
        if needed > quantity(nodes[ctx["other"]]["status"]["allocatable"][resource]):
            raise ValueError("Surviving worker has insufficient allocatable " + resource)


def ready(pod):
    return not pod["metadata"].get("deletionTimestamp") and any(c["type"] == "Ready" and c["status"] == "True" for c in pod.get("status", {}).get("conditions", []))


def observe(data, before, ctx):
    node = next(x for x in data["items"] if x["kind"] == "Node" and x["metadata"]["name"] == ctx["node"])
    detected = any(c["type"] == "Ready" and c["status"] in ("False", "Unknown") for c in node["status"]["conditions"])
    old = {p["metadata"]["uid"] for p in before["items"] if p["kind"] == "Pod" and p["spec"].get("nodeName") == ctx["node"]}
    endpoints = {e.get("targetRef", {}).get("uid") for s in data["items"] if s["kind"] == "EndpointSlice" and s["metadata"]["labels"].get("kubernetes.io/service-name") == "beach"
                 for e in s.get("endpoints", []) if e.get("conditions", {}).get("ready") is not False and not e.get("conditions", {}).get("terminating")}
    removed = not old.intersection(endpoints)
    current = [p for p in data["items"] if p["kind"] == "Pod" and p["metadata"]["labels"].get("app.kubernetes.io/name") in ("beach", "postgres", "redis") and not p["metadata"].get("deletionTimestamp")]
    restored = detected and removed and len(current) == 4 and all(ready(p) and p["spec"].get("nodeName") == ctx["other"] and p["metadata"]["uid"] not in old for p in current)
    if restored:
        trimmed = copy.deepcopy(data)
        trimmed["items"] = [p for p in trimmed["items"] if p["kind"] != "Pod" or not p["metadata"].get("deletionTimestamp")]
        survivor = next(p["metadata"]["uid"] for p in before["items"] if p["kind"] == "Pod" and p["spec"].get("nodeName") == ctx["other"] and p["metadata"]["labels"].get("app.kubernetes.io/name") == "beach")
        try: f.state(trimmed, next(iter(old)), survivor)
        except (ValueError, KeyError, StopIteration): restored = False
    return detected, removed, restored


def summarize(raw):
    result = f.summarize(raw)
    marks = dict(line.split("=", 1) for line in raw.splitlines() if "=" in line and not line.startswith("{"))
    times = {k: f.timestamp(marks[k]) for k in ("t0", "node_detected", "endpoint_removed", "replacement_ready", "restart_requested", "final_state_verified") if k in marks}
    complete = len(times) == 6 and times["t0"] <= times["node_detected"] <= times["replacement_ready"] < times["restart_requested"] < times["final_state_verified"] and times["t0"] <= times["endpoint_removed"] <= times["replacement_ready"]
    boundary = f.timestamp(result["recovery_boundary_utc"]) if result["recovery_boundary_utc"] else None
    result["passed"] = bool(result["passed"] and complete and boundary is not None and boundary < times["restart_requested"])
    for key, mark in [("detection_seconds", "node_detected"), ("endpoint_seconds", "endpoint_removed")]:
        result[key] = times[mark] - times["t0"] if mark in times and "t0" in times else None
    mitigation = f.summarize(raw + "\nreplacement_ready=" + marks["endpoint_removed"]) if "endpoint_removed" in marks else {}
    result["api_stable_utc"] = mitigation.get("recovery_boundary_utc")
    result["mitigation_seconds"] = f.timestamp(result["api_stable_utc"]) - times["t0"] if result["api_stable_utc"] else None
    result["recovery_seconds"] = boundary - times["t0"] if boundary else None
    result["clock_caveat"] = "t0/restart: operator clock; node observations: CP; request samples: obs-1; offsets unverified"
    return result


def final(data, before, ctx):
    nodes = {p["metadata"]["name"]: p for p in data["items"] if p["kind"] == "Node"}
    if not all(name in nodes and ready(nodes[name]) and nodes[name]["metadata"]["labels"].get("node-role") == "app" for name in (ctx["node"], ctx["other"])) or not all(ready(p) for p in nodes.values()):
        raise ValueError("Final target/survivor or other nodes not Ready")
    for name in (ctx["node"], ctx["other"]):
        spec = nodes[name].get("spec", {})
        if spec.get("unschedulable") or any(t["key"] in ("node.kubernetes.io/unreachable", "node.kubernetes.io/not-ready", "node.cilium.io/agent-not-ready") for t in spec.get("taints", [])):
            raise ValueError("Final app worker scheduling recovery incomplete")
    if any(p["kind"] == "Pod" and p["spec"].get("nodeName") == ctx["node"] and p["metadata"].get("deletionTimestamp") for p in data["items"]):
        raise ValueError("Final target still has terminating Pods")
    if ctx["ip"] not in [a["address"] for a in nodes[ctx["node"]]["status"]["addresses"] if a["type"] == "InternalIP"]:
        raise ValueError("Restarted target Node IP mismatch")
    trimmed = copy.deepcopy(data)
    trimmed["items"] = [p for p in data["items"] if p["kind"] != "Pod" or not p["metadata"].get("deletionTimestamp")]
    old = next(p["metadata"]["uid"] for p in before["items"] if p["kind"] == "Pod" and p["spec"].get("nodeName") == ctx["node"] and p["metadata"]["labels"].get("app.kubernetes.io/name") == "beach")
    survivor = next(p["metadata"]["uid"] for p in before["items"] if p["kind"] == "Pod" and p["spec"].get("nodeName") == ctx["other"] and p["metadata"]["labels"].get("app.kubernetes.io/name") == "beach")
    f.state(trimmed, old, survivor)
    for name, count in [("postgres", 1), ("redis", 1)]:
        pods = [p for p in trimmed["items"] if p["kind"] == "Pod" and p["metadata"]["labels"].get("app.kubernetes.io/name") == name]
        if len(pods) != count or not all(ready(p) for p in pods): raise ValueError("Final dependency Pod not Ready")


if __name__ == "__main__":
    mode, directory = sys.argv[1], pathlib.Path(sys.argv[2])
    load = lambda name: json.loads((directory / name).read_text())
    if mode == "target":
        tf = {key: load(name + ".json") for key, name in [("ids", "node_instance_ids"), ("hosts", "node_hostnames"), ("roles", "node_roles"), ("ips", "node_private_ips")]}
        tf["cp"] = sys.argv[4]
        print(json.dumps(target(tf, sys.argv[3])))
    elif mode == "aws":
        ctx = load("context.json")
        instances = [i for r in load("aws-before.json")["Reservations"] for i in r["Instances"]]
        if len(instances) != 1 or (instances[0]["InstanceId"], instances[0]["PrivateIpAddress"], instances[0]["State"]["Name"], instances[0]["RootDeviceType"]) != (ctx["instance"], ctx["ip"], "running", "ebs"):
            raise ValueError("AWS target identity/state mismatch")
    elif mode == "preflight": preflight(load("state.json"), load("context.json"))
    elif mode == "snapshot": print(json.dumps(dict(event="snapshot", time=dt.datetime.now(dt.timezone.utc).isoformat(), data=load("state.json"))), flush=True)
    elif mode == "final": final(load("state.json"), load("before.json"), load("context.json"))
    elif mode == "observe":
        flags = observe(load("state.json"), load("before.json"), load("context.json"))
        for key, seen in zip(["node_detected", "endpoint_removed", "replacement_ready"], flags):
            marker = directory / key
            if seen and not marker.exists():
                stamp = dt.datetime.now(dt.timezone.utc).isoformat()
                marker.write_text(stamp); print(key + "=" + stamp, flush=True)
        sys.exit(0 if all(flags) else 1)
    else:
        result = summarize((directory / "remote-output.txt").read_text())
        print(json.dumps(result, indent=2)); sys.exit(0 if result["passed"] else 1)
