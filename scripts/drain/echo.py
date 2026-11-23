"""A TCP echo standing in for a database that lives off the box.

check-server-image.sh runs it off the network a deploy attaches to and
publishes its port on that network's gateway address only, so the drain
workload reaches it through the host, as a service reaches a database hosted
elsewhere, and loses it when it loses its network.
"""

import socket
import threading

PORT = 15432


def serve(connection):
    with connection:
        while data := connection.recv(64):
            connection.sendall(data)


listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("0.0.0.0", PORT))
listener.listen(64)
print(f"echo listening port={PORT}", flush=True)
while True:
    connection, _ = listener.accept()
    threading.Thread(target=serve, args=(connection,), daemon=True).start()
