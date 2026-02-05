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
# Otherwise, install normally (for local builds or if export failed)
RUN --mount=type=cache,target=/home/opam/.opam/download-cache,uid=1000,gid=1000 \
    eval $(opam env) && \
    if [ -f .opam-switch-export ] && [ -s .opam-switch-export ]; then \
        echo "Importing opam switch from CI to reuse installed packages..." && \
        opam switch import .opam-switch-export --yes && \
        echo "Successfully imported opam switch from CI" || \
        (echo "Switch import failed, falling back to normal install" && \
         opam update && \
         opam install -y --deps-only -t . -j 4); \
    else \
        echo "No valid opam switch export found, installing normally..." && \
        opam update && \
        opam install -y --deps-only -t . -j 4; \
    fi && \
    eval $(opam env)

# Copy source code
COPY --chown=opam:opam . .

# Build the application with version available as build-time environment variable
# The version will be baked into the binary at build time (not available at runtime)
ENV VERSION=$VERSION
RUN opam exec -- dune build --profile release bin/server/main.exe

# Final stage - minimal runtime image
FROM alpine:latest

# Install minimal runtime dependencies needed for the OCaml binary
RUN apk add --no-cache \
    gmp \
    libev \
    openssl \
    pcre \
    ca-certificates

# Copy the binary from the build stage and set permissions in one layer
COPY --from=builder --chmod=755 /build/_build/default/bin/server/main.exe /usr/local/bin/bondi-server

# Set user to non-root for security
RUN addgroup -g 1000 appuser && \
    adduser -D -u 1000 -G appuser appuser
USER appuser

# Set VERSION environment variable from build arg (build-time only, but available at runtime)
ARG VERSION
ENV VERSION=$VERSION

# Run the application
ENTRYPOINT ["/usr/local/bin/bondi-server"]

