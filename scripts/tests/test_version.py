import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from version import build_number, current, next_version, parse_version, plan_release


class VersionTests(unittest.TestCase):
    def test_validation_rejects_invalid_metadata(self):
        for value in ["1.2", "v1.2.3", "01.2.3", "1.2.-1", "1.2.3-beta", "1.2.3\n", "$(command)", None]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse_version(value)
        for value in [0, -1, "", "1\n", "01", "1.2", True]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                build_number(value)

    def test_first_release_and_numeric_tag_order(self):
        self.assertEqual(next_version("0.5.0", []), "0.5.0")
        self.assertEqual(next_version("0.5.0", ["v0.5.9", "v0.5.10"]), "0.5.11")
        self.assertEqual(next_version("0.6.0", ["v0.5.99"]), "0.6.0")

    def test_explicit_increments_reset_lower_components(self):
        self.assertEqual(next_version("0.5.0", [], "patch"), "0.5.1")
        self.assertEqual(next_version("0.5.0", ["v0.5.9"], "minor"), "0.6.0")
        self.assertEqual(next_version("0.5.0", ["v0.5.9"], "major"), "1.0.0")
        with self.assertRaises(ValueError):
            next_version("0.5.0", [], "unsupported")

    def test_source_archive_fallback_and_environment_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "version.json").write_text(json.dumps({"version": "0.5.2", "build": 8}))
            self.assertEqual(current(root, {}), {"version": "0.5.2", "build": 8})
            self.assertEqual(current(root, {"QUIETDESK_VERSION": "1.2.3", "QUIETDESK_BUILD_NUMBER": "15"}), {"version": "1.2.3", "build": 15})
            for environment in [{"QUIETDESK_VERSION": ""}, {"QUIETDESK_VERSION": "1.2.3;command"}, {"QUIETDESK_BUILD_NUMBER": "0"}]:
                with self.subTest(environment=environment), self.assertRaises(ValueError):
                    current(root, environment)


class GitVersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "version.json").write_text(json.dumps({"version": "0.5.0", "build": 6}))
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("add", "version.json")
        self.git("commit", "-m", "Fixture")

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.root), *arguments], text=True, stderr=subprocess.DEVNULL).strip()

    def tag(self, name="v0.5.0", run="100", build=7):
        self.git("tag", "-a", name, "-m", f"QuietDesk {name}\n\nWorkflow-Run: {run}\nBuild-Number: {build}")

    def test_tag_resolves_actual_release_metadata(self):
        self.tag("v0.5.3", build=10)
        self.git("tag", "v99.0.0-beta")
        self.assertEqual(current(self.root, {}), {"version": "0.5.3", "build": 10})

    def test_run_retries_reuse_tag_and_build_but_new_run_increments(self):
        first = plan_release(self.root, "auto", "100", "1")
        self.assertEqual((first["version"], first["build"]), ("0.5.0", 7))
        self.tag()
        retry = plan_release(self.root, "auto", "100", "1")
        self.assertTrue(retry["reused"])
        self.assertEqual((retry["version"], retry["build"]), ("0.5.0", 7))
        subsequent = plan_release(self.root, "auto", "101", "2")
        self.assertEqual((subsequent["version"], subsequent["build"]), ("0.5.1", 8))
        self.assertEqual(plan_release(self.root, "minor", "102", "3")["version"], "0.6.0")

    def test_old_tag_cannot_reuse_version_for_another_commit(self):
        self.tag()
        self.git("commit", "--allow-empty", "-m", "Next fixture")
        result = plan_release(self.root, "auto", "100", "1")
        self.assertFalse(result["reused"])
        self.assertEqual(result["version"], "0.5.1")

    def test_retrying_older_release_does_not_mark_it_latest(self):
        self.tag()
        self.tag("v0.6.0", run="101", build=8)
        result = plan_release(self.root, "auto", "100", "1")
        self.assertEqual(result["version"], "0.5.0")
        self.assertFalse(result["latest"])


if __name__ == "__main__":
    unittest.main()
