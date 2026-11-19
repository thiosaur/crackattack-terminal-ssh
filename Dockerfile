# syntax=docker/dockerfile:1
#
# Crack Attack! (terminal version) behind an ssh login: connecting starts the game, nothing else.
#
# The game comes from the Crack Attack! release (BINARY_FROM=release, the default): the archive
# is downloaded from GitHub and checked against the checksum pinned in .env.
# BINARY_FROM=source builds it instead from a checkout, passed as the named build context
# `crackattack-src` (test/smoke.sh does this, to try a change before it is released).
#
# The game is the static build (musl): it needs no system library, so the image does not
# depend on the base's libc.

ARG BINARY_FROM=release

# ---- the game, from a release archive ---------------------------------------------------
FROM debian:13-slim AS fetch
ARG CRACKATTACK_VERSION
ARG CRACKATTACK_ARCHIVE=linux-x86_64-static
ARG CRACKATTACK_SHA256
RUN test -n "$CRACKATTACK_SHA256" \
    || { echo "CRACKATTACK_SHA256 is empty: pin a release with tools/bump.sh <version>" >&2; exit 1; }
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
RUN set -eu; \
    name="crackattack-terminal-${CRACKATTACK_VERSION}-${CRACKATTACK_ARCHIVE}"; \
    curl -fsSL -o archive.tar.gz \
        "https://github.com/thiosaur/crackattack/releases/download/v${CRACKATTACK_VERSION}/${name}.tar.gz"; \
    echo "${CRACKATTACK_SHA256}  archive.tar.gz" | sha256sum -c -; \
    tar -xzf archive.tar.gz; \
    mv "$name" /pkg

# ---- the game, built from a checkout -----------------------------------------------------
FROM rust:1.94-trixie AS build
RUN apt-get update && apt-get install -y --no-install-recommends musl-tools \
    && rm -rf /var/lib/apt/lists/*
COPY --from=crackattack-src . /src
WORKDIR /src
RUN rustup target add x86_64-unknown-linux-musl \
    && cargo build --release --locked -p crackattack-terminal --target x86_64-unknown-linux-musl \
    && mkdir /pkg \
    && cp target/x86_64-unknown-linux-musl/release/crackattack-terminal tools/release/overlay/LICENSE tools/release/overlay/AUTHORS /pkg/

FROM fetch AS binary-release
FROM build AS binary-source
FROM binary-${BINARY_FROM} AS binary

# ---- the image ----------------------------------------------------------------------------
FROM debian:13-slim
ARG CRACKATTACK_VERSION=unknown
LABEL org.opencontainers.image.title="Crack Attack! terminal over ssh" \
      org.opencontainers.image.version="${CRACKATTACK_VERSION}" \
      org.opencontainers.image.source="https://github.com/thiosaur/crackattack-terminal-ssh" \
      org.opencontainers.image.description="The terminal version of Crack Attack! (https://github.com/thiosaur/crackattack) behind an ssh login" \
      org.opencontainers.image.base.name="docker.io/library/debian:13-slim" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-server \
    && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_* /usr/lib/openssh/sftp-server

COPY docker/play docker/authorized-keys docker/import-keys /usr/local/bin/
# sshd runs as `play` itself, not as root: it can only ever log in that one account, and the
# container keeps no capability. `play` may read /etc/shadow (where its own empty password
# is, for AUTH_MODE=open); nothing else is in it.
RUN useradd --system --uid 10222 --no-create-home --home-dir /home/play --shell /usr/local/bin/play play \
    && passwd -d play \
    && chgrp play /etc/shadow && chmod 640 /etc/shadow \
    && install -d -m 755 -o root -g root /home/play \
    && install -d -m 700 -o play -g play /keys

COPY --from=binary /pkg/crackattack-terminal /usr/local/bin/crackattack-terminal
# Licence, authors and third-party notices travel with the binary.
COPY --from=binary /pkg/ /usr/share/doc/crackattack-terminal/
RUN rm /usr/share/doc/crackattack-terminal/crackattack-terminal

COPY docker/sshd_config /etc/ssh/sshd_config
COPY docker/banner /etc/ssh/banner
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

VOLUME /keys
USER play
EXPOSE 2222
HEALTHCHECK --interval=60s --timeout=10s --start-period=10s \
    CMD crackattack-terminal --headless --autoplay easy --frames 100 > /dev/null \
        && ssh-keyscan -T 3 -p 2222 127.0.0.1 2> /dev/null | grep -q ssh-ed25519
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
