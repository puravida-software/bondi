# Build stage
FROM ocaml/opam:alpine-ocaml-5.3 AS builder

# Set build argument for version (build-time only, not available at runtime)
ARG VERSION
# Validate that VERSION is provided
RUN if [ -z "$VERSION" ]; then echo "Error: VERSION build argument is required. Use: docker build --build-arg VERSION=x.y.z ." && exit 1; fi

# Set working directory
WORKDIR /build

# Install system dependencies for building
USER root
RUN apk add --no-cache \
    linux-headers \
    gmp-dev \
    libev-dev \
    openssl-dev \
    pcre-dev \
    musl-dev \
    m4 \
    make

# Switch back to opam user
USER opam

# Copy dependency files first for better layer caching
COPY --chown=opam:opam dune-project bondi.opam ./

# Copy opam switch export from CI (if available) to reuse installed packages
# This avoids re-downloading and re-building packages that were already installed in CI
# The file is always created in CI (even if empty), so COPY won't fail
COPY --chown=opam:opam .opam-switch-export* ./

# Install OCaml dependencies with BuildKit cache mounts for opam caches
# Cache mounts:
# - /home/opam/.opam/download-cache: Global package download cache
# Note: We don't cache /home/opam/.opam/repo as it can interfere with opam's
# repository configuration when the cache is empty. The download cache is sufficient
# for speeding up package downloads.
# If .opam-switch-export exists and is valid, import it to reuse packages from CI
# Otherwise, install normally (for local builds or if export failed).
# The base image bundles a frozen opam-repository mirror, so the default remote is
# re-pointed at upstream and refreshed before installing — otherwise recently
# published dependency versions (e.g. tls-eio 2.1.1) cannot be resolved.
RUN --mount=type=cache,target=/home/opam/.opam/download-cache,uid=1000,gid=1000 \
    eval $(opam env) && \
    opam repository set-url default git+https://github.com/ocaml/opam-repository.git && \
    opam update && \
    if [ -f .opam-switch-export ] && [ -s .opam-switch-export ]; then \
        echo "Importing opam switch from CI to reuse installed packages..." && \
        opam switch import .opam-switch-export --yes && \
        echo "Successfully imported opam switch from CI" || \
        (echo "Switch import failed, falling back to normal install" && \
         opam install -y --deps-only -t . -j 4); \
    else \
        echo "No valid opam switch export found, installing normally..." && \
        opam install -y --deps-only -t . -j 4; \
    fi && \
    eval $(opam env)

# Copy source code
COPY --chown=opam:opam . .

# Build the application with version available as build-time environment variable
# The version will be baked into the binary at build time (not available at runtime)
ENV VERSION=$VERSION
RUN opam exec -- dune build --profile release bin/server/main.exe

# Collect the binary's own shared-library closure so the runtime stage carries
# exactly what it links. A hand-written apk list cannot do this: it is not
# derived from anything, so it silently goes stale the moment a dependency
# starts linking something new, and the first symptom is the musl loader
# aborting before main with exit 127 on a production host.
#
# ldd resolves transitively, so this is the whole closure, not just the direct
# NEEDED entries. The musl loader itself is excluded: it is libc, every Alpine
# image already has one, and overwriting the runtime stage's copy with the
# builder's would break the rest of that image.
USER root
RUN set -eu; \
    binary=/build/_build/default/bin/server/main.exe; \
    mkdir -p /runtime-libs; \
    if ! ldd "$binary" > /tmp/ldd.txt 2>&1; then \
        echo "error: the built binary has unresolved shared libraries:"; \
        cat /tmp/ldd.txt; \
        exit 1; \
    fi; \
    awk '{ for (i = 1; i <= NF; i++) if ($i == "=>") print $(i + 1) }' /tmp/ldd.txt \
        | grep -v 'ld-musl' \
        | sort -u \
        | while IFS= read -r lib; do cp -L "$lib" /runtime-libs/; done; \
    echo "runtime closure:"; ls -1 /runtime-libs

# Final stage - minimal runtime image
FROM alpine:latest

# ca-certificates is a trust store, not a linkage: no amount of scanning the
# binary can discover it, and outbound TLS to alert sinks needs it.
RUN apk add --no-cache ca-certificates

# The runtime closure derived from the binary above, rather than a package list
# maintained by hand alongside it.
COPY --from=builder /runtime-libs/ /usr/lib/

# Copy the binary from the build stage and set permissions in one layer
COPY --from=builder --chmod=755 /build/_build/default/bin/server/main.exe /usr/local/bin/bondi-server

# Fail the build rather than the deployment. An unresolved shared library stops
# the musl loader before main, which `docker run -d` still reports as success,
# so nothing downstream of here would notice. ldd exits 127 in that case — the
# same 127 the failure presents as on a server.
RUN set -eu; \
    if ! ldd /usr/local/bin/bondi-server > /tmp/ldd.txt 2>&1 \
       || grep -qE 'not found|Error loading|Error relocating' /tmp/ldd.txt; then \
        echo "error: unresolved shared libraries in the runtime image:"; \
        cat /tmp/ldd.txt; \
        exit 1; \
    fi; \
    cat /tmp/ldd.txt; \
    rm -f /tmp/ldd.txt

# Set user to non-root for security
RUN addgroup -g 1000 appuser && \
    adduser -D -u 1000 -G appuser appuser
USER appuser

# Set VERSION environment variable from build arg (build-time only, but available at runtime)
ARG VERSION
ENV VERSION=$VERSION

# Run the application
ENTRYPOINT ["/usr/local/bin/bondi-server"]

