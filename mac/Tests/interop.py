"""Exercise the Mac transport with an independent OpenSSL TLS 1.2 client."""
import os
import pathlib
import queue
import socket
import ssl
import subprocess
import sys
import threading
import time


def exercise(fixture, ipv6):
    secret = os.urandom(16)
    host = "::1" if ipv6 else "127.0.0.1"
    child = subprocess.Popen([fixture] + (["--ipv6"] if ipv6 else []),
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    messages = queue.Queue()

    def read():
        for line in child.stdout:
            messages.put(line.decode().strip())
        messages.put("EOF")

    threading.Thread(target=read, daemon=True).start()

    def expect(value):
        actual = messages.get(timeout=10)
        assert actual == value, (value, actual)

    try:
        child.stdin.write(secret)
        child.stdin.close()
        port_line = messages.get(timeout=10).split()
        assert port_line[0] == "PORT", port_line
        port = int(port_line[1])

        def connect(key, identity="airplay-input-v1"):
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_2
            context.set_ciphers("PSK-AES128-GCM-SHA256")
            context.set_psk_client_callback(lambda hint: (identity, key))
            return context.wrap_socket(socket.create_connection((host, port), timeout=8))

        for key, identity in [(os.urandom(16), "airplay-input-v1"), (secret, "unknown-identity")]:
            try:
                with connect(key, identity) as conn:
                    assert conn.recv(1) == b"", "unauthenticated connection received ready"
            except (ssl.SSLError, ConnectionResetError):
                pass
            expect("END")

        # A held key is released on malformed input, EOF and heartbeat expiry.
        for reason in ["malformed", "eof", "timeout"]:
            with connect(secret) as conn:
                assert conn.cipher()[0] == "PSK-AES128-GCM-SHA256"
                assert conn.recv(1) == b"\x01"
                frame = bytes([4, 4, 1, 0, 0, 0, 0, 0])
                conn.sendall(frame[:3])
                time.sleep(0.05)
                assert messages.empty()
                conn.sendall(frame[3:] + bytes(8))
                expect("DOWN")
                if reason == "malformed":
                    conn.sendall(bytes([255]) + bytes(7))
                elif reason == "eof":
                    conn.close()
                else:
                    conn.sendall(frame[:7])
                expect("UP")
                expect("END")
        print(f"PASS {host} TLS 1.2 PSK, identity, ready, framing, release and reconnect")
    finally:
        child.terminate()
        child.wait(timeout=5)


if __name__ == "__main__":
    if not getattr(ssl, "HAS_PSK", False):
        sys.exit("Use Python 3.13 or newer with OpenSSL PSK support to run this test.")
    for v6 in (False, True):
        exercise(str(pathlib.Path(sys.argv[1]).resolve()), v6)
