"""Uploads of known length and digest through Traefik, for the upload arm.

Usage: upload.py ADDRESS HOST INTERVAL SIZE BYTES_PER_SECOND TIMEOUT ID_PREFIX

One upload is started every INTERVAL seconds, each on its own thread, to
https://ADDRESS/upload?id=<ID_PREFIX>-<n> with the given Host header. Each
sends SIZE random bytes under a Content-Length of SIZE, paced at
BYTES_PER_SECOND, so that an upload takes long enough to be in flight when the
container receiving it is stopped. A socket operation that waits more than
TIMEOUT seconds ends the upload as failed. On SIGTERM it starts no more,
waits for those in flight, and prints one line per upload, in id order:

    <id> <length sent> <sha256 sent> <status, 0 when none came> <body or error>

A status of 0 means no complete answer came: the body may or may not have
reached an application, which is what the gate reads the backend's log for.
"""

import hashlib
import http.client
import os
import signal
import ssl
import sys
import threading
import time

address, host = sys.argv[1], sys.argv[2]
interval, size = float(sys.argv[3]), int(sys.argv[4])
pace, timeout, prefix = float(sys.argv[5]), float(sys.argv[6]), sys.argv[7]
chunk_size = 8192
# Traefik serves the gate's hosts with its default certificate.
context = ssl._create_unverified_context()
rows = []
rows_lock = threading.Lock()
stopping = threading.Event()


def one(number):
    upload_id = f"{prefix}-{number}"
    body = os.urandom(size)
    digest = hashlib.sha256(body).hexdigest()
    connection = http.client.HTTPSConnection(address, 443, timeout=timeout, context=context)
    try:
        connection.putrequest("POST", f"/upload?id={upload_id}", skip_host=True)
        connection.putheader("Host", host)
        connection.putheader("Content-Length", str(size))
        connection.endheaders()
        began = time.monotonic()
        for offset in range(0, size, chunk_size):
            connection.send(body[offset:offset + chunk_size])
            time.sleep(max(0.0, began + (offset + chunk_size) / pace - time.monotonic()))
        answer = connection.getresponse()
        code, text = answer.status, answer.read().decode().strip()
    except Exception as e:  # every other outcome is a failed upload, by its name
        code, text = 0, type(e).__name__
    finally:
        connection.close()
    with rows_lock:
        rows.append((number, upload_id, digest, code, text.replace(" ", "_")[:200] or "-"))


# Installed before the first upload thread starts: this process is its
# container's init.
signal.signal(signal.SIGTERM, lambda *_: stopping.set())
threads = []
began = time.time()
started = 0
while not stopping.is_set():
    thread = threading.Thread(target=one, args=(started,))
    thread.start()
    threads.append(thread)
    started += 1
    stopping.wait(max(0.0, began + started * interval - time.time()))
for thread in threads:
    thread.join()
for row in sorted(rows):
    print(f"{row[1]} {size} {row[2]} {row[3]} {row[4]}", flush=True)
