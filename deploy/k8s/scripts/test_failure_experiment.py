import copy
import datetime as dt
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

import failure_results as f


def shell_env(work, **extra):
    # Shell fixtures must use the interpreter running unittest, not a PATH alias.
    shim = work / "python3"
    shim.write_text('#!/usr/bin/env bash\nexec "$FIXTURE_PYTHON" "$@"\n', newline="\n")
    shim.chmod(0o755)
    env = dict(os.environ, FIXTURE_PYTHON=sys.executable.replace("\\", "/"),
               PYTHON=sys.executable.replace("\\", "/"), **extra)
    env["PATH"] = work.as_posix() + os.pathsep + env["PATH"]
    return env


def resource(kind, name, **extra):
    return dict(kind=kind, metadata=dict(name=name, uid=name, labels={}), **extra)


def fixture():
    items = [resource("Deployment", n, spec={"replicas": r}, status={"readyReplicas": r, "updatedReplicas": r})
             for n, r in [("beach", 2), ("postgres", 1), ("redis", 1)]]
    for name, role in [("app-1", "app"), ("app-2", "app"), ("obs-1", "observability")]:
        node = resource("Node", name, status={"conditions": [{"type": "Ready", "status": "True"}]})
        node["metadata"]["labels"]["node-role"] = role
        items.append(node)
    for name, node in [("old", "app-1"), ("survivor", "app-2")]:
        pod = resource("Pod", name, spec={"nodeName": node}, status={"conditions": [{"type": "Ready", "status": "True"}]})
        pod["metadata"]["labels"]["app.kubernetes.io/name"] = "beach"
        items.append(pod)
    slices = resource("EndpointSlice", "slice", endpoints=[{"targetRef": {"uid": n}, "addresses": [n]} for n in ["old", "survivor"]])
    slices["metadata"]["labels"]["kubernetes.io/service-name"] = "beach"
    return {"items": items + [slices, resource("Service", "beach", spec={})]}


class FailureTests(unittest.TestCase):
    def test_omitted_ready_and_duplicate_slice_addresses(self):
        data = fixture()
        data["items"].append(copy.deepcopy(data["items"][-2]))
        self.assertEqual(set(f.state(data)), {"old", "survivor"})

    def test_wrong_nodes_unready_endpoint_and_old_uid_are_rejected(self):
        for mutate in [lambda d: d["items"][6]["spec"].update(nodeName="app-2"),
                       lambda d: d["items"][3]["metadata"]["labels"].update({"node-role": "control-plane"}),
                       lambda d: d["items"][-2]["endpoints"][0].update(conditions={"ready": False})]:
            data = fixture()
            mutate(data)
            with self.assertRaises(ValueError):
                f.state(data)
        with self.assertRaises(ValueError):
            f.state(fixture(), "old", "survivor")
        data = fixture()
        data["items"][6]["metadata"]["uid"] = "new"
        data["items"][-2]["endpoints"][0]["targetRef"]["uid"] = "new"
        self.assertEqual(set(f.state(data, "old", "survivor")), {"new", "survivor"})

    def test_phase_boundaries_failures_and_small_p99_sample(self):
        result = f.summarize(self.output())
        self.assertEqual(result["phases"]["baseline"]["requests"], 120)
        failure = result["phases"]["failure"]
        self.assertEqual((failure["requests"], failure["failed"], failure["http_5xx"], failure["connection_failures"]), (35, 2, 1, 1))
        self.assertEqual(failure["p99_ms"], 900)
        self.assertTrue(failure["small_p99_sample"])
        self.assertTrue(result["passed"])

    def test_missing_recovery_or_remote_failure_never_passes(self):
        for text in [self.output().replace("replacement_ready=", "missing="), self.output().replace("experiment_exit_status=0", "experiment_exit_status=1"), self.output(late_failure=True)]:
            self.assertFalse(f.summarize(text)["passed"])

    def test_cli_start_baseline_and_dependency_failure_snapshot(self):
        helper = str(pathlib.Path(f.__file__).resolve())
        run = lambda *args, text="": subprocess.run([sys.executable, helper, *args], input=text, text=True, capture_output=True)
        self.assertEqual(run("started", text=self.output()).stdout.strip(), "2026-01-01T00:00:00+00:00")
        self.assertEqual(run("baseline", "2026-01-01T00:02:00+00:00", text=self.output()).returncode, 0)
        self.assertNotEqual(run("baseline", "2026-01-01T00:02:01+00:00", text=self.output()).returncode, 0)
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "state.json"
            data = fixture()
            data["items"][2]["status"]["readyReplicas"] = 0
            path.write_text(json.dumps(data), encoding="utf-8")
            result = run("snapshot", str(path))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout)["data"], data)

    @staticmethod
    def output(late_failure=False):
        start = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
        stamp = lambda s: (start + dt.timedelta(seconds=s)).isoformat()
        lines = ["t0=" + stamp(120), "replacement_ready=" + stamp(125), "experiment_exit_status=0"]
        for second in range(420):
            for metric, value in {"http_reqs": 1, "http_req_failed": int(second in (120, 124) or (late_failure and second >= 155)), "http_req_duration": 900 if second == 120 else 10,
                                  "beach_status_5xx": int(second == 120), "beach_connection_failures": int(second == 124)}.items():
                lines.append(json.dumps(dict(type="Point", metric=metric, data=dict(time=stamp(second), value=value))))
        return "\n".join(lines)


if __name__ == "__main__":
    unittest.main()
