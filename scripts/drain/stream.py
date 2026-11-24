"""An open-loop stream of GET requests through Traefik, for the swap arm.

Usage: stream.py URL HOST RATE TIMEOUT

One request is started every 1/RATE seconds, each on its own thread, so a
request that hangs never delays the next. A request fails on a status other
than 2xx, on an error, or when no answer has come within TIMEOUT seconds;
TIMEOUT is that failure criterion and asserts nothing about latency. On
SIGTERM it starts no more requests, waits for those in flight, which each end
within TIMEOUT, and prints one line per request, in the order they started:

    <started> <status, 0 when none came> <body, or the error's name> <seconds>

The body of a 2xx answer from the drain workload is the hostname of the
container that answered, which is its short id.
"""

import signal
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request

url, host, rate, timeout = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
# Traefik serves the gate's hosts with its default certificate.
context = ssl._create_unverified_context()
rows = []
rows_lock = threading.Lock()
stopping = threading.Event()


def one():
    started = time.time()
    try:
        request = urllib.request.Request(url, headers={"Host": host})
        with urllib.request.urlopen(request, timeout=timeout, context=context) as answer:
            code, body = answer.status, answer.read().decode().strip()
    except urllib.error.HTTPError as e:
        code, body = e.code, f"http-{e.code}"
    except Exception as e:  # every other outcome is a failed request, by its name
        code, body = 0, type(e).__name__
    with rows_lock:
        rows.append((started, code, body.replace(" ", "_")[:40] or "-", time.time() - started))


# Installed before the first request thread starts, for the reason the drain
# workload installs its own first: this process is its container's init.
signal.signal(signal.SIGTERM, lambda *_: stopping.set())
threads = []
began = time.time()
sent = 0
while not stopping.is_set():
    thread = threading.Thread(target=one)
    thread.start()
    threads.append(thread)
    sent += 1
    stopping.wait(max(0.0, began + sent / rate - time.time()))
for thread in threads:
    thread.join()
for row in sorted(rows):
    print(f"{row[0]:.3f} {row[1]} {row[2]} {row[3]:.3f}", flush=True)
