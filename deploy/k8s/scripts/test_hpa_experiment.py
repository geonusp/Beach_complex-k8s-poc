import copy
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

import test_failure_experiment as fixtures


class HpaTests(unittest.TestCase):
    def test_large_ssm_payload_uses_file_and_reports_send_failure(self):
        root = pathlib.Path(__file__).parent
        with tempfile.TemporaryDirectory() as folder:
            work = pathlib.Path(folder)
            (work / "payload").write_text("echo evidence\n" * 5000)
            (work / "aws").write_text('''#!/usr/bin/env python3
import base64,json,os,pathlib,sys
a=sys.argv[1:]; p=pathlib.Path(os.environ['work_dir'])
if a[:2]==['ssm','send-command']:
 value=a[a.index('--parameters')+1]
 assert value.startswith('file://'), 'payload must be loaded from file'
 command=json.loads(pathlib.Path(value[7:]).read_text())['commands'][0]
 assert base64.b64decode(command.split()[1])==(p/'payload').read_text().rstrip().encode()
 (p/'parameter-path').write_text(value[7:])
 if os.environ['SEND_FAIL']=='1': sys.exit(1)
 print('command-1')
else: print('Success')
''', newline="\n")
            (work / "aws").chmod(0o755)
            for failure in ("0", "1"):
                env = fixtures.shell_env(work, work_dir=work.as_posix(), SEND_FAIL=failure,
                                         SSM_LIB=(root / "lib/ssm.sh").resolve().as_posix())
                bash = "C:/Program Files/Git/bin/bash.exe" if os.name == "nt" else shutil.which("bash")
                prefix = 'export PATH="$(cygpath -u "$work_dir")":$PATH; ' if os.name == "nt" else 'export PATH="$work_dir":$PATH; '
                run = subprocess.run([bash, "-c", prefix + 'set -Eeuo pipefail; source "$SSM_LIB"; ssm_run i-fixture "$(cat "$work_dir/payload")"'], env=env, capture_output=True, text=True)
                self.assertEqual(run.returncode == 0, failure == "0", run.stderr)
                if failure == "1": self.assertIn('failed to send SSM', run.stderr)
                self.assertFalse(pathlib.Path((work / "parameter-path").read_text()).exists())

    def test_suite_orders_stages_and_stops_on_failure(self):
        root = pathlib.Path(__file__).parent
        with tempfile.TemporaryDirectory() as folder:
            work = pathlib.Path(folder)
            shutil.copy(root / "run-hpa-suite.sh", work)
            (work / "run-hpa-experiment.sh").write_text('''#!/usr/bin/env bash
echo "$2" >> "$SUITE_CALLS"
[[ "$2" != "$FAIL_STAGE" ]]
''', newline="\n")
            bash = "C:/Program Files/Git/bin/bash.exe" if os.name == "nt" else shutil.which("bash")
            for stage, answer, expected in [("", "continue\n", ["smoke", "baseline", "baseline", "load", "stress"]),
                                             ("baseline", "continue\n", ["smoke", "baseline"]),
                                             ("", "stop\n", ["smoke", "baseline"])]:
                calls = work / "calls"; calls.write_text("")
                run = subprocess.run([bash, str(work / "run-hpa-suite.sh"), "--confirm-dev"], input=answer.encode(),
                                     env=dict(os.environ, SUITE_CALLS=calls.as_posix(), FAIL_STAGE=stage), capture_output=True)
                self.assertEqual(calls.read_text().splitlines(), expected)
                self.assertEqual(run.returncode == 0, len(expected) == 5, run.stderr)

    def context(self):
        return dict(hosts={"app-1": "app-1", "app-2": "app-2", "obs-1": "obs-1", "cp-1": "cp-1"},
                    roles={"app-1": "app", "app-2": "app", "obs-1": "observability", "cp-1": "control-plane"},
                    ips={"app-1": "10.0.0.1", "app-2": "10.0.0.2", "obs-1": "10.0.0.3", "cp-1": "10.0.0.4"})

    def cluster(self):
        data = fixtures.fixture()
        cp = fixtures.resource("Node", "cp-1", status=dict(conditions=[dict(type="Ready", status="True")]))
        cp["metadata"]["labels"]["node-role.kubernetes.io/control-plane"] = ""
        data["items"].append(cp)
        nodes = [x for x in data["items"] if x["kind"] == "Node"]
        for i, node in enumerate(nodes):
            node["spec"] = {}
            node["status"]["addresses"] = [dict(type="InternalIP", address=f"10.0.0.{i+1}")]
            node["status"]["allocatable"] = dict(cpu="2", memory="3Gi", pods="30")
        for pod in (x for x in data["items"] if x["kind"] == "Pod"):
            pod["spec"]["containers"] = [{"name": "beach", "resources": {"requests": {"cpu": "250m", "memory": "512Mi"}}}]
        data["all_pods"] = [x for x in data["items"] if x["kind"] == "Pod"]
        return data

    def test_preflight_checks_actual_control_plane_and_worker_role_labels(self):
        import hpa_results as h
        data = self.cluster()
        h.preflight(data, self.context())
        for node in (x for x in data["items"] if x["kind"] == "Node"):
            with self.subTest(node=node["metadata"]["name"]):
                bad = copy.deepcopy(data)
                target = next(x for x in bad["items"] if x["kind"] == "Node" and x["metadata"]["name"] == node["metadata"]["name"])
                target["metadata"]["labels"].pop("node-role.kubernetes.io/control-plane", None)
                target["metadata"]["labels"]["node-role"] = "wrong"
                with self.assertRaises(ValueError):
                    h.preflight(bad, self.context())

    def test_preflight_rejects_existing_hpa_wrong_cluster_and_capacity(self):
        import hpa_results as h
        data = self.cluster()
        h.preflight(data, self.context())
        changes = [lambda d: d["items"].append(dict(kind="HorizontalPodAutoscaler", metadata=dict(name="existing"), spec=dict(scaleTargetRef=dict(kind="Deployment", name="beach")))),
                   lambda d: d["items"][3]["status"]["addresses"][0].update(address="10.9.0.1"),
                   lambda d: d["items"][3]["status"]["allocatable"].update(memory="512Mi"),
                   lambda d: d["items"].append(dict(kind="Job", metadata=dict(name="beach-k6-other"), status=dict(active=1)))]
        for change in changes:
            bad = copy.deepcopy(data); change(bad)
            with self.subTest(change=change), self.assertRaises(ValueError): h.preflight(bad, self.context())

    def output(self):
        lines = ["profile=load", "request_rate=1", "experiment_exit_status=0"]
        for second in range(10):
            stamp = f"2026-01-01T00:00:{second:02d}Z"
            for metric, value in [("http_reqs", 1), ("http_req_failed", 0), ("http_req_duration", second + 1)]:
                lines.append(json.dumps(dict(type="Point", metric=metric, data=dict(time=stamp, value=value))))
        for second, count in [(0, 2), (5, 3), (20, 2)]:
            lines.append(json.dumps(dict(event="hpa_sample", time=f"2026-01-01T00:00:{second:02d}Z", ready=count, desired=count, current=count)))
        lines.append(json.dumps(dict(experiment="hpa", metrics=dict(http_reqs=dict(values=dict(count=10))))))
        return "\n".join(lines)

    def test_summary_compares_only_before_and_after_ready_scale(self):
        import hpa_results as h
        result = h.summarize(self.output())
        self.assertTrue(result["passed"])
        self.assertEqual(result["phases"]["before_scale"]["requests"], 5)
        self.assertEqual(result["phases"]["after_scale"]["p50_ms"], 8)
        self.assertEqual(result["phases"]["after_scale"]["p95_ms"], 10)
        self.assertEqual(result["phases"]["after_scale"]["throughput"], 1)
        self.assertTrue(result["scale_down_observed"])

    def test_samples_preserve_identities_without_repeating_full_manifests(self):
        data = self.cluster()
        data["items"][0]["spec"]["large_template"] = "x" * 10000
        with tempfile.TemporaryDirectory() as folder:
            state = pathlib.Path(folder) / "state.json"; state.write_text(json.dumps(data))
            run = subprocess.run([sys.executable, "-B", str(pathlib.Path(__file__).parent / "hpa_results.py"), "sample", str(state)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            sample = json.loads(run.stdout)
            self.assertNotIn("state", sample)
            self.assertEqual(sample["pods"][0]["uid"], "old")
            self.assertLess(len(run.stdout), 5000)

    def test_incomplete_samples_missing_scale_and_failed_run_cannot_pass(self):
        import hpa_results as h
        for text in [self.output().replace('"metric": "http_req_duration"', '"metric": "missing"'),
                     self.output().replace('"ready": 3', '"ready": 2'),
                     self.output().replace('"ready": 2, "desired": 2, "current": 2}', '"ready": 3, "desired": 3, "current": 3}'),
                     self.output().replace('"count": 10', '"count": 11'),
                     self.output().replace('"experiment": "hpa"', '"experiment": "missing"'),
                     self.output().replace("experiment_exit_status=0", "experiment_exit_status=1")]:
            with self.subTest(text=text): self.assertFalse(h.summarize(text)["passed"])

    def test_local_runner_packages_valid_shell_and_does_not_overwrite_failed_evidence(self):
        root = pathlib.Path(__file__).parent
        with tempfile.TemporaryDirectory() as folder:
            work = pathlib.Path(folder)
            (work / "lib").mkdir()
            for name in ("run-hpa-experiment.sh", "hpa_results.py", "failure_results.py", "node_failure_results.py"):
                shutil.copy(root / name, work)
            (work / "verify-observability.sh").write_text("exit 0\n")
            (work / "lib/hpa-remote.sh").write_text((root / "lib/hpa-remote.sh").read_text())
            (work / "lib/ssm.sh").write_text('''repo_root="$TEST_REPO"
require_tools() { :; }
log() { echo "$*"; }
fail() { echo "$*" >&2; exit 1; }
terraform_output() { case "$1" in control_plane_instance_id) echo i-cafe;; *) echo bucket;; esac; }
terraform_output_json() { case "$1" in node_instance_ids) echo '{"cp-1":"i-cafe"}';; node_roles) echo '{"cp-1":"control-plane"}';; *) echo '{}';; esac; }
ssm_run() { if [[ "${TEST_SEND_FAIL:-0}" == 1 ]]; then echo SEND_FAILED >&2; exit 1; fi; printf '%s' "$2" > "$TEST_WORK/payload.sh"; bash -n "$TEST_WORK/payload.sh" || return; echo CONTROLLED_REMOTE_FAILURE; echo experiment_exit_status=1; }
''', newline="\n")
            (work / "aws").write_text('#!/usr/bin/env bash\necho "{}"\n', newline="\n"); (work / "aws").chmod(0o755)
            env = fixtures.shell_env(work, TEST_WORK=work.as_posix(), TEST_REPO=root.parents[2].as_posix(),
                                     TEST_RUNNER=(work / "run-hpa-experiment.sh").as_posix(), work_dir=work.as_posix(), BEACH_HPA_RESULT_DIR=(work / "results").as_posix())
            bash = "C:/Program Files/Git/bin/bash.exe" if os.name == "nt" else shutil.which("bash")
            prefix = 'export PATH="$(cygpath -u "$work_dir")":/usr/bin:/bin:$PATH; ' if os.name == "nt" else 'export PATH="$work_dir":$PATH; '
            command = [bash, "-c", prefix + 'bash "$TEST_RUNNER" --confirm-dev load 40 fixture']
            run = subprocess.run(command, env=env, capture_output=True, text=True, timeout=20)
            self.assertNotEqual(run.returncode, 0)
            evidence = work / "results/fixture/remote-output.txt"
            self.assertIn("CONTROLLED_REMOTE_FAILURE", evidence.read_text(), run.stdout + run.stderr)
            previous = evidence.read_bytes()
            again = subprocess.run(command, env=env, capture_output=True, text=True, timeout=20)
            self.assertNotEqual(again.returncode, 0)
            self.assertIn("result label exists", again.stderr)
            self.assertEqual(evidence.read_bytes(), previous)
            failed = subprocess.run([bash, "-c", prefix + 'bash "$TEST_RUNNER" --confirm-dev load 40 send-failed'],
                                    env=dict(env, TEST_SEND_FAIL="1"), capture_output=True, text=True, timeout=20)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("SEND_FAILED", failed.stderr)
            self.assertIn("SSM execution/retrieval failed", failed.stderr)

    def test_real_remote_shell_preserves_load_failure_and_distinguishes_restore_failure(self):
        root = pathlib.Path(__file__).parent
        for scenario in ("healthy", "seconds_filtered", "throttling_missing", "k6_failed", "restore_failed", "api_failed", "preflight_failed", "job_create_failed", "hpa_create_timeout", "terminating"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as folder:
                work = pathlib.Path(folder) / "run.fixture"; work.mkdir()
                for name in ("hpa_results.py", "failure_results.py", "node_failure_results.py"):
                    shutil.copy(root / name, work)
                for path in (root.parent / "loadtest/k6-failure-job.yaml", root.parent / "app/hpa.yaml", root.parent / "observability/promql-queries.tsv"):
                    shutil.copy(path, work)
                (work / "context.json").write_text(json.dumps(self.context()))
                (work / "cluster.json").write_text(json.dumps(self.cluster()))
                (work / "hpa.js").write_text("")
                (work / "kubectl").write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
p=pathlib.Path(os.environ['work_dir']); a=' '.join(sys.argv[1:]); scenario=os.environ['SCENARIO']
with (p/'calls').open('a') as out: out.write(a+'\\n')
if 'get pods,' in a:
 d=json.loads((p/'cluster.json').read_text())
 if (p/'scaled').exists() and scenario=='terminating' and not (p/'retried').exists():
  d['items'].append(dict(kind='Pod',metadata=dict(name='terminating',uid='extra',labels={'app.kubernetes.io/name':'beach'},deletionTimestamp='now'),spec=dict(nodeName='app-1'),status=dict(conditions=[]))); (p/'retried').touch()
 if scenario=='preflight_failed': d['items'][3]['status']['addresses'][0]['address']='wrong'
 if (p/'hpa-created').exists(): d['items'].append(dict(kind='HorizontalPodAutoscaler',metadata=dict(name='test'),spec=dict(scaleTargetRef=dict(kind='Deployment',name='beach')),status=dict(desiredReplicas=2)))
 print(json.dumps(d))
elif 'get pods -A' in a: print(json.dumps(dict(items=json.loads((p/'cluster.json').read_text())['all_pods'])))
elif 'get --raw' in a:
 missing=scenario=='seconds_filtered' and 'container_cpu_cfs_throttled_seconds_total' in a or scenario=='throttling_missing' and 'container_cpu_cfs_' in a
 print(json.dumps(dict(status='success',data=dict(result=[] if missing else [dict(values=[[0,'0']])]))))
elif 'set env' in a: print('{}')
elif 'create -f' in a:
 if 'run-hpa.yaml' in a:
  (p/'hpa-created').touch()
  if scenario=='hpa_create_timeout': sys.exit(1)
 elif scenario=='job_create_failed': sys.exit(1)
elif 'get job' in a: print(':1' if scenario=='k6_failed' else '1:')
elif 'delete hpa' in a:
 if scenario=='restore_failed': sys.exit(1)
 (p/'hpa-created').unlink()
elif 'get service' in a: print('10.0.0.9')
elif 'logs ' in a: print('RAW_EVIDENCE')
elif 'scale deployment' in a: (p/'scaled').touch()
''', newline="\n")
                (work / "curl").write_text('#!/usr/bin/env bash\n[[ "$SCENARIO" != api_failed ]] || exit 1\necho API_OK\n', newline="\n")
                (work / "sleep").write_text('#!/usr/bin/env bash\nexit 0\n', newline="\n")
                for name in ("kubectl", "curl", "sleep"): (work / name).chmod(0o755)
                env = fixtures.shell_env(work, work_dir=work.as_posix(), SCENARIO=scenario, profile="load", rate="40", TEST_REMOTE=(root / "lib/hpa-remote.sh").resolve().as_posix())
                # Keep the lock inside this fixture; the production lock path is otherwise unchanged.
                remote = (root / "lib/hpa-remote.sh").read_text().replace('/tmp/beach-hpa-active', work.as_posix() + '/lock')
                remote = remote.replace('deadline=$((SECONDS + 180))', 'deadline=$((SECONDS + 5))')
                (work / "remote.sh").write_text(remote, newline="\n")
                env["TEST_REMOTE"] = (work / "remote.sh").as_posix()
                bash = "C:/Program Files/Git/bin/bash.exe" if os.name == "nt" else shutil.which("bash")
                prefix = 'export PATH="$(cygpath -u "$work_dir")":$PATH; ' if os.name == "nt" else 'export PATH="$work_dir":$PATH; '
                run = subprocess.run([bash, "-c", prefix + 'source "$TEST_REMOTE"'], env=env, capture_output=True, text=True, timeout=30)
                self.assertEqual(run.returncode == 0, scenario in ("healthy", "seconds_filtered", "terminating"), run.stdout + run.stderr)
                calls = (work / "calls").read_text()
                if scenario == "healthy":
                    self.assertIn('K6_NEW_MACHINE_READABLE_SUMMARY=false', calls)
                    self.assertIn('"name": "k6_cpu_cores"', run.stdout)
                    self.assertIn('"name": "k6_throttled_period_ratio"', run.stdout)
                    self.assertIn('container_cpu_cfs_throttled_periods_total', calls)
                    self.assertIn('container_cpu_cfs_periods_total', calls)
                if scenario == "throttling_missing":
                    self.assertIn('Missing Prometheus evidence', run.stderr)
                if scenario == "preflight_failed":
                    self.assertNotIn('create -f', calls)
                    self.assertNotIn('scale deployment', calls)
                else:
                    if scenario not in ("job_create_failed", "hpa_create_timeout"):
                        self.assertIn('RAW_EVIDENCE', run.stdout)
                        self.assertIn('delete job beach-k6-hpa-fixture', calls)
                    self.assertIn('delete hpa beach-k6-hpa-fixture', calls)
                    if scenario != "hpa_create_timeout": self.assertIn('delete configmap beach-k6-hpa-fixture', calls)
                    else:
                        self.assertIn('--ignore-not-found', calls)
                        self.assertIn('scale deployment/beach --replicas=2', calls)
                    self.assertEqual('final_state_verified=' in run.stdout, scenario not in ("restore_failed", "api_failed"))
                    if scenario == "restore_failed": self.assertNotIn('scale deployment', calls)
                self.assertIn('remote_work_dir=', run.stdout)
                self.assertFalse((work / "lock").exists())


if __name__ == "__main__":
    unittest.main()
