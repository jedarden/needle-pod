#!/usr/bin/env bash
# Reconcile the baked version floor against the ConfigMap-declared ceiling.
#
# The contract (docs/notes/image-and-update-strategy.md, Decision 3):
#   - the image bakes a known-good set and records it in versions.json
#   - a ConfigMap declares the *exact* desired version of any tool
#   - unset means "use what was baked" — normally this whole file is a no-op
#   - nothing ever resolves "latest" here; that would make two pods on the same
#     image digest run different code
#
# Upgrades install alongside, get probed, and only then have the symlink
# flipped (Decision 6). A failed probe leaves the baked version in place and
# emits telemetry, so one bad upstream release cannot break the fleet at once.

# shellcheck source=common.sh
. "${NEEDLE_POD_LIB}/common.sh"

NEEDLE_POD_PROBE="${NEEDLE_POD_PROBE:-/usr/local/lib/needle-pod/probe/harness-probe.sh}"

# Map a harness name to the npm package that provides it. Harnesses installed
# by shell installer (goose, droid) and aider are deliberately absent: they have
# no npm identity, so declaring a version for them is not supported and is
# rejected loudly rather than silently ignored.
_npm_package_for() {
    case "$1" in
        claude-code) echo "@anthropic-ai/claude-code" ;;
        codex)       echo "@openai/codex" ;;
        opencode)    echo "opencode-ai" ;;
        pi)          echo "@earendil-works/pi-coding-agent" ;;
        *)           echo "" ;;
    esac
}

_baked_version_of() {
    jq -r --arg h "$1" '.harnesses[$h] // "absent"' "$VERSIONS_FILE" 2>/dev/null
}

# reconcile_harness_versions — walk the declared ceiling and act only on drift.
reconcile_harness_versions() {
    local declared="${NEEDLE_POD_HARNESS_VERSIONS:-}"
    [ -n "$declared" ] || { log_info "no declared harness versions; using baked floor"; return 0; }

    # Format: "claude-code=2.1.223,codex=0.147.0"
    local pair harness want have pkg
    while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        harness="${pair%%=*}"
        want="${pair#*=}"

        if [ "$harness" = "$want" ] || [ -z "$want" ]; then
            log_error "malformed entry in NEEDLE_POD_HARNESS_VERSIONS; expected name=version" \
                --arg entry "$pair"
            continue
        fi

        if [ "$want" = "latest" ]; then
            # Refused on purpose. "latest" here reintroduces exactly the
            # invisible drift the pinning scheme exists to prevent.
            log_error "declared version 'latest' is not permitted; pin an exact version" \
                --arg harness "$harness"
            continue
        fi

        pkg="$(_npm_package_for "$harness")"
        if [ -z "$pkg" ]; then
            log_error "harness is not npm-managed; version cannot be declared" \
                --arg harness "$harness" --arg declared "$want"
            continue
        fi

        have="$(_baked_version_of "$harness")"
        if [ "$have" = "$want" ]; then
            log_info "harness already at declared version" \
                --arg harness "$harness" --arg version "$want"
            continue
        fi

        _install_and_flip "$harness" "$pkg" "$want" "$have"
    done <<< "$(split_list "$declared")"
}

# Install a version into a private prefix, probe it end-to-end, and only flip
# the symlink on a pass. Unix exec semantics make the flip safe mid-dispatch —
# a running process holds its own inode.
_install_and_flip() {
    local harness="$1" pkg="$2" want="$3" have="$4"
    local prefix="${HOME}/.needle-pod/versions/${harness}/${want}"
    local bin_dir="${HOME}/.local/bin"

    log_info "installing declared harness version" \
        --arg harness "$harness" --arg from "$have" --arg to "$want"

    mkdir -p "$prefix" "$bin_dir"
    if ! npm install --prefix "$prefix" --global --ignore-scripts "${pkg}@${want}" >/dev/null 2>&1; then
        log_error "declared harness version failed to install; keeping current" \
            --arg harness "$harness" --arg version "$want"
        return 1
    fi

    local candidate="${prefix}/bin/${harness}"
    # npm installs the bin under the package's own name, which is not always
    # the harness name (claude-code ships `claude`).
    [ -x "$candidate" ] || candidate="$(find "$prefix/bin" -maxdepth 1 -type f -o -type l 2>/dev/null | head -1)"
    if [ ! -x "$candidate" ]; then
        log_error "installed package exposed no runnable binary; keeping current" \
            --arg harness "$harness" --arg version "$want"
        return 1
    fi

    if ! "$NEEDLE_POD_PROBE" "$harness" "$candidate"; then
        log_error "probe failed for declared version; staying on current binary" \
            --arg harness "$harness" --arg version "$want" --arg kept "$have"
        return 1
    fi

    ln -sfn "$candidate" "${bin_dir}/$(basename "$candidate")"
    log_info "harness version flipped after passing probe" \
        --arg harness "$harness" --arg version "$want"
}

# needle itself needs none of this. Its own hot-reload (src/upgrade/mod.rs)
# watches the :stable path and re-execs with --resume, so dropping a new binary
# there is the entire update. Recorded here so nobody adds a redundant path.
reconcile_needle_version() {
    local declared="${NEEDLE_POD_NEEDLE_VERSION:-}"
    [ -n "$declared" ] || return 0
    local baked
    baked="$(jq -r '.core.needle_release // "unknown"' "$VERSIONS_FILE" 2>/dev/null)"
    [ "$declared" = "$baked" ] && return 0
    log_warn "declared needle version differs from the baked image; rebuild rather than patching in-pod" \
        --arg declared "$declared" --arg baked "$baked"
}
