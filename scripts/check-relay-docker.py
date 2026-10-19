#!/usr/bin/env python3
"""Exercise Docker deployment with isolated volumes and temporary TLS credentials."""

import base64
from contextlib import ExitStack
import hmac
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import struct
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
DEVICE = "672d6104-a890-4c4c-8862-c8f28f55953a"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def receive(connection, count):
    data = bytearray()
    while len(data) < count:
        part = connection.recv(count - len(data))
        if not part:
            raise RuntimeError("Unexpected relay EOF")
        data.extend(part)
    return bytes(data)


def read_message(connection, operation):
    size = struct.unpack("!I", receive(connection, 4))[0]
    require(0 < size <= 8192, "Invalid relay frame size")
    message = json.loads(receive(connection, size))
    require(message.get("op") == operation, "Unexpected relay operation")
    return message


def main():
    automatic = "--self-signed" in sys.argv
    subprocess.run(["docker", "info"], check=True, stdout=subprocess.DEVNULL)
    (ROOT / "work").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="relay-docker-checks-", dir=ROOT / "work") as temporary:
        directory = Path(temporary)
        certificate, key = directory / "fullchain.pem", directory / "privkey.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
                        "-keyout", str(key), "-out", str(certificate)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        key.chmod(0o600)
        with socket.socket() as candidate, socket.socket(type=socket.SOCK_DGRAM) as udp:
            candidate.bind(("127.0.0.1", 0))
            port = candidate.getsockname()[1]
            udp.bind(("127.0.0.1", port))
        project = "qdr-check-" + secrets.token_hex(6)
        environment = {**os.environ, "COMPOSE_PROJECT_NAME": project, "QUIETDESK_RELAY_PORT": str(port),
                       "QUIETDESK_RELAY_IMAGE": project + ":test"}

        def compose(*arguments, **options):
            return subprocess.run(["docker", "compose", "-f", str(ROOT / "relay/compose.yaml"), *arguments],
                                  env=environment, check=True, text=True, capture_output=True, timeout=180, **options).stdout

        def deploy(success=True, manual=False, ip="127.0.0.1"):
            arguments = ["--ip", ip] if automatic and not manual else [str(certificate), str(key)]
            result = subprocess.run(["sh", str(ROOT / "relay/deploy.sh"), *arguments],
                                    env=environment, text=True, capture_output=True, timeout=600)
            if (result.returncode == 0) != success:
                raise RuntimeError("Unexpected deployment result:\n" + result.stdout[-4000:] + result.stderr[-4000:])

        try:
            deploy()
            if automatic:
                certificate.write_text(compose("exec", "-T", "relay", "openssl", "x509", "-in", "/etc/quietdesk-relay/fullchain.pem", "-outform", "PEM"))
            original_certificate = certificate.read_bytes()
            require(compose("exec", "-T", "relay", "id", "-u").strip() == "65532", "Relay runs as root")
            access = compose("exec", "-T", "relay", "cat", "/var/lib/quietdesk-relay/access.key").strip()
            require(len(bytes.fromhex(access)) == 32, "Invalid generated access key")
            require(compose("exec", "-T", "relay", "stat", "-c", "%a:%u:%h", "/var/lib/quietdesk-relay/access.key").strip()
                    == "600:65532:1", "Access key permissions or ownership are unsafe")
            require(compose("exec", "-T", "relay", "stat", "-c", "%a:%u", "/var/lib/quietdesk-relay").strip()
                    == "700:65532", "State directory permissions or ownership are unsafe")
            container = compose("ps", "-q", "relay").strip()
            inspect = json.loads(subprocess.check_output(["docker", "inspect", container], text=True))[0]
            require(inspect["HostConfig"]["ReadonlyRootfs"], "Root filesystem is writable")
            require(set(inspect["HostConfig"]["PortBindings"]) == {"7443/tcp", "7443/udp"}, "Unexpected published ports")
            context = ssl.create_default_context(cafile=str(certificate))
            owner = base64.b64encode(secrets.token_bytes(32)).decode()

            def connect(stack, operation, **fields):
                raw = stack.enter_context(socket.create_connection(("127.0.0.1", port), timeout=5))
                connection = stack.enter_context(context.wrap_socket(raw, server_hostname="127.0.0.1" if automatic else "localhost"))
                data = json.dumps({"version": 1, "op": operation, "deviceID": DEVICE,
                                   "accessKey": base64.b64encode(bytes.fromhex(access)).decode(), **fields}).encode()
                connection.sendall(struct.pack("!I", len(data)) + data)
                return connection

            with ExitStack() as stack:
                wrong = connect(stack, "connect", accessKey=base64.b64encode(secrets.token_bytes(32)).decode())
                require(read_message(wrong, "error").get("error") == "unauthorized", "Bad credentials accepted")
                host = connect(stack, "register", ownerKey=owner)
                registration = read_message(host, "registered")["registration"]
                viewer = connect(stack, "connect")
                circuit = read_message(host, "incoming")["circuitID"]
                accepted = connect(stack, "accept", circuitID=circuit, registration=registration)
                read_message(viewer, "ready")
                read_message(accepted, "ready")
                for sender, receiver in [(viewer, accepted), (accepted, viewer)]:
                    payload = secrets.token_bytes(4096)
                    sender.sendall(payload)
                    require(receive(receiver, len(payload)) == payload, "Reliable forwarding changed bytes")

                lease = connect(stack, "datagram")
                host_route = read_message(host, "incomingDatagram")
                host_udp = stack.enter_context(socket.socket(type=socket.SOCK_DGRAM))
                viewer_udp = stack.enter_context(socket.socket(type=socket.SOCK_DGRAM))
                for connection in [host_udp, viewer_udp]:
                    connection.settimeout(5)
                    connection.connect(("127.0.0.1", port))

                def packet(route, side, sequence, payload=b""):
                    data = struct.pack("!4sBBQ16sH", b"QDR1", side, 0, sequence,
                                       base64.b64decode(route["datagramID"]), len(payload)) + payload
                    return data + hmac.digest(base64.b64decode(route["datagramKey"]), data, "sha256")

                host_udp.send(packet(host_route, 1, 1))
                viewer_route = read_message(lease, "datagramReady")
                viewer_udp.send(packet(viewer_route, 0, 1))
                # Forward viewer -> host first, so the viewer endpoint is known before the reverse path.
                for sender, receiver, route, destination, side in [
                    (viewer_udp, host_udp, viewer_route, host_route, 0),
                    (host_udp, viewer_udp, host_route, viewer_route, 1),
                ]:
                    payload = secrets.token_bytes(512)
                    sender.send(packet(route, side, 2, payload))
                    forwarded = receiver.recv(2048)
                    require(forwarded[5] == 1 and forwarded[32:-32] == payload, "UDP forwarding failed")
                    require(hmac.compare_digest(forwarded[-32:], hmac.digest(base64.b64decode(destination["datagramKey"]),
                                                                            forwarded[:-32], "sha256")),
                            "Forwarded UDP authentication failed")

            state = compose("exec", "-T", "relay", "cat", "/var/lib/quietdesk-relay/devices.json")
            deploy()
            exported = compose("exec", "-T", "relay", "openssl", "x509", "-in", "/etc/quietdesk-relay/fullchain.pem", "-outform", "PEM")
            require(exported.encode() == original_certificate, "Redeployment replaced the node certificate")
            if automatic:
                deploy(success=False, ip="127.0.0.2")
            require(compose("exec", "-T", "relay", "cat", "/var/lib/quietdesk-relay/access.key").strip() == access,
                    "Redeployment replaced the access key")
            require(compose("exec", "-T", "relay", "cat", "/var/lib/quietdesk-relay/devices.json") == state,
                    "Redeployment changed device ownership")
            with ExitStack() as stack:
                wrong = connect(stack, "register", ownerKey=base64.b64encode(secrets.token_bytes(32)).decode())
                require(read_message(wrong, "error").get("error") == "owner_mismatch", "Device identity was lost")
                read_message(connect(stack, "register", ownerKey=owner), "registered")
            installed = compose("exec", "-T", "relay", "sha256sum", "/etc/quietdesk-relay/privkey.pem")
            subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(key)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deploy(success=False, manual=True)
            require(compose("exec", "-T", "relay", "sha256sum", "/etc/quietdesk-relay/privkey.pem") == installed,
                    "Invalid certificate deployment replaced the installed private key")
            json.loads(compose("exec", "-T", "relay", "wget", "-qO-", "http://127.0.0.1:9091/healthz"))
            print("Docker checks passed: non-root, TLS/auth, TCP/UDP, persistent identities, invalid certificate rejection.")
        finally:
            # Only this randomly named fixture project may have its volumes removed.
            compose("--profile", "tools", "down", "--volumes", "--remove-orphans")
            subprocess.run(["docker", "image", "rm", project + ":test"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
