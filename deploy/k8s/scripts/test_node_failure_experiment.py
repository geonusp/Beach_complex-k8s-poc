import copy
import datetime as dt
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

import node_failure_results as n
import test_failure_experiment as fixtures


def context():
    return dict(key="app-1", instance="i-app1", node="app-1", other="app-2", ip="10.0.0.1")


def cluster():
    data = fixtures.fixture()
    for deployment in data["items"][:3]:
        spread = dict(maxSkew=1, topologyKey="kubernetes.io/hostname", whenUnsatisfiable="DoNotSchedule", nodeTaintsPolicy="Honor")
        if deployment["metadata"]["name"] != "beach":
            spread["labelSelector"] = dict(matchExpressions=[dict(key="app.kubernetes.io/name", operator="In", values=["postgres", "redis"])])
        deployment["spec"]["template"] = dict(spec=dict(topologySpreadConstraints=[spread]))
    for i, node in enumerate(p for p in data["items"] if p["kind"] == "Node"):
        node["status"].update(addresses=[dict(type="InternalIP", address=f"10.0.0.{i+1}")], allocatable=dict(cpu="2", memory="1800Mi", pods="20"))
    for name, node in [("postgres", "app-1"), ("redis", "app-2")]:
        pod = fixtures.resource("Pod", name, spec=dict(nodeName=node), status=dict(conditions=[dict(type="Ready", status="True")]))
        pod["metadata"]["labels"]["app.kubernetes.io/name"] = name
        data["items"].append(pod)
    for pod in (p for p in data["items"] if p["kind"] == "Pod"):
        pod["spec"]["containers"] = [dict(resources=dict(requests=dict(cpu="250m", memory="256Mi")))]
    data["all_pods"] = [copy.deepcopy(p) for p in data["items"] if p["kind"] == "Pod"]
    return data


def recovered(data):
    data = copy.deepcopy(data)
    data["items"][3]["status"]["conditions"][0]["status"] = "Unknown"
    for pod in (p for p in data["items"] if p["kind"] == "Pod" and p["spec"]["nodeName"] == "app-1"):
        pod["metadata"]["uid"] += "-new"
        pod["spec"]["nodeName"] = "app-2"
    data["items"][8]["endpoints"][0]["targetRef"]["uid"] = "old-new"
    return data


class NodeTests(unittest.TestCase):
    def test_preflight_requires_joint_dependency_spread_and_single_node_recovery(self):
        n.preflight(cluster(), context())
        for name in ["postgres", "redis"]:
            for change in [dict(nodeTaintsPolicy="Ignore"), dict(minDomains=2), dict(maxSkew=2),
                           dict(whenUnsatisfiable="ScheduleAnyway"), dict(topologyKey="topology.kubernetes.io/zone"),
                           dict(matchLabelKeys=["pod-template-hash"]),
                           dict(labelSelector=dict(matchLabels={"app.kubernetes.io/name": name}))]:
                with self.subTest(name=name, change=change):
                    data = cluster()
                    deployment = next(d for d in data["items"] if d["kind"] == "Deployment" and d["metadata"]["name"] == name)
                    deployment["spec"]["template"]["spec"]["topologySpreadConstraints"][0].update(change)
                    with self.assertRaisesRegex(ValueError, "dependency topology spread"):
                        n.preflight(data, context())

    def test_target_must_match_terraform_app_role_and_unique_identity(self):
        tf = dict(ids={"cp-1": "i-cp", "app-1": "i-app1", "app-2": "i-app2", "obs-1": "i-obs"},
                  roles={"cp-1": "control-plane", "app-1": "app", "app-2": "app", "obs-1": "observability"},
                  hosts={k: k for k in ["cp-1", "app-1", "app-2", "obs-1"]}, ips={"app-1": "10.0.0.1"}, cp="i-cp")
        self.assertEqual(n.target(tf, "app-1"), context())
        for key in ["cp-1", "obs-1", "missing"]:
            with self.subTest(key=key), self.assertRaises(ValueError): n.target(tf, key)
        tf["ids"]["app-1"] = "i-cp"
        with self.assertRaises(ValueError): n.target(tf, "app-1")

    def test_preflight_rejects_wrong_node_ip_capacity_and_dependency_placement(self):
        n.preflight(cluster(), context())
        for change in [lambda d: d["items"][3]["status"]["addresses"][0].update(address="10.9.9.9"),
                       lambda d: d["items"][4]["status"]["allocatable"].update(memory="512Mi"),
                       lambda d: d["items"][-1]["spec"].update(nodeName="app-1")]:
            data = cluster(); change(data)
            with self.assertRaises(ValueError): n.preflight(data, context())

    def test_recovery_needs_new_uids_on_survivor_and_dependencies_ready(self):
        before = cluster(); after = recovered(before)
        self.assertEqual(n.observe(before, before, context()), (False, False, False))
        self.assertEqual(n.observe(after, before, context()), (True, True, True))
        for change in [lambda d: d["items"][-2]["status"]["conditions"][0].update(status="False"),
                       lambda d: d["items"][6]["spec"].update(nodeName="app-1"),
                       lambda d: d["items"][6]["metadata"].update(uid="old")]:
            data = copy.deepcopy(after); change(data)
            self.assertFalse(n.observe(data, before, context())[2])

    def test_summary_rejects_recovery_after_restart_and_missing_evidence(self):
        raw = fixtures.FailureTests.output() + "\nnode_detected=2026-01-01T00:02:01Z\nendpoint_removed=2026-01-01T00:02:02Z\nrestart_requested=2026-01-01T00:08:00Z\nfinal_state_verified=2026-01-01T00:09:00Z\n"
        result = n.summarize(raw)
        self.assertTrue(result["passed"])
        self.assertEqual(result["detection_seconds"], 1)
        self.assertEqual(result["endpoint_seconds"], 2)
        self.assertGreaterEqual(result["mitigation_seconds"], 2)
        for bad in [raw.replace("node_detected=", "missing="), raw.replace("final_state_verified=", "missing="),
                    raw.replace("00:08:00Z", "00:02:04Z"), raw.replace("endpoint_removed=", "missing=")]:
            self.assertFalse(n.summarize(bad)["passed"])

    def test_final_requires_same_target_node_back_with_expected_ip(self):
        before = cluster(); after = recovered(before)
        after["items"][3]["status"]["conditions"][0]["status"] = "True"
        n.final(after, before, context())
        for change in [lambda d: d["items"].pop(3),
                       lambda d: d["items"][3]["status"]["addresses"][0].update(address="10.9.9.9"),
                       lambda d: d["items"][3]["status"]["conditions"][0].update(status="Unknown")]:
            data = copy.deepcopy(after); change(data)
            with self.assertRaises(ValueError): n.final(data, before, context())


class NodeRunnerTests(unittest.TestCase):
    def test_permission_stop_observation_restart_and_final_verification_failures(self):
        root = pathlib.Path(__file__).parent
        for scenario in ["permission", "stop_error", "observation", "restart_error", "final_error"]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as folder:
                work = pathlib.Path(folder)
                (work / "scripts/lib").mkdir(parents=True)
                shutil.copy(root / "run-node-failure-experiment.sh", work / "scripts")
                shutil.copy(root / "node_failure_results.py", work / "scripts")
                shutil.copy(root / "failure_results.py", work / "scripts")
                (work / "scripts/verify-observability.sh").write_text("exit 0\n")
                (work / "loadtest").mkdir()
                for file in ["failure.js", "k6-failure-job.yaml"]: shutil.copy(root.parent / "loadtest" / file, work / "loadtest")
                (work / "scripts/lib/ssm.sh").write_text('''repo_root="$FIXTURE_ROOT"
ssm_command_timeout_seconds=1500
require_tools() { :; }
log() { echo "$*"; }
fail() { echo "$*" >&2; exit 1; }
terraform_output() { case "$1" in control_plane_instance_id) echo i-cp;; *) echo bucket;; esac; }
terraform_output_json() { cat "$FIXTURE_ROOT/$1.json"; }
ssm_run() {
 case "$2" in
  *'# phase=observe'*) echo experiment_exit_status=1; /usr/bin/sleep 1;;
  *'# phase=gate'*) echo ready;;
  *'# phase=final'*) [[ "$SCENARIO" != final_error ]] || exit 1; echo final_state_verified=2026-01-01T00:09:00Z;;
 esac
}
''')
                maps = dict(node_instance_ids={"cp-1": "i-cp", "app-1": "i-app1", "app-2": "i-app2", "obs-1": "i-obs"},
                            node_roles={"cp-1": "control-plane", "app-1": "app", "app-2": "app", "obs-1": "observability"},
                            node_hostnames={k: k for k in ["cp-1", "app-1", "app-2", "obs-1"]}, node_private_ips={"app-1": "10.0.0.1"})
                for key, value in maps.items(): (work / (key + ".json")).write_text(json.dumps(value))
                (work / "aws").write_text('''#!/usr/bin/env bash
echo "$*" >> "$FIXTURE_ROOT/aws.log"
if [[ "$*" == *--dry-run* ]]; then
 [[ "$SCENARIO" != permission ]] || { echo UnauthorizedOperation >&2; exit 255; }
 echo DryRunOperation >&2; exit 255
fi
case "$1 $2" in
 'ec2 describe-instances')
  if [[ "$*" == *--query* ]]; then echo stopped
  else echo '{"Reservations":[{"Instances":[{"InstanceId":"i-app1","PrivateIpAddress":"10.0.0.1","State":{"Name":"running"},"RootDeviceType":"ebs"}]}]}' ; fi;;
 'ec2 stop-instances') [[ "$SCENARIO" != stop_error ]] || exit 254;;
 'ec2 start-instances') [[ "$SCENARIO" != restart_error ]] || exit 254;;
esac
''')
                (work / "aws").chmod(0o755)
                env = fixtures.shell_env(work, FIXTURE_ROOT=work.as_posix(), SCENARIO=scenario,
                                         BEACH_NODE_RESULT_DIR=(work / "results").as_posix())
                bash = "C:/Program Files/Git/bin/bash.exe" if os.name == "nt" else shutil.which("bash")
                command = 'export PATH="$(cygpath -u "$FIXTURE_ROOT")":$PATH; bash "$FIXTURE_ROOT/scripts/run-node-failure-experiment.sh" --confirm-dev app-1 fixture' if os.name == "nt" else 'bash "$FIXTURE_ROOT/scripts/run-node-failure-experiment.sh" --confirm-dev app-1 fixture'
                result = subprocess.run([bash, "-c", command], env=env, text=True, capture_output=True, timeout=20)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue((work / "aws.log").exists(), result.stdout + result.stderr)
                calls = (work / "aws.log").read_text()
                mutations = [line for line in calls.splitlines() if "--dry-run" not in line]
                if scenario == "permission": self.assertFalse(any("stop-instances" in c for c in mutations))
                else:
                    self.assertTrue(any("start-instances --instance-ids i-app1" in c for c in mutations), calls + result.stderr)
                    self.assertTrue((work / "results/fixture/remote-output.txt").exists())
                    self.assertTrue((work / "results/fixture/phases.json").exists(), result.stderr)
                    self.assertIn('Manual recovery:', result.stdout)


class NodeRemoteTests(unittest.TestCase):
    def test_actual_remote_shell_relocation_and_database_loss(self):
        root = pathlib.Path(__file__).parent
        script = (root / "run-node-failure-experiment.sh").read_text()
        common = script[script.index('remote_common='):script.index('stop_possible=false')]
        remote = script.split("remote_script=\"$(cat <<'REMOTE'\n", 1)[1].split("\nREMOTE", 1)[0]
        for scenario in ["healthy", "data_loss"]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as folder:
                work = pathlib.Path(folder)
                for file in ["failure_results.py", "node_failure_results.py"]: shutil.copy(root / file, work)
                for file in ["failure.js", "k6-failure-job.yaml"]: shutil.copy(root.parent / "loadtest" / file, work)
                (work / "context.json").write_text(json.dumps(context()))
                (work / "initial.json").write_text(json.dumps(cluster()))
                (work / "relocated.json").write_text(json.dumps(recovered(cluster())))
                (work / "inject").touch()
                start = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=130)
                records = []
                for line in fixtures.FailureTests.output().splitlines():
                    if not line.startswith('{'): continue
                    record = json.loads(line)
                    offset = dt.datetime.fromisoformat(record['data']['time']) - dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
                    record['data']['time'] = (start + offset).isoformat()
                    if record['metric'] in ('http_req_failed', 'beach_status_5xx', 'beach_connection_failures'): record['data']['value'] = 0
                    records.extend([json.dumps(record)] * 5)
                (work / 'raw.json').write_text('\n'.join(records) + '\n')
                tools = {"kubectl": '''#!/usr/bin/env bash
echo "$*" >> "$FIXTURE_ROOT/kubectl.log"
case "$*" in
 *'get pods,deployments,'*) if [[ -f "$FIXTURE_ROOT/ready" ]]; then cat "$FIXTURE_ROOT/relocated.json"; else cat "$FIXTURE_ROOT/initial.json"; fi;;
 *'get pods -A'*) python3 -c 'import json,os; d=json.load(open(os.environ["FIXTURE_ROOT"]+"/initial.json")); print(json.dumps({"items":d["all_pods"]}))';;
 *'exec deployment/postgres'*) if [[ "$SCENARIO" == data_loss && -f "$FIXTURE_ROOT/ready" ]]; then echo changed; else echo fingerprint; fi;;
 *'get service beach'*) echo 10.96.0.1;;
 *'logs '*) cat "$FIXTURE_ROOT/raw.json";;
 *'get job '*) echo 1;;
esac
''', "curl": '#!/usr/bin/env bash\necho "[]"\n', "sleep": '#!/usr/bin/env bash\nexit 0\n'}
                for name, content in tools.items():
                    (work / name).write_text(content); (work / name).chmod(0o755)
                env = fixtures.shell_env(work, FIXTURE_ROOT=work.as_posix(), SCENARIO=scenario)
                bash = 'C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' else shutil.which('bash')
                prefix = 'export PATH="$(cygpath -u "$FIXTURE_ROOT")":$PATH; ' if os.name == 'nt' else ''
                run = subprocess.run([bash, '-c', prefix + 'set -Eeuo pipefail; work_dir="$FIXTURE_ROOT";\n' + common + '\neval "$remote_common"\n' + remote], env=env, text=True, capture_output=True, timeout=20)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertIn('remote_status=' + ('0' if scenario == 'healthy' else '1'), run.stdout, run.stdout[-1500:] + run.stderr)
                self.assertIn('"metric": "http_reqs"', run.stdout)
                self.assertIn('delete job', (work / 'kubectl.log').read_text())
                if scenario == 'data_loss':
                    self.assertIn('ERROR: database contents changed after relocation', run.stdout, run.stdout[-1500:] + run.stderr)
                else:
                    self.assertNotIn('ERROR: database contents changed after relocation', run.stdout)
                if scenario == 'healthy':
                    self.assertIn('replacement_ready=', run.stdout)
                    data = recovered(cluster()); data['items'][3]['status']['conditions'][0]['status'] = 'True'
                    (work / 'relocated.json').write_text(json.dumps(data))
                    final = script.split("final_script=\"$(cat <<'FINAL'\n", 1)[1].split("\nFINAL", 1)[0]
                    check = subprocess.run([bash, '-c', prefix + 'work_dir="$FIXTURE_ROOT";\n' + common + '\neval "$remote_common"\n' + final], env=env, text=True, capture_output=True, timeout=10)
                    self.assertEqual(check.returncode, 0, check.stderr)
                    self.assertIn('final_state_verified=', check.stdout)


if __name__ == "__main__":
    unittest.main()
