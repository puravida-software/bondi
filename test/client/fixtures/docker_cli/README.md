# docker CLI captures

Verbatim output of the docker CLI commands `bondi setup` runs over SSH, taken
on 2026-11-21 against a local engine: docker CLI 29.8.0 (API 1.56), Docker
Engine - Community 29.10.0 (API 1.57), containerd v2.4.2, with the containerd
image store (`driver-type io.containerd.snapshotter.v1`). Each file holds one
stream byte for byte; do not edit them by hand. The whole set was recorded in
one session, with the exact subcommands Bondi runs (`docker container inspect`
for a container, `docker image inspect` for an image).

The registry was `registry:2.8.3` on `127.0.0.1:45123`. The image
`localhost:45123/obsimg:t` was first busybox 1.37.0, then the tag was pushed
again with a different image and pulled. Port 45124 had nothing listening.
`obs-lab` carried `--label bondi.spec-hash=abc123`; the other containers carried
no label.

| File | Command | Exit |
|------|---------|------|
| `ps_labelled_running.out` | `docker ps -a --filter name=^/obs-lab$ --format '{{.State}}\t{{.Image}}\t{{.Label "bondi.spec-hash"}}'` | 0 |
| `ps_unlabelled_running.out` | the same, for `obs-nolab` | 0 |
| `ps_unlabelled_created.out` | the same, for `obs-created` (created, never started) | 0 |
| `ps_labelled_after_tag_moved.out` | the same, for `obs-lab`, after a pull moved its tag to a new image | 0 |
| `ps_unlabelled_after_tag_moved.out` | the same, for `obs-nolab`, after the same pull | 0 |
| `inspect_container_image.out` | `docker container inspect -f '{{.Image}}' obs-lab` (unchanged by the tag move) | 0 |
| `image_inspect_id_before_tag_moved.out` | `docker image inspect -f '{{.Id}}' localhost:45123/obsimg:t` | 0 |
| `image_inspect_id_after_tag_moved.out` | the same, after the pull moved the tag | 0 |
| `pull_up_to_date.out` | `docker pull localhost:45123/obsimg:t`, the tag unchanged in the registry (stdout; stderr empty) | 0 |
| `pull_newer_image.out` | the same, after the tag was pushed with a new image (stdout; stderr empty) | 0 |
| `pull_unknown_tag.err` | `docker pull localhost:45123/obsimg:nope` (stderr; stdout empty) | 1 |
| `pull_registry_unreachable.err` | `docker pull localhost:45124/obsimg:t` (stderr; stdout empty) | 1 |
| `inspect_absent_container.err` | `docker container inspect -f '{{.Image}}' obs-nothing` (stderr; stdout one newline) | 1 |
| `image_inspect_absent_reference.err` | `docker image inspect -f '{{.Id}}' localhost:45123/obsimg:nope` (stderr; stdout one newline) | 1 |

A `ps` for a name no container has prints nothing and exits 0. No file holds it.

What the captures show:
- `{{.Image}}` in `ps` is the reference the container was created from only
  while that reference still names the container's image. After a pull moves
  the tag, it is the container's image id cut to 12 hex digits, with no
  `sha256:` prefix.
- `{{.Label "bondi.spec-hash"}}` prints the value, or nothing at all when the
  label is absent. The tab before it is still printed.
- `docker container inspect -f '{{.Image}}'` and `docker image inspect -f '{{.Id}}'`
  print the full `sha256:` id. The two are equal until the tag moves.
