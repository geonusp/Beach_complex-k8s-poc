"""Validate Pod identity/EndpointSlices and summarize timestamped k6 JSON points."""
import datetime as dt
import json
import math
import sys


def dependencies(data):
    for name in ("postgres", "redis"):
        deploy = next(d for d in data["items"] if d["kind"] == "Deployment" and d["metadata"]["name"] == name)
        if deploy["spec"]["replicas"] != 1 or deploy.get("status", {}).get("readyReplicas") != 1:
            raise ValueError("Dependency not ready: " + name)


def state(data, old="", survivor=""):
    dependencies(data)
    groups = {}
    for item in data["items"]:
        groups.setdefault(item["kind"], {})[item["metadata"]["name"]] = item
    ready = lambda p: not p["metadata"].get("deletionTimestamp") and any(c["type"] == "Ready" and c["status"] == "True" for c in p.get("status", {}).get("conditions", []))
    for name, replicas in [("beach", 2), ("postgres", 1), ("redis", 1)]:
        deploy = groups["Deployment"][name]
        if any(deploy.get(part, {}).get(field) != replicas for part, field in [("spec", "replicas"), ("status", "readyReplicas"), ("status", "updatedReplicas")]):
            raise ValueError("Deployment not ready: " + name)
    nodes = groups["Node"]
    if not any(ready(n) and n["metadata"]["labels"].get("node-role") == "observability" for n in nodes.values()):
        raise ValueError("No ready observability node")
    pods = {p["metadata"]["uid"]: p for p in groups["Pod"].values() if p["metadata"].get("labels", {}).get("app.kubernetes.io/name") == "beach"}
    if len(pods) != 2 or not all(ready(p) and ready(nodes[p["spec"]["nodeName"]]) and nodes[p["spec"]["nodeName"]]["metadata"]["labels"].get("node-role") == "app" for p in pods.values()):
        raise ValueError("Expected two ready Beach Pods on ready app nodes")
    if not old and len({p["spec"]["nodeName"] for p in pods.values()}) != 2:
        raise ValueError("Beach Pods must start on distinct app nodes")
    endpoints = {e.get("targetRef", {}).get("uid") for s in groups.get("EndpointSlice", {}).values() if s["metadata"].get("labels", {}).get("kubernetes.io/service-name") == "beach" for e in s.get("endpoints", []) if e.get("conditions", {}).get("ready") is not False and not e.get("conditions", {}).get("terminating")}
    if groups["Service"]["beach"]["spec"].get("publishNotReadyAddresses") or endpoints != set(pods):
        raise ValueError("Ready EndpointSlice identities differ from ready Pods")
    if old and (old in pods or survivor not in pods):
        raise ValueError("Replacement UID or survivor not verified")
    return pods


def timestamp(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def summarize(text):
    marks, points = {}, {}
    for line in text.splitlines():
        if line.startswith("{") and line.strip() != "{":
            record = json.loads(line)
            if record.get("type") == "Point":
                points.setdefault(record["metric"], []).append((timestamp(record["data"]["time"]), record["data"]["value"]))
        elif "=" in line:
            key, value = line.split("=", 1)
            marks[key] = value
    requests = points.get("http_reqs", [])
    if not requests:
        raise ValueError("No k6 request samples; preserve remote-output.txt")
    rate = float(marks.get("request_rate", 1))
    start, end = min(t for t, _ in requests), max(t for t, _ in requests) + 1 / rate
    t0 = timestamp(marks["t0"]) if "t0" in marks else end
    ready = timestamp(marks["replacement_ready"]) if "replacement_ready" in marks else end

    def phase(left, right):
        samples = lambda metric: [v for t, v in points.get(metric, []) if left <= t < right]
        count = sum(samples("http_reqs"))
        durations = sorted(samples("http_req_duration"))
        quantile = lambda q: durations[math.ceil(len(durations) * q) - 1] if durations else None
        return dict(requests=count, failed=sum(samples("http_req_failed")), http_5xx=sum(samples("beach_status_5xx")),
                    connection_failures=sum(samples("beach_connection_failures")), dropped_iterations=sum(samples("dropped_iterations")),
                    error_rate=sum(samples("http_req_failed")) / count if count else None,
                    throughput=count / (right - left) if right > left else None, p95_ms=quantile(.95), p99_ms=quantile(.99),
                    duration_samples=len(durations), small_p99_sample=len(durations) < 100,
                    samples_complete=count == len(durations) == len(samples("http_req_failed")))

    baseline = phase(start, t0)
    valid = t0 - start >= 119 and baseline["samples_complete"] and baseline["failed"] == 0 and not baseline["dropped_iterations"] and baseline["throughput"] >= rate * .95
    cutoff = end
    # First observed 30s stable window after structural recovery, with >=60s follow-up.
    for second in range(max(0, math.ceil(end - ready - 90)) + 1):
        window = phase(ready + second, ready + second + 30)
        if valid and ready + second + 90 <= end and window["samples_complete"] and window["error_rate"] == 0 and window["throughput"] >= baseline["throughput"] * .95:
            cutoff = ready + second + 30
            break
    phases = dict(baseline=baseline, failure=phase(t0, cutoff), recovery=phase(cutoff, end))
    recovery = phases["recovery"]
    passed = marks.get("experiment_exit_status") == "0" and cutoff < end and recovery["error_rate"] == 0 and recovery["throughput"] >= baseline["throughput"] * .95 and all(p["samples_complete"] and not p["dropped_iterations"] for p in phases.values())
    return dict(passed=passed, t0=marks.get("t0"), replacement_ready=marks.get("replacement_ready"),
                recovery_boundary_utc=dt.datetime.fromtimestamp(cutoff, dt.timezone.utc).isoformat() if cutoff < end else None,
                replacement_seconds=ready - t0 if "replacement_ready" in marks else None, poll_sleep_seconds=2,
                percentile_method="nearest_rank", latency_scope="all_requests", baseline_valid=valid, phases=phases)


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "snapshot":
        data = json.load(open(sys.argv[2], encoding="utf-8"))
        print(json.dumps(dict(event="snapshot", time=dt.datetime.now(dt.timezone.utc).isoformat(), data=data)), flush=True)
        dependencies(data)
    elif mode == "started":
        for line in sys.stdin.read().rsplit("\n", 1)[0].splitlines():
            if line.startswith("{"):
                record = json.loads(line)
                if record.get("type") == "Point" and record.get("metric") == "http_reqs":
                    print(record["data"]["time"])
                    break
    elif mode == "baseline":
        result = summarize(sys.stdin.read().rsplit("\n", 1)[0] + "\nt0=" + sys.argv[2])
        print(json.dumps(result["phases"]["baseline"]))
        sys.exit(0 if result["baseline_valid"] else 1)
    elif mode == "state":
        for uid, pod in state(json.load(open(sys.argv[2], encoding="utf-8")), *sys.argv[3:]).items():
            print(pod["metadata"]["name"], uid, pod["spec"]["nodeName"])
    else:
        result = summarize(open(sys.argv[2], encoding="utf-8").read())
        print(json.dumps(result, indent=2))
        sys.exit(0 if result["passed"] else 1)
