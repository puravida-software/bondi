"""The drain workload: a service whose shutdown needs its network.

check-server-image.sh builds it into the image its swap and upload arms deploy
blue-green. It stands in for a service that, once sent SIGTERM, still has work
to do over the network: it closes its listener, lets the requests it holds
finish, and then makes a DNS lookup and a round trip to its database, which
lives off the network a deploy attaches to.

- GET /           200, and the body is the container's hostname, which the
                  engine sets to its short id
- GET /health     200
- GET /slow?s=N   held until the process is sent SIGTERM, then N seconds more,
                  with a database round trip before the hold and one after it.
                  The reply names the hostname and both results.
- POST /upload?id=X  reads the body the Content-Length announces and logs one
                  `upload` line naming the id, the length read, its sha256 and
                  whether the body was complete. Only a complete body is
                  answered 2xx, and the answer repeats the line's fields.

Every line logged names its event first and its fields as key=value, so the
gate joins a client's request to this log by its id, never by order.

On SIGTERM it closes its listener, waits up to GRACE seconds for the requests
in flight, logs the DNS lookup and the database round trip, then exits 0.
"""

import hashlib
import os
import signal
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("PORT", "8080"))
DB_HOST = os.environ.get("DB_HOST", "")
DB_PORT = int(os.environ.get("DB_PORT", "0"))
DNS_NAME = os.environ.get("DNS_NAME", "")
GRACE = float(os.environ.get("GRACE", "5"))
# The longest a /slow request waits for SIGTERM, so one sent to a container
# that is never stopped still ends.
SLOW_CAP = 120.0
HOST = socket.gethostname()

stopping = threading.Event()
# The count of requests being handled, written by the handler threads under
# `lock` and read by the shutdown, which waits for it to reach zero.
in_flight = 0
lock = threading.Lock()


def log(event, **fields):
    rendered = " ".join(f"{k}={v}" for k, v in fields.items())
    print(f"{time.time():.3f} {event} host={HOST} {rendered}".rstrip(), flush=True)


def db_roundtrip(timeout=3.0):
    started = time.monotonic()
    try:
        with socket.create_connection((DB_HOST, DB_PORT), timeout=timeout) as s:
            s.sendall(b"ping\n")
            if s.recv(16) != b"ping\n":
                return f"FAIL:echo-mismatch:{time.monotonic() - started:.3f}s"
        return f"ok:{time.monotonic() - started:.3f}s"
    except OSError as e:
        return f"FAIL:{type(e).__name__}:{time.monotonic() - started:.3f}s"


def dns_lookup():
    started = time.monotonic()
    try:
        socket.getaddrinfo(DNS_NAME, None)
        return f"ok:{time.monotonic() - started:.3f}s"
    except OSError as e:
        return f"FAIL:{type(e).__name__}:{time.monotonic() - started:.3f}s"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, code, body):
        encoded = body.encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(encoded)))
        if stopping.is_set():
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        self.wfile.write(encoded)

    def counted(self, work):
        global in_flight
        with lock:
            in_flight += 1
        try:
            work()
        finally:
            with lock:
                in_flight -= 1

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/health":
            return self.reply(200, "health\n")
        if url.path == "/slow":
            return self.counted(lambda: self.slow(url))
        return self.counted(lambda: self.reply(200, f"{HOST}\n"))

    def slow(self, url):
        after = float(parse_qs(url.query).get("s", ["2"])[0])
        before = db_roundtrip()
        log("slow-start", db_before=before)
        released = stopping.wait(SLOW_CAP)
        time.sleep(after)
        later = db_roundtrip()
        log("slow-done", released_by_sigterm=released, db_after=later)
        self.reply(200, f"{HOST} slow db_before={before} db_after={later}\n")

    def do_POST(self):
        url = urlparse(self.path)
        if url.path != "/upload":
            return self.reply(404, "not found\n")
        return self.counted(lambda: self.upload(url))

    def upload(self, url):
        upload_id = parse_qs(url.query).get("id", ["-"])[0]
        expected = int(self.headers.get("Content-Length", "0"))
        log("upload-start", id=upload_id, announced=expected)
        digest = hashlib.sha256()
        received = 0
        try:
            while received < expected:
                chunk = self.rfile.read(min(65536, expected - received))
                if not chunk:
                    break
                digest.update(chunk)
                received += len(chunk)
        except OSError:
            pass
        complete = received == expected
        fields = f"id={upload_id} length={received} sha256={digest.hexdigest()}"
        log("upload", id=upload_id, length=received,
            sha256=digest.hexdigest(), complete=complete)
        if complete:
            self.reply(200, f"{HOST} {fields}\n")
        else:
            self.close_connection = True


# The disposition is installed before the server thread starts, so a SIGTERM
# that arrives as the process comes up is not dropped: the kernel discards a
# default-action signal sent to a PID namespace's init.
signal.signal(signal.SIGTERM, lambda *_: stopping.set())
server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
log("listening", port=PORT)
stopping.wait()
began = time.monotonic()
log("sigterm", note="closing-listener")
server.shutdown()
server.server_close()
deadline = time.monotonic() + GRACE
while time.monotonic() < deadline:
    with lock:
        if in_flight == 0:
            break
    time.sleep(0.05)
with lock:
    left = in_flight
log("drained", in_flight_left=left, after=f"{time.monotonic() - began:.3f}s")
log("shutdown-dns", name=DNS_NAME, result=dns_lookup())
log("shutdown-db", result=db_roundtrip())
log("stopping", after=f"{time.monotonic() - began:.3f}s")
sys.exit(0)
