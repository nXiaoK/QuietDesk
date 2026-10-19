import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "package-relay.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("package_relay", SCRIPT)
package_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package_module)


class RelayPackageTests(unittest.TestCase):
    def test_docker_package_is_complete_and_excludes_local_secrets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "work").mkdir()
            (root / "output").mkdir()
            names = ["Dockerfile", ".dockerignore", "compose.yaml", "compose.image.yaml", "deploy.sh", "docker/provision.sh", "README.md", "go.mod",
                     "cmd/quietdesk-relay/main.go", "server.go", "privatefile.go", "protocol.go", "server_test.go"]
            for name in names:
                path = root / "relay" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(name + "\n")
            (root / "LICENSE").write_text("license\n")
            subprocess.run(["git", "-C", str(root), "add", "relay", "LICENSE"], check=True)
            (root / "relay/privkey.pem").write_text("local private fixture\n")
            (root / "relay/untracked.go").write_text("local source\n")
            filename = package_module.package_docker(root, root / "output", "0.7.3", "abc123", True)
            with tarfile.open(root / "output" / filename) as archive:
                prefix = "QuietDesk-Relay-0.7.3-Docker/"
                self.assertEqual({item.name.removeprefix(prefix) for item in archive.getmembers() if item.isfile()},
                                 {*names, "LICENSE", "manifest.json"})
                manifest = json.load(archive.extractfile(prefix + "manifest.json"))
                self.assertEqual(manifest["revision"], "abc123")
                self.assertTrue(manifest["workingTreeDirty"])
                for name, digest in manifest["sha256"].items():
                    self.assertEqual(digest, hashlib.sha256(archive.extractfile(prefix + name).read()).hexdigest())
                self.assertEqual(archive.getmember(prefix + "deploy.sh").mode, 0o755)
            filename = package_module.package_docker(root, root / "output", "0.7.3", "abc123", True, include_source=False)
            with tarfile.open(root / "output" / filename) as archive:
                prefix = "QuietDesk-Relay-0.7.3-Docker-Deploy/"
                self.assertEqual({item.name.removeprefix(prefix) for item in archive.getmembers() if item.isfile()},
                                 {"compose.image.yaml", "deploy.sh", "README.md", "LICENSE", "manifest.json"})
                self.assertEqual(archive.getmember(prefix + "deploy.sh").mode, 0o755)
            (root / "relay/compose.yaml").unlink()
            with self.assertRaisesRegex(ValueError, "regular file"):
                package_module.package_docker(root, root / "output", "0.7.3", "abc123", True)


if __name__ == "__main__":
    unittest.main()
