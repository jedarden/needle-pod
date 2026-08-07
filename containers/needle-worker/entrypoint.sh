#!/usr/bin/env bash
# needle-pod worker entrypoint.
#
# Turns a pod's environment into a running NEEDLE worker: provider credentials
# fanned out into every harness's config format, a rendered needle config, repos
# cloned onto the emptyDir, telemetry shipping to stdout, then `needle run` in
# the foreground as PID 1's child.
#
# Everything here is idempotent and re-runs on every restart — a preempted spot
# node is the normal case, not an exception.

set -euo pipefail

NEEDLE_POD_LIB="${NEEDLE_POD_LIB:-/usr/local/lib/needle-pod/lib}"
NEEDLE_POD_SHARE="${NEEDLE_POD_SHARE:-/usr/local/share/needle-pod}"
export NEEDLE_POD_LIB NEEDLE_POD_SHARE

# shellcheck source=lib/common.sh
. "${NEEDLE_POD_LIB}/common.sh"
# shellcheck source=lib/needle-config.sh
. "${NEEDLE_POD_LIB}/needle-config.sh"
# shellcheck source=lib/workspaces.sh
. "${NEEDLE_POD_LIB}/workspaces.sh"
# shellcheck source=lib/telemetry.sh
. "${NEEDLE_POD_LIB}/telemetry.sh"
# shellcheck source=lib/versions.sh
. "${NEEDLE_POD_LIB}/versions.sh"

announce_image() {
    if [ -r "$VERSIONS_FILE" ]; then
        # The whole baked manifest, once, at start. This is what makes
        # "what was running when this broke?" answerable from `kubectl logs`
        # alone, without pulling the image apart.
        jq -c '{message: "needle-pod worker starting", level: "info",
                component: "needle-pod-entrypoint", versions: .}' "$VERSIONS_FILE" >&2
    else
        log_warn "no baked versions manifest found" --arg path "$VERSIONS_FILE"
    fi
}

# The worker's identity in telemetry. Defaults to the pod name, which is what
# makes a single failing worker's history isolatable during triage.
resolve_worker_identity() {
    export NEEDLE_WORKER_ID="${NEEDLE_POD_WORKER_ID:-${HOSTNAME:-needle-worker}}"
    log_info "worker identity resolved" --arg worker_id "$NEEDLE_WORKER_ID"
}

# The default agent is an adapter name, and adapters are named
# <harness>-<provider> by render.py. Both halves must be resolved the same way
# here or needle will start with a default_agent that does not exist.
resolve_default_agent() {
    local harnesses provider harness
    harnesses="$(split_list "${NEEDLE_POD_HARNESSES:-claude-code}")"
    harness="${NEEDLE_POD_DEFAULT_HARNESS:-$(head -1 <<< "$harnesses")}"
    provider="${NEEDLE_POD_DEFAULT_PROVIDER:-$(head -1 <<< "$(split_list "${NEEDLE_POD_PROVIDERS:-}")")}"

    [ -n "$harness" ]  || die "cannot resolve a default harness"
    [ -n "$provider" ] || die "cannot resolve a default provider"

    if ! grep -qx "$harness" <<< "$harnesses"; then
        die "NEEDLE_POD_DEFAULT_HARNESS is not in NEEDLE_POD_HARNESSES" \
            --arg default "$harness" --arg harnesses "$(echo "$harnesses" | tr '\n' ' ')"
    fi

    export NEEDLE_POD_DEFAULT_AGENT="${harness}-${provider}"
    log_info "default agent resolved" --arg agent "$NEEDLE_POD_DEFAULT_AGENT"
}

render_providers() {
    # render.py owns every harness config format and the adapter YAMLs. It
    # fails closed: a missing token or an unknown harness stops the pod here,
    # with a named cause, rather than surfacing as a dispatch failure later.
    if ! python3 "${NEEDLE_POD_LIB}/render.py"; then
        die "provider rendering failed; refusing to start with a partial configuration"
    fi
}

verify_harnesses() {
    # Optional and off by default: a real dispatch per harness costs tokens and
    # wall-clock on every restart, which is the wrong trade on a preemptible
    # node. Turn it on when validating a new image.
    [ "${NEEDLE_POD_PROBE_ON_START:-false}" = "true" ] || return 0

    local harness failed=0
    while IFS= read -r harness; do
        [ -n "$harness" ] || continue
        if ! /usr/local/lib/needle-pod/probe/harness-probe.sh "$harness"; then
            failed=$((failed + 1))
        fi
    done <<< "$(split_list "${NEEDLE_POD_HARNESSES:-claude-code}")"

    if [ "$failed" -gt 0 ]; then
        # Warn, do not die. One broken harness should not idle a worker that
        # can still dispatch through the others.
        log_warn "one or more harnesses failed the start probe" --argjson failed "$failed"
    fi
}

main() {
    announce_image
    resolve_worker_identity

    require_env NEEDLE_POD_PROVIDERS

    resolve_default_agent
    render_providers
    reconcile_needle_version
    reconcile_harness_versions

    configure_git
    clone_workspaces

    render_needle_config

    start_log_shipper
    start_log_pruner

    verify_harnesses

    # Belt-and-braces over the rendered config file. NEEDLE applies
    # NEEDLE_<PATH> overrides with __ as the separator, and both of these are
    # in its allowlist. Setting them here means the two values a pod cannot
    # function without survive even if the config file is ever written to the
    # wrong path again — which is exactly the bug that made the first
    # deployment idle with a fully hydrated repo one directory away.
    export NEEDLE_STRANDS__EXPLORE__ENABLED=true
    export NEEDLE_STRANDS__EXPLORE__WORKSPACE_ROOT="${NEEDLE_POD_WORKSPACES_DIR:-$HOME/workspaces}"
    export NEEDLE_AGENT__DEFAULT="${NEEDLE_POD_DEFAULT_AGENT}"

    # Fail here rather than at dispatch. Without this, a wrong adapter name
    # only surfaces after the worker has already CLAIMED a bead — it then dies
    # and leaves that bead claimed until mend reclaims it, burning a lease per
    # restart.
    local adapters_dir="${NEEDLE_ADAPTERS_DIR:-$HOME/.config/needle/adapters}"
    if [ ! -f "${adapters_dir}/${NEEDLE_POD_DEFAULT_AGENT}.yaml" ]; then
        die "default adapter YAML is missing; refusing to start and orphan beads" \
            --arg adapter "$NEEDLE_POD_DEFAULT_AGENT" \
            --arg expected "${adapters_dir}/${NEEDLE_POD_DEFAULT_AGENT}.yaml"
    fi

    log_info "handing off to needle run" \
        --arg workspace_root "$NEEDLE_STRANDS__EXPLORE__WORKSPACE_ROOT" \
        --arg agent "$NEEDLE_AGENT__DEFAULT"

    # exec, deliberately: needle becomes the signalled process so its own
    # SIGTERM handler runs directly, with no shell in between to swallow it.
    #
    # KNOWN GAP: that handler sets a shutdown flag and breaks the supervisor
    # loop without awaiting in-flight dispatch children, so a preemption
    # mid-dispatch orphans the bead until the stale reaper releases it
    # (heartbeat_max_age, lowered in needle-config.sh). The real fix is an
    # upstream drain in src/supervisor/mod.rs — tracked, not solved here.
    exec needle run --resume "$@"
}

main "$@"
