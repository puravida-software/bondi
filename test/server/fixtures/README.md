# Captured pull streams

Both files are the raw bodies a real Docker Engine returned for
`POST /images/create`, saved byte for byte. Each line ends in `\r\n`, as the
engine wrote it. They were captured, not written, so that what reads them is
built against the stream the engine sends rather than the one its reference
documents. A capture that stops matching what an engine sends is recaptured
the same way.

Both were pulled with

    curl --unix-socket /var/run/docker.sock -X POST \
      'http://localhost/v1.47/images/create?fromImage=localhost%3A5443%2Fbondi-observe-app&tag=<tag>'

from a `registry:2` container
(`registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373`)
serving TLS on `127.0.0.1:5443`. Each image was one layer of random bytes
pushed straight to the registry over its HTTP API, so the engine had never held
that layer. An image built on the same engine is no use here: the engine keeps
the built layer after the image is removed, and a pull then reports it
`Already exists` and succeeds without fetching it.

## `pull_stream_missing_layer.ndjson`

[observed -- 2026-11-19T18:48:51Z, Docker Engine 29.10.0, API 1.57, containerd
image store] The image's layer blob was deleted from the registry's storage
and the registry restarted. Before the restart the registry's blob cache still
answered `200` for the deleted blob; after it, `404 BLOB_UNKNOWN`. The pull's
HTTP status was `200 OK`. The failure is only in the body: its last line
carries `error` and `errorDetail` (with `code` 404), and no image was left on
the engine.

## `pull_stream_success.ndjson`

[observed -- 2026-11-19T18:48:56Z, Docker Engine 29.10.0, API 1.57, containerd
image store] The same registry, an image whose layer was intact. HTTP status
`200 OK`, no `error` line, and the image was on the engine afterwards under the
digest the stream's `Digest:` line names.

## `pull_stream_up_to_date.ndjson`

[observed -- 2026-11-21, Docker Engine 29.10.0, API 1.57] A pull of `alpine:3.21`,
which the engine already held, from the public registry via
`/v1.47/images/create?fromImage=alpine&tag=3.21`. HTTP `200`; it ends
`Status: Image is up to date for alpine:3.21`.

## Identifiers

Every string value in both bodies was scanned for account numbers, user names,
host names, emails and tokens. None is present. The long hex strings are the
content digests of the layers and manifests made for the capture.
