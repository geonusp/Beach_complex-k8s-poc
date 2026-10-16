import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

import test_failure_experiment as fixtures


class RunnerTests(unittest.TestCase):
    def test_real_remote_shell_checks_baseline_uid_and_preserves_failure_output(self):
        root = pathlib.Path(__file__).parent
        remote = (root / "run-pod-failure-experiment.sh").read_text().split("<<'REMOTE'\n", 1)[1].split("\nREMOTE", 1)[0]
        for scenario in ("healthy", "bad_baseline", "delete_failure", "no_recovery"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as folder:
                work = pathlib.Path(folder)
                shutil.copy(root / "failure_results.py", work)
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
                env = dict(os.environ, work_dir=work.as_posix(), SCENARIO=scenario)
                env["PATH"] = work.as_posix() + os.pathsep + env["PATH"]
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
                if scenario == "healthy":
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
