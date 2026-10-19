import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/configure-update-feed.py"
spec = importlib.util.spec_from_file_location("configure_update_feed", SCRIPT)
configuration_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configuration_module)


class UpdateBuildConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.config = self.root / "feed.json"
        self.key = {"id": "test", "key": base64.b64encode(bytes(range(32))).decode()}
        self.feed = "https://github.com/nXiaoK/QuietDesk/releases/latest/download/QuietDesk-update.json"
        self.config.write_text(json.dumps({"feedURL": self.feed, "publicKeys": [self.key]}))

    def tearDown(self):
        self.temporary.cleanup()

    def read(self, bundle="local.quietdesk.app", environment=None):
        return configuration_module.configuration(self.config, bundle, environment or {})

    def test_production_uses_checked_in_source(self):
        self.assertEqual(self.read(), {"feedURL": self.feed, "publicKeys": [self.key]})

    def test_preview_defaults_to_disabled(self):
        self.assertEqual(self.read("local.quietdesk.checks.updater"), {"feedURL": "", "publicKeys": []})

    def test_preview_loopback_requires_explicit_keys(self):
        environment = {"QUIETDESK_UPDATE_FEED_URL": "http://127.0.0.1:9876/update.json", "QUIETDESK_UPDATE_PUBLIC_KEYS": json.dumps([self.key])}
        self.assertEqual(self.read("local.quietdesk.checks.updater", environment)["publicKeys"], [self.key])
        for name in environment:
            with self.assertRaisesRegex(ValueError, "non-production"):
                self.read(environment={name: environment[name]})

    def test_empty_overrides_disable_preview(self):
        self.assertEqual(self.read("local.quietdesk.checks.updater", {"QUIETDESK_UPDATE_FEED_URL": "", "QUIETDESK_UPDATE_PUBLIC_KEYS": ""}), {"feedURL": "", "publicKeys": []})

    def test_rejects_untrusted_sources_and_malformed_keys(self):
        for feed in ("http://github.com/nXiaoK/QuietDesk/releases/latest/download/QuietDesk-update.json", "https://example.com/update.json", "https://user@github.com/nXiaoK/QuietDesk/releases/latest/download/QuietDesk-update.json", "https://@github.com/nXiaoK/QuietDesk/releases/latest/download/QuietDesk-update.json", self.feed + "?token=value"):
            self.config.write_text(json.dumps({"feedURL": feed, "publicKeys": [self.key]}))
            with self.assertRaises(ValueError):
                self.read()
        for keys in ([self.key, self.key], [{"id": "test", "key": "bad"}], [{"id": 4, "key": self.key["key"]}]):
            self.config.write_text(json.dumps({"feedURL": self.feed, "publicKeys": keys}))
            with self.assertRaises(ValueError):
                self.read()

    def test_inserts_valid_plist_without_xml_interpolation(self):
        plist = self.root / "Info.plist"
        plist.write_bytes(plistlib.dumps({"CFBundleIdentifier": "local.quietdesk.app"}))
        environment = {name: value for name, value in os.environ.items() if not name.startswith("QUIETDESK_UPDATE_") and name != "QUIETDESK_BUNDLE_IDENTIFIER"}
        subprocess.run(["python3", str(SCRIPT), "--config", str(self.config), "--plist", str(plist)], env=environment, check=True, capture_output=True)
        value = plistlib.loads(plist.read_bytes())
        self.assertEqual(value["QuietDeskUpdateFeedURL"], self.feed)
        self.assertEqual(value["QuietDeskUpdatePublicKeys"], [self.key])
        subprocess.run(["plutil", "-lint", str(plist)], check=True, capture_output=True)


class UpdateReleaseWorkflowTests(unittest.TestCase):
    def test_preflight_runs_before_any_release_side_effect(self):
        value = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertLess(value.index("name: Allocate version"), value.index("name: Preflight update signing"))
        self.assertLess(value.index("name: Preflight update signing"), value.index("name: Run project checks"))
        self.assertLess(value.index("name: Preflight update signing"), value.index("git tag -a"))
        self.assertIn("echo 'skip=true'", value)
        self.assertIn("if: steps.draft.outputs.skip != 'true' &&", value)
        self.assertLess(value.index('"$tool" verify'), value.index("name: Publish verified release"))
        self.assertIn("dist/QuietDesk-update.json", value[value.index("name: Save packages"):value.index("name: Publish verified release")])
        publish = value[value.index("name: Publish verified release"):]
        self.assertNotIn("QUIETDESK_UPDATE_SIGNING_KEY", publish)
        self.assertLess(publish.index("gh release upload"), publish.index("--draft=false"))

    def test_release_never_sets_test_source_overrides(self):
        value = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertNotIn("QUIETDESK_UPDATE_FEED_URL:", value)
        self.assertNotIn("QUIETDESK_UPDATE_PUBLIC_KEYS:", value)
        self.assertNotIn("QUIETDESK_BUNDLE_IDENTIFIER:", value)


if __name__ == "__main__":
    unittest.main()
