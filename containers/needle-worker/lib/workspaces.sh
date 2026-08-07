#!/usr/bin/env bash
# Clone the repos this worker should roam over.
#
# One pod = one clone per repo, on an emptyDir, discarded at restart. That is
# the deliberate upside of the pod shape: it removes the shared-worktree
# collision class the bare-metal fleet still hits. Do not reintroduce sharing
# to save disk.
#
# A repo is only visible to the Explore strand if it contains a `.beads/`
# directory — recursive discovery keys off exactly that. A clone without one is
# silently invisible, so it is reported here rather than left to puzzle someone
# reading an idle worker's telemetry.

# shellcheck source=common.sh
. "${NEEDLE_POD_LIB}/common.sh"

# Git needs an identity to commit; the fleet convention is fleet-wide.
configure_git() {
    git config --global user.email "${NEEDLE_POD_GIT_EMAIL:-github@jedarden.com}"
    git config --global user.name  "${NEEDLE_POD_GIT_NAME:-jedarden}"
    git config --global init.defaultBranch main
    git config --global advice.detachedHead false
    # Never prompt: a credential prompt in a pod hangs the worker forever.
    git config --global core.askPass /bin/true
    export GIT_TERMINAL_PROMPT=0

    # Push credential, if one was mounted. Forgejo is the source of truth;
    # GitHub is a read-only mirror and must never be pushed to.
    if [ -n "${NEEDLE_POD_GIT_TOKEN:-}" ]; then
        local host="${NEEDLE_POD_GIT_HOST:-git.ardenone.com}"
        local user="${NEEDLE_POD_GIT_USER:-jedarden}"
        # Credentials go to a 0600 file in $HOME, never into a remote URL —
        # a URL-embedded token leaks through `git remote -v` and into any
        # error message the agent might echo into a bead comment.
        printf 'https://%s:%s@%s\n' "$user" "$NEEDLE_POD_GIT_TOKEN" "$host" > "$HOME/.git-credentials"
        chmod 600 "$HOME/.git-credentials"
        git config --global credential.helper store
        log_info "git push credential configured" --arg host "$host"
    else
        log_warn "no git push credential mounted; workers can commit but not push"
    fi
}

clone_workspaces() {
    local workspaces_dir="${NEEDLE_POD_WORKSPACES_DIR:-$HOME/workspaces}"
    local base_url="${NEEDLE_POD_GIT_BASE_URL:-https://git.ardenone.com/jedarden}"
    local repos cloned=0 skipped=0

    mkdir -p "$workspaces_dir"
    repos="$(split_list "${NEEDLE_POD_WORKSPACES:-}")"

    if [ -z "$repos" ]; then
        log_warn "NEEDLE_POD_WORKSPACES is empty; worker will start with no repos to roam"
        return 0
    fi

    while IFS= read -r repo; do
        [ -n "$repo" ] || continue

        # Accept either a bare repo name or a full URL, so a one-off repo
        # outside the default org needs no new plumbing.
        local url name
        case "$repo" in
            *://*) url="$repo"; name="$(basename "${repo%.git}")" ;;
            *)     url="${base_url}/${repo}.git"; name="$repo" ;;
        esac

        local dest="${workspaces_dir}/${name}"
        if [ -d "$dest/.git" ]; then
            log_info "workspace already present; skipping clone" --arg repo "$name"
            skipped=$((skipped + 1))
            continue
        fi

        # Shallow by default: workers act on current state, and full history on
        # ~90 repos would dominate both startup time and the emptyDir.
        local depth_args=(--depth "${NEEDLE_POD_CLONE_DEPTH:-1}")
        [ "${NEEDLE_POD_CLONE_DEPTH:-1}" = "0" ] && depth_args=()

        if git clone --quiet "${depth_args[@]}" "$url" "$dest" 2>/dev/null; then
            cloned=$((cloned + 1))
            if [ -d "$dest/.beads" ]; then
                log_info "workspace cloned" --arg repo "$name"
            else
                # Not fatal — but this repo contributes no work, and saying so
                # here is far cheaper than diagnosing an idle worker later.
                log_warn "workspace has no .beads store; Explore will not see it" \
                    --arg repo "$name"
            fi
        else
            # One unreachable repo must not stop the worker from starting.
            log_error "workspace clone failed" --arg repo "$name" --arg url "$url"
        fi
    done <<< "$repos"

    log_info "workspace setup complete" \
        --argjson cloned "$cloned" \
        --argjson skipped "$skipped" \
        --arg dir "$workspaces_dir"
}
