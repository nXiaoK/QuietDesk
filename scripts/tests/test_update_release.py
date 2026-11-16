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

    def test_code_signing_keychain_lifecycle_and_secret_scoping(self):
        value = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertLess(value.index("name: Preflight code signing"), value.index("name: Run project checks"))
        self.assertLess(value.index("name: Run project checks"), value.index("name: Import code signing certificate"))
        self.assertLess(value.index("name: Import code signing certificate"), value.index("name: Build Universal application"))
        self.assertLess(value.index("name: Package DMG, ZIP and source"), value.index("name: Remove temporary code signing keychain"))
        self.assertLess(value.index("name: Remove temporary code signing keychain"), value.index("name: Create draft release and upload packages"))
        cleanup_section = value[value.index("name: Remove temporary code signing keychain"):value.index("name: Build Linux relay packages")]
        self.assertIn("if: always()", cleanup_section)
        after_cleanup = value[value.index("name: Create draft release and upload packages"):]
        self.assertNotIn("QUIETDESK_CODESIGN_P12_BASE64", after_cleanup)
        self.assertNotIn("QUIETDESK_CODESIGN_P12_PASSWORD", after_cleanup)


class CICodeSigningScriptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def make_p12(self, password="synthetic-pass-secret", include_key=True):
        conf = self.root / "cert.conf"
        conf.write_text(
            "[req]\ndefault_bits=2048\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n"
            "[dn]\nCN=QuietDesk Test Code Signing\n"
            "[ext]\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nbasicConstraints=critical,CA:FALSE\n"
        )
        key = self.root / "test.key"
        crt = self.root / "test.crt"
        p12 = self.root / "test.p12"
        subprocess.run(
            ["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", str(key), "-out", str(crt), "-days", "2", "-config", str(conf)],
            check=True, capture_output=True
        )
        fp = subprocess.check_output(
            ["/usr/bin/openssl", "x509", "-in", str(crt), "-noout", "-fingerprint", "-sha1"],
            text=True
        ).split("=", 1)[1].replace(":", "").strip()
        cmd = ["/usr/bin/openssl", "pkcs12", "-export", "-out", str(p12), "-in", str(crt), "-passout", f"pass:{password}"]
        if include_key:
            cmd.extend(["-inkey", str(key)])
        else:
            cmd.append("-nokeys")
        subprocess.run(cmd, check=True, capture_output=True)
        return base64.b64encode(p12.read_bytes()).decode(), crt, key, fp

    def test_preflight_allows_missing_secret_and_validates_configured_p12(self):
        script = ROOT / "scripts/import-ci-cert.sh"
        empty_env = {**os.environ, "QUIETDESK_CODESIGN_P12_BASE64": "", "RUNNER_TEMP": str(self.root)}
        empty_res = subprocess.run(["bash", str(script), "--preflight"], env=empty_env, capture_output=True, text=True)
        self.assertEqual(empty_res.returncode, 0)
        self.assertIn("ad-hoc", empty_res.stdout)

        b64, _, _, sha1 = self.make_p12(password="s3cr3t-pass-99")
        valid_env = {
            **os.environ,
            "QUIETDESK_CODESIGN_P12_BASE64": b64,
            "QUIETDESK_CODESIGN_P12_PASSWORD": "s3cr3t-pass-99",
            "QUIETDESK_SIGNING_LEAF_SHA1": sha1.lower(),
            "RUNNER_TEMP": str(self.root),
        }
        valid_res = subprocess.run(["bash", str(script), "--preflight"], env=valid_env, capture_output=True, text=True)
        self.assertEqual(valid_res.returncode, 0, valid_res.stderr)
        self.assertIn(sha1.upper(), valid_res.stdout)
        self.assertNotIn("s3cr3t-pass-99", valid_res.stdout + valid_res.stderr)

        wrong_pass_env = {**valid_env, "QUIETDESK_CODESIGN_P12_PASSWORD": "wrong-password-value"}
        wrong_res = subprocess.run(["bash", str(script), "--preflight"], env=wrong_pass_env, capture_output=True, text=True)
        self.assertNotEqual(wrong_res.returncode, 0)
        self.assertNotIn("wrong-password-value", wrong_res.stdout + wrong_res.stderr)
        self.assertNotIn(b64[:32], wrong_res.stdout + wrong_res.stderr)

        wrong_pin_env = {**valid_env, "QUIETDESK_SIGNING_LEAF_SHA1": "0" * 40}
        pin_res = subprocess.run(["bash", str(script), "--preflight"], env=wrong_pin_env, capture_output=True, text=True)
        self.assertNotEqual(pin_res.returncode, 0)

    def test_export_and_trust_scripts_enforce_repo_and_private_key_guards(self):
        export_script = ROOT / "scripts/export-ci-cert.sh"
        inside_repo = ROOT / "dist/forbidden-secrets"
        res = subprocess.run(["bash", str(export_script), "--out-dir", str(inside_repo)], capture_output=True, text=True)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Git 仓库", res.stderr)

        _, crt, key, _ = self.make_p12()
        combined = self.root / "combined-with-key.pem"
        combined.write_text(crt.read_text() + "\n" + key.read_text())
        trust_script = ROOT / "scripts/trust-cert.sh"
        trust_res = subprocess.run(["bash", str(trust_script), str(combined)], capture_output=True, text=True)
        self.assertNotEqual(trust_res.returncode, 0)
        self.assertIn("私钥", trust_res.stderr)


if __name__ == "__main__":
    unittest.main()
