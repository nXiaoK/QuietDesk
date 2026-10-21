import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SHELL = shutil.which("dash") or "sh"
KEY = "ab" * 32
HEALTH = {"connections": 2, "onlineDevices": 1, "pendingTunnels": 0, "activeTunnels": 1, "datagramSessions": 1,
          "forwardedDatagramBytes": 10, "rejectedDatagrams": 0, "assistedLeases": 1}

# A stateful stand-in for the Docker CLI: just enough of compose, inspect, exec and run to drive every path.
FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
arguments = sys.argv[1:]
state_path = Path(os.environ["FAKE_DOCKER_STATE"])
state = json.loads(state_path.read_text())
environment = {key: os.environ.get(key) for key in ["QUIETDESK_RELAY_IMAGE", "QUIETDESK_RELAY_PORT", "COMPOSE_PROJECT_NAME"]}
with open(os.environ["FAKE_DOCKER_LOG"], "a") as log:
    log.write(json.dumps({"arguments": arguments, "environment": environment}) + "\n")
project = state.get("project", "quietdesk-relay")
container = state.get("container")

def save():
    state_path.write_text(json.dumps(state))

def resolve(reference):
    # Retagging never deletes an image, so any ID the fixture has used stays resolvable.
    return state["images"].get(reference) or (reference if reference.startswith("sha256:") else None)

def identity(command):
    text = " ".join(command)
    if command[0] == "cat" and command[-1] == "/var/lib/quietdesk-relay/access.key":
        return print(state["key"])
    if command[0] == "openssl" and "-fingerprint" in command:
        return print("sha256 Fingerprint=AA:BB:CC")
    if command[0] == "openssl" and "-enddate" in command:
        return print("notAfter=Oct 21 00:00:00 2027 GMT")
    if command[0] == "openssl" and "-checkend" in command:
        sys.exit(0)
    if command[0] == "openssl" and "subjectAltName" in text:
        return print("X509v3 Subject Alternative Name: \n    " + state["san"])
    if command[0] == "wget":
        return print(json.dumps(state["health"]))
    sys.exit(3)

def mounts():
    return {argument.split(":")[1]: argument.split(":")[0] for index, argument in enumerate(arguments)
            if index and arguments[index - 1] == "-v"}

command = arguments[0]
if command == "info":
    print(json.dumps(state.get("security", ["name=seccomp"])) if "--format" in arguments else "Server: fake")
elif command == "compose":
    if arguments[1] == "version":
        print("Docker Compose version v2.30.0"); sys.exit(0)
    sub = arguments[3]
    image = environment["QUIETDESK_RELAY_IMAGE"]
    if sub == "pull":
        if state.get("fail_pull"): sys.exit(1)
        state["images"][image] = state["pull"]
    elif sub == "run":
        address = arguments[arguments.index("--ip") + 1]
        if state.get("san") and address not in state["san"]: sys.exit(1)
        state["san"] = state.get("san") or "IP Address:" + address
        for volume in ["_state", "_tls"]:
            if project + volume not in state["volumes"]: state["volumes"].append(project + volume)
    elif sub == "up":
        resolved = resolve(image)
        if resolved is None or resolved == state.get("fail_up_for"):
            if container: container["running"] = False
            save(); sys.exit(1)
        state["container"] = {"id": "c0ffee", "image": resolved, "running": True,
                              "port": environment["QUIETDESK_RELAY_PORT"], "revision": state["revisions"].get(resolved, "")}
    else:
        sys.exit(2)
elif command == "ps":
    if container: print(container["id"])
elif command == "inspect":
    template, target = arguments[arguments.index("--format") + 1], arguments[-1]
    if not container or target != container["id"]: sys.exit(1)
    if "PortBindings" in template: print(container["port"] + " ")
    elif "State.Running" in template: print("true" if container["running"] else "false")
    elif "State.Status" in template: print("running / healthy" if container["running"] else "exited")
    elif "{{.Image}}" in template: print(container["image"])
    elif "revision" in template: print(container["revision"] or "<no value>")
    else: sys.exit(4)
elif command == "image" and arguments[1] == "inspect":
    resolved = resolve(arguments[-1])
    if resolved is None: sys.exit(1)
    print(resolved)
elif command == "image" and arguments[1] == "rm":
    state["images"].pop(arguments[-1], None)
elif command == "tag":
    state["images"][arguments[2]] = resolve(arguments[1])
elif command == "exec":
    if not container or not container["running"]: sys.exit(1)
    identity(arguments[2:])
elif command == "run":
    volumes = mounts()
    if any(source.startswith(project) and source not in state["volumes"] for source in volumes.values()): sys.exit(1)
    entry = arguments[arguments.index("--entrypoint") + 1]
    tail = arguments[arguments.index("--entrypoint") + 2:]
    image_index = next(index for index, value in enumerate(tail) if not value.startswith("-") and (index == 0 or tail[index - 1] not in ("-v",)))
    command_arguments = tail[image_index + 1:]
    if entry == "sh" and "tar" in command_arguments[1]:
        if state.get("fail_backup"): sys.exit(1)
        Path(volumes["/backup"], "relay-" + command_arguments[-1] + ".tar.gz").write_text("backup")
    else:
        identity([entry, *command_arguments])
elif command == "rm":
    state["container"] = None
elif command == "network":
    pass
elif command == "volume" and arguments[1] == "inspect":
    sys.exit(0 if arguments[2] in state["volumes"] else 1)
elif command == "volume" and arguments[1] == "rm":
    state["volumes"].remove(arguments[2])
else:
    sys.exit(5)
save()
'''

FAKE_CURL = r'''#!/usr/bin/env python3
import json, os, sys
url = sys.argv[-1]
with open(os.environ["FAKE_CURL_LOG"], "a") as log:
    log.write(url + "\n")
responses = json.loads(os.environ.get("FAKE_CURL_RESPONSES", "{}"))
if url not in responses:
    sys.exit(22)
sys.stdout.write(open(responses[url][5:]).read() if responses[url].startswith("file:") else responses[url])
'''


class RelayManagerTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "work").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-manager-check-", dir=ROOT / "work")
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        for name in ["quietdesk-relay.sh", "compose.image.yaml"]:
            shutil.copy2(ROOT / "relay" / name, self.source / name)
        self.directory = self.root / "opt" / "quietdesk-relay"
        binaries = self.root / "bin"
        binaries.mkdir()
        tools = {
            "docker": FAKE_DOCKER, "curl": FAKE_CURL,
            "id": '#!/bin/sh\necho "${FAKE_UID:-0}"\n',
            "uname": "#!/bin/sh\necho Linux\n",
            "ss": '#!/bin/sh\necho "State Recv-Q Send-Q Local Address:Port Peer Address:Port"\n'
                  '[ -z "${FAKE_SS_BUSY:-}" ] || echo "LISTEN 0 4096 0.0.0.0:7443 0.0.0.0:*"\n',
            "ip": '#!/bin/sh\necho "1.1.1.1 via 10.0.0.1 dev eth0 src ${FAKE_ROUTE_SOURCE:-10.0.0.5} uid 0"\n',
        }
        for name, content in tools.items():
            (binaries / name).write_text(content)
            (binaries / name).chmod(0o755)
        self.state_path = self.root / "docker-state.json"
        self.log = self.root / "docker.jsonl"
        self.curl_log = self.root / "curl.log"
        self.state = {"container": None, "images": {}, "pull": "sha256:new", "volumes": [], "san": "",
                      "revisions": {"sha256:new": "f2eb871720f5fb051254c46acbc5502789ed64ae", "sha256:old": "d0f21a9"},
                      "key": KEY, "health": HEALTH}
        self.environment = {**os.environ, "PATH": str(binaries) + os.pathsep + os.environ.get("PATH", ""),
                            "FAKE_DOCKER_STATE": str(self.state_path), "FAKE_DOCKER_LOG": str(self.log),
                            "FAKE_CURL_LOG": str(self.curl_log),
                            "FAKE_CURL_RESPONSES": json.dumps({"https://ifconfig.me/ip": "198.51.100.7\n",
                                                               "https://ipv4.icanhazip.com": "10.0.0.5\n"})}
        for key in ["QUIETDESK_RELAY_IMAGE", "QUIETDESK_RELAY_DIR", "COMPOSE_PROJECT_NAME", "QUIETDESK_RELAY_PORT"]:
            self.environment.pop(key, None)

    def tearDown(self):
        self.temporary.cleanup()

    def installed(self, port="443", image="sha256:old"):
        self.state.update(container={"id": "c0ffee", "image": image, "running": True, "port": port, "revision": "d0f21a9"},
                          images={"ghcr.io/nxiaok/quietdesk-relay:latest": image},
                          volumes=["quietdesk-relay_state", "quietdesk-relay_tls"], san="IP Address:198.51.100.7")

    def run_manager(self, *arguments, success=True, script=None, stdin=None, **environment):
        self.state_path.write_text(json.dumps(self.state))
        self.log.unlink(missing_ok=True)
        command = [SHELL, str(script or self.source / "quietdesk-relay.sh"), *arguments, "--dir", str(self.directory)]
        if stdin is not None:
            command = [SHELL, "-s", "--", *arguments, "--dir", str(self.directory)]
        # A new session has no controlling terminal, so every prompt path behaves as unattended.
        result = subprocess.run(command, env={**self.environment, **environment}, capture_output=True, text=True,
                                input=stdin, cwd=self.root, start_new_session=True, timeout=60)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.state = json.loads(self.state_path.read_text())
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result.stdout + result.stderr, calls

    @staticmethod
    def compose(calls, subcommand):
        return [call for call in calls if call["arguments"][:1] == ["compose"] and call["arguments"][3:4] == [subcommand]]

    def test_fresh_install_detects_public_ip_and_shows_connection_details(self):
        output, calls = self.run_manager("install")
        self.assertIn("检测到公网 IP：198.51.100.7（来源：https://ifconfig.me/ip）", output)
        self.assertNotIn("10.0.0.5", output)
        provision = self.compose(calls, "run")[0]["arguments"]
        self.assertEqual(provision[-3:], ["provision", "--ip", "198.51.100.7"])
        self.assertEqual(provision[provision.index("--pull") + 1], "never")
        startup = self.compose(calls, "up")[0]
        self.assertIn("--wait", startup["arguments"])
        self.assertEqual(startup["environment"]["QUIETDESK_RELAY_PORT"], "7443")
        self.assertEqual(startup["environment"]["QUIETDESK_RELAY_IMAGE"], "ghcr.io/nxiaok/quietdesk-relay:latest")
        for expected in ["服务地址  tls://198.51.100.7:7443", "接入码    " + KEY, "证书指纹  AA:BB:CC",
                         "节点版本  f2eb871", "协商打洞 1", "放行 TCP 和 UDP 7443"]:
            self.assertIn(expected, output)
        self.assertFalse([call for call in calls if call["arguments"][0] in ("rm", "tag") or call["arguments"][:2] == ["volume", "rm"]])
        self.assertEqual((self.directory / "compose.image.yaml").read_bytes(), (ROOT / "relay/compose.image.yaml").read_bytes())
        self.assertEqual((self.directory / "quietdesk-relay.sh").read_bytes(), (ROOT / "relay/quietdesk-relay.sh").read_bytes())
        self.assertTrue(os.access(self.directory / "quietdesk-relay.sh", os.X_OK))
        settings = (self.directory / ".env").read_text()
        self.assertIn("QUIETDESK_RELAY_PORT=7443\n", settings)
        self.assertIn("QUIETDESK_RELAY_PUBLIC_ADDRESS=198.51.100.7\n", settings)
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.directory / ".env").stat().st_mode), 0o600)
        self.assertNotIn(KEY, (self.directory / ".env").read_text())

    def test_explicit_ipv6_and_port_skip_detection(self):
        output, calls = self.run_manager("install", "--ip", "2001:db8::10", "--port", "443")
        self.assertFalse(self.curl_log.exists())
        self.assertEqual(self.compose(calls, "run")[0]["arguments"][-1], "2001:db8::10")
        self.assertEqual(self.compose(calls, "up")[0]["environment"]["QUIETDESK_RELAY_PORT"], "443")
        self.assertIn("tls://[2001:db8::10]:443", output)

    def test_invalid_input_and_unsafe_environments_stop_before_any_change(self):
        cases = [
            (["install", "--ip", "198.51.100.7:7443"], {}, "IP 地址无效"),
            (["install", "--ip", "relay.example.com"], {}, "IP 地址无效"),
            (["install", "--port", "70000"], {}, "端口无效"),
            (["install"], {"FAKE_SS_BUSY": "1"}, "已被其他程序占用"),
            (["install"], {"FAKE_UID": "1000"}, "请使用 root 运行"),
            (["install"], {"FAKE_CURL_RESPONSES": "{}"}, "无法自动识别公网 IP"),
            (["upgrade"], {}, "未找到已安装的中继节点"),
            (["install", "--purge"], {}, "--purge 只能与 uninstall 一起使用"),
        ]
        for arguments, environment, message in cases:
            with self.subTest(arguments=arguments, environment=environment):
                output, calls = self.run_manager(*arguments, success=False, **environment)
                self.assertIn(message, output)
                self.assertFalse(self.compose(calls, "pull") + self.compose(calls, "run") + self.compose(calls, "up"))
                self.assertFalse(self.directory.exists())

    def test_public_ip_falls_back_to_a_public_interface_address(self):
        output, calls = self.run_manager("install", FAKE_CURL_RESPONSES="{}", FAKE_ROUTE_SOURCE="203.0.113.44")
        self.assertIn("来源：本机网卡", output)
        self.assertEqual(self.compose(calls, "run")[0]["arguments"][-1], "203.0.113.44")

    def test_reinstall_after_plain_uninstall_reuses_the_certificate_address(self):
        self.state.update(volumes=["quietdesk-relay_state", "quietdesk-relay_tls"], san="IP Address:198.51.100.7")
        output, calls = self.run_manager("install", FAKE_CURL_RESPONSES="{}")
        self.assertIn("沿用原地址 198.51.100.7", output)
        self.assertFalse(self.curl_log.exists())
        self.assertEqual(self.compose(calls, "run")[0]["arguments"][-1], "198.51.100.7")

    def test_install_over_an_existing_node_upgrades_and_keeps_port_and_identity(self):
        self.installed(port="443")
        output, calls = self.run_manager("install", "--ip", "203.0.113.9")
        self.assertIn("改为执行升级", output)
        self.assertIn("已忽略 --ip/--port", output)
        self.assertFalse(self.compose(calls, "run"))
        backup = next(call for call in calls if call["arguments"][:1] == ["run"])["arguments"]
        self.assertIn("quietdesk-relay_state:/backup-source/state:ro", backup)
        self.assertEqual(backup[backup.index("-c") - 1], "sha256:old")
        self.assertEqual(len(list((self.directory / "backups").glob("relay-*.tar.gz"))), 1)
        self.assertEqual(self.state["images"]["quietdesk-relay:previous"], "sha256:old")
        startup = self.compose(calls, "up")
        self.assertEqual([call["environment"]["QUIETDESK_RELAY_PORT"] for call in startup], ["443"])
        self.assertEqual(self.state["container"]["image"], "sha256:new")
        self.assertNotIn(KEY, output)
        self.assertIn("tls://198.51.100.7:443", output)
        self.assertIn("QUIETDESK_RELAY_PUBLIC_ADDRESS=198.51.100.7\n", (self.directory / ".env").read_text())

    def test_upgrade_without_a_new_image_does_not_restart(self):
        self.installed()
        self.state["pull"] = "sha256:old"
        output, calls = self.run_manager("upgrade")
        self.assertIn("已是最新版本", output)
        self.assertFalse(self.compose(calls, "up"))
        self.assertFalse([call for call in calls if call["arguments"][:1] in (["run"], ["tag"])])

    def test_failed_upgrade_rolls_back_to_the_previous_image(self):
        self.installed()
        self.state["fail_up_for"] = "sha256:new"
        output, calls = self.run_manager("upgrade", success=False)
        self.assertIn("已回退到升级前的版本", output)
        images = [call["environment"]["QUIETDESK_RELAY_IMAGE"] for call in self.compose(calls, "up")]
        self.assertEqual(images, ["ghcr.io/nxiaok/quietdesk-relay:latest", "quietdesk-relay:previous"])
        self.assertEqual(self.state["container"]["image"], "sha256:old")
        self.assertTrue(self.state["container"]["running"])

    def test_failed_backup_or_pull_leaves_the_running_node_untouched(self):
        for failure in ["fail_backup", "fail_pull"]:
            with self.subTest(failure=failure):
                self.installed()
                self.state[failure] = True
                _, calls = self.run_manager("upgrade", success=False)
                self.assertFalse(self.compose(calls, "up"))
                self.assertEqual(self.state["container"]["image"], "sha256:old")

    def test_info_reads_the_identity_and_flags_a_relay_without_hole_punching(self):
        self.installed(port="7443")
        self.state["health"] = {key: value for key, value in HEALTH.items() if key != "assistedLeases"}
        output, calls = self.run_manager("info")
        self.assertIn("接入码    " + KEY, output)
        self.assertIn("此版本不支持中继打洞，请运行 upgrade", output)
        self.assertFalse(self.compose(calls, "pull") + self.compose(calls, "up"))
        self.state["container"]["running"] = False
        output, _ = self.run_manager("info")
        self.assertIn("接入码    " + KEY, output)
        self.assertIn("运行状态  exited", output)

    def test_rollback_needs_a_previous_image_and_confirmation(self):
        self.installed()
        output, _ = self.run_manager("rollback", "--yes", success=False)
        self.assertIn("没有可回退的版本", output)
        self.state["images"]["quietdesk-relay:previous"] = "sha256:prior"
        self.state["revisions"]["sha256:prior"] = "1234567"
        self.run_manager("rollback", success=False)
        self.assertEqual(self.state["container"]["image"], "sha256:old")
        self.run_manager("rollback", "--yes")
        self.assertEqual(self.state["container"]["image"], "sha256:prior")

    def test_uninstall_keeps_identity_unless_purged_with_confirmation(self):
        self.installed()
        self.run_manager("install")
        output, calls = self.run_manager("uninstall", success=False)
        self.assertIn("需要确认", output)
        self.assertFalse([call for call in calls if call["arguments"][:1] == ["rm"]])
        output, calls = self.run_manager("uninstall", "--yes")
        self.assertIsNone(self.state["container"])
        self.assertEqual(self.state["volumes"], ["quietdesk-relay_state", "quietdesk-relay_tls"])
        self.assertTrue((self.directory / "backups").is_dir())
        self.assertIn("uninstall --purge", output)
        self.run_manager("uninstall", "--purge", success=False)
        self.assertTrue(self.state["volumes"])
        output, _ = self.run_manager("uninstall", "--purge", "--yes")
        self.assertEqual(self.state["volumes"], [])
        self.assertFalse(self.directory.exists())

    def test_purge_never_deletes_a_directory_it_did_not_create(self):
        self.installed()
        self.directory.mkdir(parents=True)
        (self.directory / "keep.txt").write_text("user data")
        output, _ = self.run_manager("uninstall", "--purge", "--yes")
        self.assertIn("不是本脚本创建的部署目录", output)
        self.assertTrue((self.directory / "keep.txt").exists())

    def test_piped_script_downloads_matching_files_and_keeps_a_copy(self):
        raw = "https://raw.githubusercontent.com/nXiaoK/QuietDesk/main/relay/"
        responses = {"https://ifconfig.me/ip": "198.51.100.7\n",
                     raw + "compose.image.yaml": "file:" + str(ROOT / "relay/compose.image.yaml"),
                     raw + "quietdesk-relay.sh": "file:" + str(ROOT / "relay/quietdesk-relay.sh")}
        self.run_manager("install", stdin=(ROOT / "relay/quietdesk-relay.sh").read_text(),
                         FAKE_CURL_RESPONSES=json.dumps(responses))
        self.assertEqual((self.directory / "compose.image.yaml").read_bytes(), (ROOT / "relay/compose.image.yaml").read_bytes())
        self.assertEqual((self.directory / "quietdesk-relay.sh").read_bytes(), (ROOT / "relay/quietdesk-relay.sh").read_bytes())
        # The installed copy refreshes the deployment file and keeps its own file in place on upgrade.
        self.state["pull"] = "sha256:newer"
        self.state["revisions"]["sha256:newer"] = "abcdef0"
        output, calls = self.run_manager("upgrade", script=self.directory / "quietdesk-relay.sh",
                                         FAKE_CURL_RESPONSES=json.dumps(responses))
        self.assertIn("升级完成", output)
        self.assertTrue((self.directory / "quietdesk-relay.sh").exists())
        self.assertIn(raw + "compose.image.yaml", self.curl_log.read_text())

    def test_rootless_docker_warns_that_hole_punching_may_fail(self):
        self.state["security"] = ["name=seccomp", "name=rootless"]
        output, _ = self.run_manager("install")
        self.assertIn("rootless", output)


if __name__ == "__main__":
    unittest.main()
