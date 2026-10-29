import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

import test_failure_experiment as fixtures


class RunnerTests(unittest.TestCase):
    def test_failed_ssm_command_preserves_stdout_and_failure_status(self):
        root = pathlib.Path(__file__).parent
        for bucket in ('', 'fixture-bucket'):
            with self.subTest(bucket=bucket), tempfile.TemporaryDirectory() as folder:
                work = pathlib.Path(folder)
                (work / 'aws').write_text('''#!/usr/bin/env bash
case "$1 $2" in
 'ssm send-command') echo command-fixture;;
 'ssm get-command-invocation') case "$*" in
  *StandardErrorContent*) echo remote-error;;
  *StandardOutputUrl*) echo https://s3.amazonaws.com/fixture-bucket/rollout/stdout;;
  *StandardOutputContent*) echo snapshot-evidence;;
  *) echo Failed;; esac;;
 's3 cp') printf 'snapshot-evidence'; printf 'x%.0s' {1..25000};;
esac
''')
                (work / 'aws').chmod(0o755)
                env = fixtures.shell_env(work, work_dir=work.as_posix(),
                                         SSM_LIB=(root / 'lib/ssm.sh').resolve().as_posix(), BUCKET=bucket)
                bash = 'C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' else shutil.which('bash')
                prefix = 'export PATH="$(cygpath -u "$work_dir")":$PATH; ' if os.name == 'nt' else ''
                run = subprocess.run([bash, '-c', prefix + 'set -Eeuo pipefail; source "$SSM_LIB"; ssm_run i-fixture "echo test" "$BUCKET" rollout'],
                                     env=env, text=True, capture_output=True, timeout=15)
                self.assertNotEqual(run.returncode, 0)
                self.assertIn('snapshot-evidence', run.stdout)
                if bucket: self.assertGreater(len(run.stdout), 24000)
                self.assertIn('remote-error', run.stderr)
                self.assertIn('finished with status Failed', run.stderr)

    def test_ssm_retrieval_failure_cannot_be_masked_by_success_status(self):
        root = pathlib.Path(__file__).parent
        with tempfile.TemporaryDirectory() as folder:
            work = pathlib.Path(folder)
            (work / 'aws').write_text('''#!/usr/bin/env bash
case "$1 $2" in
 'ssm send-command') echo command-fixture;;
 'ssm get-command-invocation') case "$*" in
  *StandardOutputUrl*) echo https://s3.amazonaws.com/fixture-bucket/rollout/stdout;;
  *StandardOutputContent*) exit 7;;
  *) echo Success;; esac;;
 's3 cp') exit 7;;
esac
''')
            (work / 'aws').chmod(0o755)
            for bucket in ('', 'fixture-bucket'):
                with self.subTest(bucket=bucket):
                    env = fixtures.shell_env(work, work_dir=work.as_posix(),
                                             SSM_LIB=(root / 'lib/ssm.sh').resolve().as_posix(), BUCKET=bucket)
                    bash = 'C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' else shutil.which('bash')
                    prefix = 'export PATH="$(cygpath -u "$work_dir")":$PATH; ' if os.name == 'nt' else ''
                    run = subprocess.run([bash, '-c', prefix + 'set -Eeuo pipefail; source "$SSM_LIB"; if ssm_run i-fixture "echo test" "$BUCKET" rollout; then echo masked-failure; fi'],
                                         env=env, text=True, capture_output=True, timeout=15)
                    self.assertNotEqual(run.returncode, 0)
                    self.assertNotIn('masked-failure', run.stdout)

    def test_remote_setup_error_is_reported_without_k6_traceback(self):
        with tempfile.TemporaryDirectory() as folder:
            work = pathlib.Path(folder)
            tools = {
                "terraform": '#!/usr/bin/env bash\ncase "${*: -1}" in control_plane_instance_id) echo i-fixture;; experiment_results_bucket_name) echo fixture-bucket;; *) exit 1;; esac\n',
                "aws": '''#!/usr/bin/env bash
case "$1 $2" in
 'ssm send-command') echo command-fixture;;
 'ssm get-command-invocation') case "$*" in *StandardOutputUrl*) echo https://s3.amazonaws.com/fixture-bucket/rollout/stdout;; *StandardOutputContent*) echo preflight-fixture;; *) echo Success;; esac;;
 's3 cp') echo 'error: configmaps already exists'; echo experiment_exit_status=1;;
 *) exit 1;;
esac
'''}
            for name, content in tools.items():
                path = work / name
                path.write_text(content)
                path.chmod(0o755)
            runner = pathlib.Path(__file__).parent / "run-pod-failure-experiment.sh"
            env = dict(os.environ, work_dir=work.as_posix(), TEST_RUNNER=runner.resolve().as_posix(), PYTHON=sys.executable.replace("\\", "/"), BEACH_FAILURE_RESULT_DIR=(work / "results").as_posix())
            bash = "C:/Program Files/Git/bin/bash.exe" if os.name == "nt" else shutil.which("bash")
            prefix = 'export PATH="$(cygpath -u "$work_dir")":$PATH; ' if os.name == "nt" else 'export PATH="$work_dir":$PATH; '
            run = subprocess.run([bash, "-c", prefix + '"$BASH" "$TEST_RUNNER" --confirm-dev fixture'], env=env, text=True, capture_output=True, timeout=15)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn("error: configmaps already exists", run.stderr)
            self.assertNotIn("Traceback", run.stderr)
            self.assertIn("experiment_exit_status=1", (work / "results" / "fixture" / "remote-output.txt").read_text())

    def test_existing_terraform_environment_is_used_in_child_shell(self):
        lib = pathlib.Path(__file__).parent / "lib" / "ssm.sh"
        env = dict(os.environ, TEST_SSM_LIB=lib.resolve().as_posix(), BEACH_TERRAFORM_ENVIRONMENT="/tmp/existing dev")
        bash = "C:/Program Files/Git/bin/bash.exe" if os.name == "nt" else shutil.which("bash")
        child = 'source "$TEST_SSM_LIB"; terraform() { printf "%s\\n" "$@"; }; terraform_output control_plane_instance_id; terraform_output_json node_instance_ids'
        result = subprocess.run([bash, "-c", 'exec "$BASH" -c "$1"', "test", child], env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["-chdir=/tmp/existing dev", "output", "-raw", "control_plane_instance_id", "-chdir=/tmp/existing dev", "output", "-json", "node_instance_ids"])

    def test_real_remote_shell_checks_baseline_uid_and_preserves_failure_output(self):
        root = pathlib.Path(__file__).parent
        remote = (root / "run-pod-failure-experiment.sh").read_text().split("<<'REMOTE'\n", 1)[1].split("\nREMOTE", 1)[0]
        for scenario in ("healthy", "previous_run", "bad_baseline", "delete_failure", "no_recovery"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as folder:
                work = pathlib.Path(folder)
                shutil.copy(root / "failure_results.py", work)
                shutil.copy(root.parent / "loadtest" / "k6-failure-job.yaml", work)
                (work / "state-source.json").write_text(json.dumps(fixtures.fixture()))
                lines = []
                for line in fixtures.FailureTests.output().splitlines():
                    if not line.startswith("{"):
                        continue
                    record = json.loads(line)
                    if record["metric"] in ("http_req_failed", "beach_status_5xx", "beach_connection_failures"):
                        record["data"]["value"] = 0
                    if scenario == "bad_baseline" and record["metric"] == "http_req_failed":
                        record["data"]["value"] = 1
                    lines.extend([json.dumps(record)] * 5)
                (work / "raw.json").write_text("\n".join(lines) + "\n")
                (work / "clock").write_text("1767225600")
                tools = {
                    "date": '''#!/usr/bin/env python3
import datetime as d,os,pathlib,sys
p=pathlib.Path(os.environ['work_dir'])/'clock'; t=int(p.read_text())
if '-d' in sys.argv: print(int(d.datetime.fromisoformat(sys.argv[3]).timestamp()))
elif sys.argv[-1]=='+%s': print(t); p.write_text(str(t+30))
else: print(d.datetime.fromtimestamp(t,d.timezone.utc).isoformat())
''',
                    "sleep": "#!/usr/bin/env bash\nexit 0\n",
                    "kubectl": '''#!/usr/bin/env python3
import json,os,pathlib,sys
p=pathlib.Path(os.environ['work_dir']); args=' '.join(sys.argv[1:]); scenario=os.environ['SCENARIO']
if 'get pods,' in args:
 data=json.loads((p/'state-source.json').read_text())
 if (p/'deleted').exists() and scenario!='no_recovery':
  data['items'][6]['metadata']['uid']='new'; data['items'][-2]['endpoints'][0]['targetRef']['uid']='new'
 print(json.dumps(data))
elif 'logs ' in args: print((p/'raw.json').read_text(),end='')
elif 'create configmap ' in args:
 name=args.split('create configmap ',1)[1].split()[0]
 if scenario=='previous_run' and name=='beach-k6-failure':
  print('error: configmaps "beach-k6-failure" already exists',file=sys.stderr); sys.exit(1)
 (p/'configmap-name').write_text(name)
elif 'create -f ' in args:
 manifest=pathlib.Path(sys.argv[-1]).read_text(); name=(p/'configmap-name').read_text()
 assert manifest.count('name: '+name+chr(10))==2, 'Job and ConfigMap names must match this run'
elif 'delete --raw' in args:
 options=json.loads((p/'delete.json').read_text()); assert options['preconditions']['uid']=='old' and options['gracePeriodSeconds']==0
 (p/'deleted').touch()
 if scenario=='delete_failure': print('DELETE_FAILED_DETAIL',file=sys.stderr); sys.exit(1)
elif 'get job ' in args: print(1)
elif 'version ' in args: print('gitVersion: fixture')
'''}
                for name, content in tools.items():
                    path = work / name
                    path.write_text(content)
                    path.chmod(0o755)
                env = fixtures.shell_env(work, work_dir=work.as_posix(), SCENARIO=scenario)
                bash = shutil.which("bash")
                if os.name == "nt":
                    bash = "C:/Program Files/Git/bin/bash.exe"
                    remote_command = 'export PATH="$(cygpath -u "$work_dir")":$PATH\n' + remote
                else:
                    remote_command = remote
                run = subprocess.run([bash, "-c", remote_command], env=env, text=True, capture_output=True, timeout=30)
                output = run.stdout
                self.assertEqual(run.returncode, 0, output[-1000:] + run.stderr)
                self.assertTrue('"metric": "http_reqs"' in output)
                if scenario in ("healthy", "previous_run"):
                    self.assertTrue("experiment_exit_status=0" in output, output[:1000] + output[-1000:])
                    self.assertTrue("replacement_ready=" in output)
                    self.assertTrue(fixtures.f.summarize(output)["passed"])
                else:
                    self.assertTrue("experiment_exit_status=1" in output)
                if scenario == "bad_baseline":
                    self.assertFalse((work / "deleted").exists())
                if scenario == "delete_failure":
                    self.assertTrue("DELETE_FAILED_DETAIL" in output)


if __name__ == "__main__":
    unittest.main()
