# syntax=docker/dockerfile:1.7
###############################################################################
# needle-pod worker runtime image
#
# One NEEDLE worker per pod. Fat by design (docs/notes/image-and-update-strategy.md,
# Decision 1): a single image carrying every toolchain, so workers keep NEEDLE's
# default cross-repo roaming rather than being pinned to a language cohort.
# agent-sandbox nodes carry ~96 GiB ephemeral, which makes the size affordable.
#
# LAYER ORDER IS LOAD-BEARING. needle is ~13 MB against a multi-GB image whose
# bulk is toolchains, so it installs LAST: a needle-only rebuild reuses the
# cached base and pushes ~13 MB.
#
# Versions float at BUILD time and are frozen into /etc/needle-pod/versions.json.
# Nothing resolves "latest" at container start — see Decision 2 in the same note:
# doing so would break GitOps rollback for the fastest-moving component.
###############################################################################

FROM ubuntu:24.04

# Pin any of these at build time to reproduce an exact image. Empty means
# "resolve the current release at build time", which is what the nightly
# rebuild does (Decision 4 — no version-detection CI).
ARG NEEDLE_VERSION=
ARG NODE_MAJOR=24
ARG GO_VERSION=
ARG RUST_VERSION=stable
ARG CLAUDE_CODE_VERSION=
ARG CODEX_VERSION=
ARG OPENCODE_VERSION=
ARG PI_VERSION=
ARG AIDER_VERSION=
# Pinned, NOT main. Building from bead-forge HEAD produced a bf that imports
# beads but never creates the critical_path_cache / blocked_issues_cache
# tables, so every `bf ready` fails with "no such table" and the worker finds
# no work. schema.rs is mid-refactor: this commit references
# critical_path_cache 11 times, HEAD only 6. Verified working; bump
# deliberately, after testing `bf ready` on a fresh clone.
ARG BEAD_FORGE_REF=9cd859023d793a00775bd8f300b9b1a62a1e0f47

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# --- 1. Base OS packages -----------------------------------------------------
# ripgrep/fd/jq are here because agent harnesses shell out to them constantly;
# build-essential + pkg-config + libssl-dev are the floor for cargo builds.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git git-lfs openssh-client gnupg \
        build-essential pkg-config libssl-dev \
        python3 python3-venv python3-dev \
        ripgrep fd-find jq unzip xz-utils file procps less \
        sqlite3 tini \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# --- 2. Node.js --------------------------------------------------------------
# Node 24: @earendil-works/pi-coding-agent requires >=22.19.0 and
# @anthropic-ai/claude-code requires >=22.0.0, so 22 is the floor and 24 the
# nearest LTS above it.
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm config set fund false --global \
    && npm config set audit false --global

# --- 3. Python tooling (uv) --------------------------------------------------
# uv installs aider into its own managed interpreter; aider-chat requires
# >=3.10,<3.13 and pinning it here keeps that constraint off the system python.
ENV UV_INSTALL_DIR=/usr/local/bin
RUN curl -fsSL https://astral.sh/uv/install.sh | sh \
    && uv --version

# --- 4. Go -------------------------------------------------------------------
ENV GOROOT=/usr/local/go \
    GOPATH=/home/needle/go \
    PATH=/usr/local/go/bin:/home/needle/go/bin:$PATH
RUN set -eux; \
    ver="${GO_VERSION:-$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)}"; \
    case "$(dpkg --print-architecture)" in \
      amd64) garch=amd64 ;; arm64) garch=arm64 ;; \
      *) echo "unsupported arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/${ver}.linux-${garch}.tar.gz" -o /tmp/go.tgz; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz; \
    go version

# --- 5. Rust -----------------------------------------------------------------
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
# rustup-init takes --component once per component; a bare list makes it treat
# the second name as a positional argument and abort.
RUN curl -fsSL https://sh.rustup.rs | sh -s -- \
        -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_VERSION}" \
        --component clippy --component rustfmt \
    && chmod -R a+w "$RUSTUP_HOME" "$CARGO_HOME" \
    && rustc --version && cargo --version

# --- 6. Agent harnesses distributed via npm ----------------------------------
# --ignore-scripts is applied to pi ONLY, per its own containerization guide.
#
# It must NOT be applied to claude-code or opencode: both ship a postinstall
# that fetches their native binary, and skipping it leaves a stub that reports a
# healthy npm version while failing at run time with "native binary not
# installed". That failure is invisible to a version manifest, which is why the
# build asserts each one actually executes below.
RUN set -eux; \
    npm install -g \
        "@anthropic-ai/claude-code${CLAUDE_CODE_VERSION:+@$CLAUDE_CODE_VERSION}" \
        "@openai/codex${CODEX_VERSION:+@$CODEX_VERSION}" \
        "opencode-ai${OPENCODE_VERSION:+@$OPENCODE_VERSION}"; \
    npm install -g --ignore-scripts \
        "@earendil-works/pi-coding-agent${PI_VERSION:+@$PI_VERSION}"; \
    npm cache clean --force; \
    claude --version; \
    codex --version; \
    opencode --version; \
    pi --version

# --- 7. Agent harnesses distributed via shell installer ----------------------
# goose: CONFIGURE=false suppresses the interactive provider wizard. The
#   canonical installer now lives under aaif-goose/goose; block/goose still
#   redirects, so the documented URL is used and verified at build time.
# droid: Factory's installer drops the binary in ~/.local/bin, so it runs as
#   the needle user and PATH is extended below.
ENV GOOSE_BIN_DIR=/usr/local/bin
RUN set -eux; \
    CONFIGURE=false GOOSE_BIN_DIR=/usr/local/bin \
      bash -c 'curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | bash'; \
    goose --version

# droid installs to "$HOME/.local/bin", so HOME is pointed at /usr/local to land
# it somewhere every user can execute. Installing as root into /root/.local/bin
# would leave it unreadable by the non-root `needle` user at runtime.
#
# NOTE: the installer picks an AVX2 or a -baseline build by reading the BUILD
# host's /proc/cpuinfo. If the build host has AVX2 and a worker node does not,
# droid will fault at dispatch rather than at build. The harness probe is what
# catches that; it is why the probe runs a real dispatch rather than --help.
RUN set -eux; \
    mkdir -p /opt/factory; \
    HOME=/opt/factory sh -c 'curl -fsSL https://app.factory.ai/cli | sh'; \
    install -m 0755 /opt/factory/.local/bin/droid /usr/local/bin/droid; \
    droid --version

# --- 8. aider ----------------------------------------------------------------
# UV_TOOL_BIN_DIR puts the launcher on the shared PATH and UV_TOOL_DIR keeps the
# managed venv out of /root, so aider is runnable by the needle user.
RUN UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin \
    uv tool install --python 3.12 --force \
        "aider-chat${AIDER_VERSION:+==$AIDER_VERSION}" \
    && chmod -R a+rX /opt/uv-tools \
    && aider --version

# --- 9. bf (bead-forge) ------------------------------------------------------
# bead-forge publishes no binary release on either host — the Forgejo API
# requires auth and the GitHub mirror has no release assets — so it is built
# from the public mirror. Kept in its own layer so a bf bump does not rebuild
# the toolchains above it.
# Cloned full then checked out, because BEAD_FORGE_REF is a commit SHA and
# `git clone --branch` only accepts branches and tags.
RUN set -eux; \
    git clone https://github.com/jedarden/bead-forge.git /tmp/bead-forge; \
    git -C /tmp/bead-forge checkout --quiet "${BEAD_FORGE_REF}"; \
    cargo install --locked --path /tmp/bead-forge --root /usr/local; \
    rm -rf /tmp/bead-forge "$CARGO_HOME"/registry "$CARGO_HOME"/git; \
    bf --version

# --- 10. Non-root user -------------------------------------------------------
# uid 1000 matches the fleet convention. Everything the worker writes lives
# under /home/needle, which is where the emptyDir gets mounted.
# Ubuntu 24.04 ships a default `ubuntu` account already holding uid 1000, so it
# is removed first — the fleet convention is that the workload owns uid 1000.
RUN userdel --remove ubuntu 2>/dev/null || true; \
    useradd --create-home --shell /bin/bash --uid 1000 needle \
    && mkdir -p /home/needle/.needle /home/needle/workspaces /etc/needle-pod \
    && chown -R needle:needle /home/needle

# --- 11. Entrypoint, libraries, adapter templates ----------------------------
COPY --chown=root:root entrypoint.sh          /usr/local/lib/needle-pod/entrypoint.sh
COPY --chown=root:root lib/                   /usr/local/lib/needle-pod/lib/
COPY --chown=root:root probe/                 /usr/local/lib/needle-pod/probe/
COPY --chown=root:root adapters/              /usr/local/share/needle-pod/adapters/
COPY --chown=root:root bin/record-versions.sh /usr/local/bin/needle-pod-record-versions
RUN chmod +x /usr/local/lib/needle-pod/entrypoint.sh \
             /usr/local/lib/needle-pod/probe/*.sh \
             /usr/local/bin/needle-pod-record-versions

# --- 12. needle — LAST, deliberately -----------------------------------------
# ~13 MB. Installed into the versioned :stable layout NEEDLE's own hot-reload
# expects (src/upgrade/mod.rs), so dropping a new binary at the stable path is
# the entire in-pod update path — no image rebuild, no restart.
RUN set -eux; \
    ver="${NEEDLE_VERSION:-$(curl -fsSL https://api.github.com/repos/jedarden/NEEDLE/releases/latest | jq -r .tag_name)}"; \
    base="https://github.com/jedarden/NEEDLE/releases/download/${ver}"; \
    install -d /opt/needle/bin; \
    for b in needle needle-transform-claude needle-transform-codex; do \
        curl -fsSL "${base}/${b}-x86_64-unknown-linux-gnu" -o "/opt/needle/bin/${b}"; \
        chmod +x "/opt/needle/bin/${b}"; \
        ln -sf "/opt/needle/bin/${b}" "/usr/local/bin/${b}"; \
    done; \
    echo "$ver" > /etc/needle-pod/needle-version; \
    needle --version

# --- 13. Freeze the baked floor ---------------------------------------------
RUN /usr/local/bin/needle-pod-record-versions > /etc/needle-pod/versions.json \
    && cat /etc/needle-pod/versions.json

USER needle
WORKDIR /home/needle
ENV HOME=/home/needle \
    NEEDLE_HOME=/home/needle/.needle \
    NEEDLE_POD_WORKSPACES_DIR=/home/needle/workspaces \
    PATH=/home/needle/.local/bin:/home/needle/go/bin:/usr/local/go/bin:/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin

# tini reaps the agent subprocesses NEEDLE spawns per dispatch; without it a
# preempted pod leaves zombies behind the supervisor.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/lib/needle-pod/entrypoint.sh"]
