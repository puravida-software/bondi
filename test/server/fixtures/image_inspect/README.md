# Captured image inspect responses

Each file is the raw body a real Docker Engine returned for
`GET /images/{name}/json`, saved byte for byte. They were captured, not
written, so that what decodes them is built against the response the engine
sends rather than the one its reference documents. A capture that stops
matching what an engine sends is recaptured the same way.

Every image was built with BuildKit (the engine's default builder, BuildKit
v0.35.0) from `alpine:3.24`, tagged `bondi-observe-<kind>:1`, and captured
twice:

    curl --unix-socket /var/run/docker.sock \
      'http://localhost/<version>/images/bondi-observe-<kind>:1/json'

- at `v1.41`, the version `Docker.Client.negotiate` picks on this engine: it
  prefers `v1.41`, and the engine reports a window of 1.40 to 1.57;
- at `v1.45`, the first version that no longer sends `ContainerConfig`.

[observed -- 2026-11-22T17:08:03Z, Docker Engine 29.10.0, API 1.57 (minimum
1.40), docker CLI 29.8.0, containerd image store (`overlayfs`,
`io.containerd.snapshotter.v1`)]

## What `ContainerConfig` holds

At `v1.41` every capture carries the `ContainerConfig` key, but its value is
`null`, for the image with a `HEALTHCHECK` as much as for the others. An image
BuildKit built states its health check only in `Config.Healthcheck`. A decoder
reading `ContainerConfig.Healthcheck` therefore finds no health check for any
of these images at either version. At `v1.45` the key is absent, as are
`Container` and `VirtualSize`.

## The files

| File | Built from | `Config.Healthcheck` | `Config.Labels` |
|---|---|---|---|
| `healthcheck_cmd.v1.41.json`, `healthcheck_cmd.v1.45.json` | `HEALTHCHECK --interval=5s --timeout=2s CMD ["true"]` | `{"Interval":5000000000,"Test":["CMD","true"],"Timeout":2000000000}` | `null` |
| `no_healthcheck.v1.41.json`, `no_healthcheck.v1.45.json` | no `HEALTHCHECK` instruction | key absent | `null` |
| `healthcheck_none.v1.41.json`, `healthcheck_none.v1.45.json` | `HEALTHCHECK NONE` | `{"Test":["NONE"]}` | `null` |
| `router_middlewares_label.v1.41.json`, `router_middlewares_label.v1.45.json` | `LABEL traefik.http.routers.obsapp.middlewares=image-declared@docker` | key absent | `{"traefik.http.routers.obsapp.middlewares":"image-declared@docker"}` |

The two versions of each image agree on `Config` exactly (compared with
`jq -S .Config`).

## The label image

[observed -- 2026-11-22T17:08:26Z, the same engine] A container created from
`router_middlewares_label`'s image through `POST /v1.41/containers/create`,
with Bondi's service labels plus
`traefik.http.routers.obsapp.middlewares=obsapp-retry`, carries `obsapp-retry`
under that key: a label set at create replaces the image's label of the same
key. The same image created with no labels carries the image's
`image-declared@docker`.

## Identifiers

Every string value in every capture was scanned for account numbers, user
names, registry hosts, emails and tokens. None is present. The images were
tagged locally and never pushed, so `RepoTags` and `RepoDigests` name no
registry. The long hex strings are the content digests of the images and the
base layer. The only label is the one the label image was built to carry.

## The empty-config image

[observed -- 2026-11-22T23:39Z, Docker Engine 29.10.0, API 1.57] An empty tar
archive imported with `docker import` and tagged `bondi-observe-empty:1`
(removed after capture), saved as `empty_config.v1.41.json` and
`empty_config.v1.45.json`. `Config` is an object at both versions with no
`Healthcheck` and `Labels` null; it is neither null nor absent. `ContainerConfig`
is null at `v1.41` and absent at `v1.45`.
