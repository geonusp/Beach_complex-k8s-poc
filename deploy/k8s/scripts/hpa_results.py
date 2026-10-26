"""HPA experiment gates and time-aligned k6 evidence, using shared failure helpers."""
import datetime as dt
import json
import math
import pathlib
import sys

import failure_results as f
from node_failure_results import quantity


def preflight(data, context):
    pods = f.state(data)
    items = data["items"]
    if any(x["kind"] == "HorizontalPodAutoscaler" and x["spec"]["scaleTargetRef"].get("kind") == "Deployment" and x["spec"]["scaleTargetRef"]["name"] == "beach" for x in items):
        raise ValueError("An HPA already controls Beach")
    if any(x["kind"] == "Job" and x["metadata"]["name"].startswith("beach-k6-") and not (x.get("status", {}).get("succeeded") or x.get("status", {}).get("failed")) for x in items):
        raise ValueError("Another k6 Job may be running")
    nodes = {x["metadata"]["name"]: x for x in items if x["kind"] == "Node"}
    apps = [context["hosts"][key] for key, role in context["roles"].items() if role == "app"]
    if len(apps) != 2:
        raise ValueError("Expected two Terraform app workers")
    for key, host in context["hosts"].items():
        node = nodes[host]
        if not any(c["type"] == "Ready" and c["status"] == "True" for c in node["status"]["conditions"]) or node["metadata"]["labels"].get("node-role") != context["roles"][key] or not any(a["type"] == "InternalIP" and a["address"] == context["ips"][key] for a in node["status"]["addresses"]):
            raise ValueError("Terraform and Kubernetes node identity differ")
    for host in apps:
        node = nodes[host]
        if node["spec"].get("unschedulable") or node["spec"].get("taints"):
            raise ValueError("App worker is not schedulable")
        current = [p for p in data["all_pods"] if p["spec"].get("nodeName") == host and p.get("status", {}).get("phase") not in ("Succeeded", "Failed")]
        extra = next(p for p in pods.values() if p["spec"]["nodeName"] == host)
        if any(not c.get("resources", {}).get("requests", {}).get(r) for c in extra["spec"]["containers"] for r in ("cpu", "memory")):
            raise ValueError("Beach containers require CPU and memory requests")
        for resource in ("cpu", "memory"):
            def request(pod):
                normal = sum(quantity(c["resources"]["requests"][resource]) for c in pod["spec"]["containers"] if c.get("resources", {}).get("requests", {}).get(resource))
                init = max([quantity(c.get("resources", {}).get("requests", {}).get(resource, "0")) for c in pod["spec"].get("initContainers", [])] + [0])
                return max(normal, init) + quantity(pod["spec"].get("overhead", {}).get(resource, "0"))
            if sum(request(p) for p in current) + request(extra) > quantity(node["status"]["allocatable"][resource]):
                raise ValueError("Insufficient requested capacity for four Beach replicas")
        if len(current) + 1 > int(node["status"]["allocatable"]["pods"]):
            raise ValueError("Insufficient Pod slots")


def summarize(text):
    marks, points, timeline, summary_count = {}, {}, [], None
    for line in text.splitlines():
        if line.startswith('{"'):
            record = json.loads(line)
            if record.get("event") == "hpa_sample":
                timeline.append(record)
            elif record.get("experiment") == "hpa":
                summary_count = record["metrics"]["http_reqs"]["values"]["count"]
            elif record.get("type") == "Point":
                points.setdefault(record["metric"], []).append((f.timestamp(record["data"]["time"]), record["data"]["value"]))
        elif "=" in line:
            key, value = line.split("=", 1); marks[key] = value
    requests = points.get("http_reqs", [])
    if not requests:
        raise ValueError("No k6 request samples; preserve remote evidence")
    start = min(t for t, _ in requests)
    end = max(t for t, _ in requests) + 1 / float(marks["request_rate"])
    scale = next((f.timestamp(x["time"]) for x in timeline if start < f.timestamp(x["time"]) < end and x["ready"] > 2), None)
    down = bool(scale and any(f.timestamp(x["time"]) > end and x["ready"] == x["desired"] == x["current"] == 2 for x in timeline))

    def phase(left, right):
        samples = lambda metric: [v for t, v in points.get(metric, []) if left <= t < right]
        count = sum(samples("http_reqs")); durations = sorted(samples("http_req_duration"))
        percentile = lambda q: durations[math.ceil(len(durations) * q) - 1] if durations else None
        return dict(requests=count, throughput=count / (right - left),
                    error_rate=sum(samples("http_req_failed")) / count if count else None,
                    dropped_iterations=sum(samples("dropped_iterations")),
                    p50_ms=percentile(.5), p95_ms=percentile(.95), p99_ms=percentile(.99),
                    samples_complete=count > 0 and count == len(durations) == len(samples("http_req_failed")),
                    small_p99_sample=len(durations) < 100)

    phases = {"all": phase(start, end)}
    if scale:
        phases.update(before_scale=phase(start, scale), after_scale=phase(scale, end))
    passed = marks.get("experiment_exit_status") == "0" and summary_count == phases["all"]["requests"] and all(p["samples_complete"] and not p["dropped_iterations"] for p in phases.values())
    return dict(passed=bool(passed and (marks.get("profile") in ("smoke", "baseline") or (scale and down))),
                scale_out_observed=bool(scale), scale_down_observed=down, timeline=timeline, phases=phases,
                percentile_method="nearest_rank", latency_scope="all_requests", poll_seconds=10)


if __name__ == "__main__":
    mode, path = sys.argv[1:3]
    data = json.loads(pathlib.Path(path).read_text()) if mode != "summarize" else None
    if mode == "preflight":
        preflight(data, json.loads(pathlib.Path(sys.argv[3]).read_text()))
    elif mode == "sample":
        deploy = next(x for x in data["items"] if x["kind"] == "Deployment" and x["metadata"]["name"] == "beach")
        hpa = next((x for x in data["items"] if x["kind"] == "HorizontalPodAutoscaler"), {})
        print(json.dumps(dict(event="hpa_sample", time=dt.datetime.now(dt.timezone.utc).isoformat(),
                              ready=deploy.get("status", {}).get("readyReplicas", 0),
                              current=deploy.get("status", {}).get("replicas", 0),
                              desired=hpa.get("status", {}).get("desiredReplicas", deploy["spec"]["replicas"]),
                              hpa_status=hpa.get("status", {}),
                              pods=[dict(name=x["metadata"]["name"], uid=x["metadata"]["uid"], node=x["spec"].get("nodeName"),
                                         deleting=x["metadata"].get("deletionTimestamp"), status=x.get("status", {}))
                                    for x in data["items"] if x["kind"] == "Pod"],
                              endpoints=[dict(name=x["metadata"]["name"], endpoints=x.get("endpoints", []))
                                         for x in data["items"] if x["kind"] == "EndpointSlice"])), flush=True)
    elif mode == "restored":
        f.state(data)
    elif mode == "down":
        f.state(data)
        hpa = next(x for x in data["items"] if x["kind"] == "HorizontalPodAutoscaler")
        assert hpa.get("status", {}).get("desiredReplicas") == 2, "HPA still desires more than two replicas"
    elif mode == "summarize":
        result = summarize(pathlib.Path(path).read_text())
        print(json.dumps(result, indent=2)); sys.exit(0 if result["passed"] else 1)
