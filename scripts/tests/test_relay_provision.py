import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class RelayProvisionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        candidates = [shutil.which("openssl")]
        if shutil.which("brew"):
            prefix = subprocess.run(["brew", "--prefix", "openssl@3"], capture_output=True, text=True)
            if prefix.returncode == 0:
                candidates.append(str(Path(prefix.stdout.strip()) / "bin/openssl"))
        for candidate in filter(None, candidates):
            if not Path(candidate).is_file():
                continue
            help_text = subprocess.run([candidate, "x509", "-help"], capture_output=True, text=True)
            if "-checkip" in help_text.stdout + help_text.stderr:
                cls.openssl_binary = candidate
                cls.openssl_environment = {**os.environ, "PATH": str(Path(candidate).parent) + os.pathsep + os.environ.get("PATH", "")}
                return
        raise unittest.SkipTest("Relay provisioner checks require OpenSSL with x509 -checkip (OpenSSL 3 recommended)")

    def setUp(self):
        (ROOT / "work").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-provision-check-", dir=ROOT / "work")
        self.root = Path(self.temporary.name)
        self.tls, self.state = self.root / "tls", self.root / "state"
        self.tls.mkdir(mode=0o700)
        self.state.mkdir(mode=0o700)
        # Run the actual provisioner with only its two volume paths isolated.
        source = (ROOT / "relay/docker/provision.sh").read_text()
        self.script = self.root / "provision.sh"
        self.script.write_text(source.replace("/etc/quietdesk-relay", str(self.tls)).replace("/var/lib/quietdesk-relay", str(self.state)))

    def tearDown(self):
        self.temporary.cleanup()

    def provision(self, *arguments, success=True, archive=None):
        result = subprocess.run(["sh", str(self.script), *arguments], input=archive, capture_output=True, env=self.openssl_environment)
        self.assertEqual(result.returncode == 0, success, result.stderr.decode())
        return result

    def openssl(self, *arguments):
        return subprocess.check_output([self.openssl_binary, *arguments], stderr=subprocess.DEVNULL)

    def test_first_ip_deployment_generates_valid_identity_and_reuses_it(self):
        result = self.provision("--ip", "192.0.2.10")
        certificate = self.tls / "fullchain.pem"
        der = self.openssl("x509", "-in", str(certificate), "-outform", "DER")
        fingerprint = ":".join(re.findall("..", hashlib.sha256(der).hexdigest().upper()))
        self.assertIn(fingerprint.encode(), result.stdout)
        self.openssl("x509", "-in", str(certificate), "-noout", "-checkip", "192.0.2.10")
        self.openssl("verify", "-trusted", str(certificate), "-verify_ip", "192.0.2.10", "-purpose", "sslserver", str(certificate))
        code = (self.state / "access.key").read_bytes()
        self.assertRegex(code.decode(), r"^[0-9a-f]{64}\n$")
        self.assertNotIn(code.strip(), result.stdout + result.stderr)
        for path in [certificate, self.tls / "privkey.pem", self.state / "access.key"]:
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.stat().st_nlink, 1)
        (self.state / "devices.json").write_text('{"version":1,"owners":{}}')
        before = {path: path.read_bytes() for path in [certificate, self.tls / "privkey.pem", self.state / "access.key", self.state / "devices.json"]}
        self.provision("--ip", "192.0.2.10")
        for path, data in before.items():
            self.assertEqual(path.read_bytes(), data)
        self.provision("--ip", "192.0.2.11", success=False)
        for path, data in before.items():
            self.assertEqual(path.read_bytes(), data)

    def test_ipv6_and_invalid_addresses(self):
        for address in ["", "example.com", "1.2.3.4,DNS:other", "999.1.1.1", "::::"]:
            with self.subTest(address=address):
                self.provision("--ip", address, success=False)
                self.assertFalse((self.tls / "fullchain.pem").exists())
                self.assertFalse((self.state / "access.key").exists())
        self.provision("--ip", "2001:db8::10")
        self.openssl("x509", "-in", str(self.tls / "fullchain.pem"), "-noout", "-checkip", "2001:db8::10")

    def test_partial_identity_and_lost_access_key_are_not_reset(self):
        (self.tls / "privkey.pem").write_text("incomplete fixture")
        self.provision("--ip", "192.0.2.10", success=False)
        self.assertEqual((self.tls / "privkey.pem").read_text(), "incomplete fixture")
        (self.tls / "privkey.pem").unlink()
        (self.state / "devices.json").write_text('{"version":1,"owners":{}}')
        self.provision("--ip", "192.0.2.10", success=False)
        self.assertFalse((self.state / "access.key").exists())
        self.assertFalse((self.tls / "fullchain.pem").exists())
        (self.state / "devices.json").unlink()
        (self.state / "access.key").write_text("existing access fixture")
        self.provision("--ip", "192.0.2.10", success=False)
        self.assertFalse((self.tls / "fullchain.pem").exists())
        self.assertEqual((self.state / "access.key").read_text(), "existing access fixture")

    def test_expired_identity_and_manual_mismatch_preserve_installed_files(self):
        self.provision("--ip", "192.0.2.10")
        certificate, key = self.tls / "fullchain.pem", self.tls / "privkey.pem"
        expired = self.root / "expired.pem"
        csr = self.root / "expired.csr"
        self.openssl("req", "-new", "-key", str(key), "-subj", "/CN=fixture", "-addext", "subjectAltName=IP:192.0.2.10", "-out", str(csr))
        (self.root / "index").write_text("")
        (self.root / "serial").write_text("01\n")
        configuration = self.root / "ca.cnf"
        configuration.write_text(f"[ca]\ndefault_ca=node\n[node]\ndatabase={self.root}/index\nserial={self.root}/serial\n"
                                 f"new_certs_dir={self.root}\ndefault_md=sha256\npolicy=policy\ncopy_extensions=copy\n"
                                 "[policy]\ncommonName=supplied\n")
        self.openssl("ca", "-batch", "-selfsign", "-notext", "-config", str(configuration), "-keyfile", str(key),
                     "-cert", str(certificate), "-in", str(csr), "-out", str(expired),
                     "-startdate", "200101000000Z", "-enddate", "210101000000Z")
        certificate.write_bytes(expired.read_bytes())
        self.provision("--ip", "192.0.2.10", success=False)
        self.assertEqual(certificate.read_bytes(), expired.read_bytes())
        # A valid but unrelated private key must not replace the existing pair.
        candidate = self.root / "candidate"
        candidate.mkdir()
        self.openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=fixture",
                     "-addext", "subjectAltName=IP:192.0.2.10", "-keyout", str(candidate / "privkey.pem"),
                     "-out", str(candidate / "fullchain.pem"))
        (candidate / "privkey.pem").write_bytes(key.read_bytes())
        archive = self.root / "tls.tar"
        with tarfile.open(archive, "w") as bundle:
            for name in ["fullchain.pem", "privkey.pem"]:
                bundle.add(candidate / name, arcname=name)
        before = certificate.read_bytes(), key.read_bytes()
        self.provision(success=False, archive=archive.read_bytes())
        self.assertEqual((certificate.read_bytes(), key.read_bytes()), before)


if __name__ == "__main__":
    unittest.main()
