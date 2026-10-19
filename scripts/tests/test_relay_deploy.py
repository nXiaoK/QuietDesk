import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class RelayDeployTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "work").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-deploy-check-", dir=ROOT / "work")
        self.root = Path(self.temporary.name)
        self.deployment = self.root / "deployment"
        self.deployment.mkdir()
        for name in ["deploy.sh", "compose.image.yaml"]:
            shutil.copy2(ROOT / "relay" / name, self.deployment / name)
        executable = self.root / "bin"
        executable.mkdir()
        docker = executable / "docker"
        docker.write_text("""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
arguments = sys.argv[1:]
with open(os.environ['QUIETDESK_DOCKER_TEST_LOG'], 'a') as log:
    log.write(json.dumps(arguments) + '\\n')
if os.environ.get('QUIETDESK_DOCKER_TEST_FAIL') in arguments:
    sys.exit(42)
if 'run' in arguments:
    Path(os.environ['QUIETDESK_DOCKER_TEST_ARCHIVE']).write_bytes(sys.stdin.buffer.read())
""")
        docker.chmod(0o755)
        self.log = self.root / "docker.jsonl"
        self.environment = {**os.environ, "PATH": str(executable) + os.pathsep + os.environ.get("PATH", ""),
                            "QUIETDESK_DOCKER_TEST_LOG": str(self.log), "QUIETDESK_DOCKER_TEST_ARCHIVE": str(self.root / "input.tar")}

    def tearDown(self):
        self.temporary.cleanup()

    def deploy(self, *arguments, success=True, failure=None):
        environment = dict(self.environment)
        if failure:
            environment["QUIETDESK_DOCKER_TEST_FAIL"] = failure
        result = subprocess.run(["sh", str(self.deployment / "deploy.sh"), *arguments], env=environment, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stderr.decode())
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def test_image_deployment_needs_no_sources_and_never_builds(self):
        _, calls = self.deploy("--ip", "2001:db8::10")
        self.assertFalse(any("build" in call for call in calls))
        self.assertTrue(any(call[-2:] == ["pull", "relay"] for call in calls))
        provision = next(call for call in calls if "run" in call)
        self.assertEqual(provision[-3:], ["provision", "--ip", "2001:db8::10"])
        self.assertEqual(provision[provision.index("--pull") + 1], "never")
        startup = next(call for call in calls if "up" in call)
        self.assertIn("--no-build", startup)
        self.assertIn("--wait", startup)
        self.assertEqual(startup[startup.index("--pull") + 1], "never")
        self.assertTrue(all("compose.yaml" not in call for call in calls))
        self.assertEqual({path.name for path in self.deployment.iterdir()}, {"deploy.sh", "compose.image.yaml"})
        self.assertEqual(list((self.root / "work").iterdir()), [])

    def test_source_default_remains_build_and_explicit_pull_uses_image_configuration(self):
        shutil.copy2(ROOT / "relay/compose.yaml", self.deployment / "compose.yaml")
        _, calls = self.deploy("--ip", "192.0.2.10")
        self.assertTrue(any(call[-2:] == ["build", "relay"] for call in calls))
        self.assertFalse(any(call[-2:] == ["pull", "relay"] for call in calls))
        self.log.unlink()
        _, calls = self.deploy("--pull", "--ip", "192.0.2.10")
        self.assertFalse(any("build" in call for call in calls))
        self.assertTrue(any(call[-2:] == ["pull", "relay"] for call in calls))
        self.assertTrue(all("compose.yaml" not in call for call in calls))

    def test_pull_or_provision_failure_never_starts_or_deletes_service(self):
        for stage in ["info", "pull", "run"]:
            with self.subTest(stage=stage):
                self.log.unlink(missing_ok=True)
                _, calls = self.deploy("--ip", "192.0.2.10", success=False, failure=stage)
                self.assertFalse(any("up" in call or "down" in call or "stop" in call for call in calls))
                self.assertEqual(list((self.root / "work").iterdir()), [])

    def test_manual_certificate_paths_with_spaces_are_streamed_without_host_mounts(self):
        certificate, key = self.root / "chain with spaces.pem", self.root / "private with spaces.pem"
        certificate.write_bytes(b"public fixture")
        key.write_bytes(b"private fixture")
        result, calls = self.deploy(str(certificate), str(key))
        self.assertNotIn(key.read_bytes(), result.stdout + result.stderr)
        self.assertFalse(any("--volume" in call or "-v" in call for call in calls))
        with tarfile.open(self.root / "input.tar") as archive:
            self.assertEqual(set(archive.getnames()), {"fullchain.pem", "privkey.pem"})
            self.assertEqual(archive.extractfile("privkey.pem").read(), key.read_bytes())
        self.assertEqual(list((self.root / "work").iterdir()), [])

    def test_missing_configuration_and_invalid_ip_do_not_call_docker(self):
        self.deploy("--ip", "192.0.2.1,DNS:other", success=False)
        self.assertFalse(self.log.exists())
        (self.deployment / "compose.image.yaml").unlink()
        self.deploy("--ip", "192.0.2.10", success=False)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
