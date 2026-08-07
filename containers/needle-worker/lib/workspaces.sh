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
#
# HYDRATION IS MANDATORY, AND THE REASON IS DESTRUCTIVE.
#
# `beads.db` is gitignored fleet-wide, so a fresh clone carries only the
# `issues.jsonl` checkpoint. Measured on a real clone: `bf ready` silently
# auto-creates an EMPTY database and reports "No ready candidates" while 354
# open beads sit unread in the checkpoint. That alone would idle every worker.
#
# The worse half: flushing that empty database writes it back over the
# checkpoint. Measured on the same clone — `bf sync --flush-only` took
# issues.jsonl from 2,333 beads to 0. Worker pods hold a push credential, so an
# unhydrated clone is one flush away from destroying a repo's entire bead
# history and pushing the result.
#
# So every clone is hydrated with `bf sync --import-only` (note: `--import` is
# not a valid flag), the result is verified against the checkpoint, and any
# workspace that fails verification is quarantined out of Explore's view rather
# than left where something can flush it.

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

# Rebuild the SQLite store from the committed checkpoint, then prove it worked.
# Returns non-zero if the workspace must not be exposed to Explore.
hydrate_beads() {
    local dest="$1" name="$2"
    local beads_dir="${dest}/.beads"
    local jsonl="${beads_dir}/issues.jsonl"

    [ -d "$beads_dir" ] || return 1

    if [ ! -f "$jsonl" ]; then
        log_warn "workspace has .beads but no issues.jsonl checkpoint" --arg repo "$name"
        return 1
    fi

    local expected
    expected="$(grep -cve '^[[:space:]]*$' "$jsonl" 2>/dev/null || echo 0)"

    if [ "$expected" -eq 0 ]; then
        # A genuinely empty checkpoint is legitimate (a new repo). There is
        # nothing to import and nothing an accidental flush could destroy.
        log_info "workspace checkpoint is empty; nothing to hydrate" --arg repo "$name"
        return 0
    fi

    if ! ( cd "$dest" && timeout "${NEEDLE_POD_IMPORT_TIMEOUT:-300}" bf sync --import-only ) >/dev/null 2>&1; then
        log_error "bead import failed" --arg repo "$name" --argjson expected "$expected"
        quarantine_workspace "$dest" "$name" "import-failed"
        return 1
    fi

    local actual
    actual="$(sqlite3 "${beads_dir}/beads.db" 'SELECT COUNT(*) FROM issues;' 2>/dev/null || echo 0)"

    # The check that matters: a populated checkpoint must yield a populated
    # store. Anything else is the empty-database state, which is the one that
    # destroys data on flush.
    if [ "${actual:-0}" -eq 0 ]; then
        log_error "bead store is empty after import; quarantining before anything can flush it" \
            --arg repo "$name" --argjson expected "$expected" --argjson imported "${actual:-0}"
        quarantine_workspace "$dest" "$name" "empty-after-import"
        return 1
    fi

    log_info "bead store hydrated" \
        --arg repo "$name" --argjson imported "$actual" --argjson checkpoint "$expected"
    return 0
}

# Make a workspace invisible to Explore without discarding it. Renaming .beads
# is enough — discovery keys on that directory's presence — and it leaves the
# clone intact for `kubectl exec` triage.
quarantine_workspace() {
    local dest="$1" name="$2" reason="$3"
    if mv "${dest}/.beads" "${dest}/.beads.quarantined" 2>/dev/null; then
        log_warn "workspace quarantined; Explore will skip it" \
            --arg repo "$name" --arg reason "$reason"
    else
        # Could not quarantine — removing the clone outright is the safe
        # fallback, because leaving it is what risks the checkpoint.
        rm -rf "$dest"
        log_warn "workspace removed; could not quarantine" \
            --arg repo "$name" --arg reason "$reason"
    fi
}

clone_workspaces() {
    local workspaces_dir="${NEEDLE_POD_WORKSPACES_DIR:-$HOME/workspaces}"
    local base_url="${NEEDLE_POD_GIT_BASE_URL:-https://git.ardenone.com/jedarden}"
    local repos cloned=0 skipped=0 usable=0

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
            # Pre-existing clone (a restart on a persisted volume). Do NOT
            # re-import: rebuilding the store from the checkpoint is exactly
            # what destroys beads created since the last flush. Only hydrate
            # when the store is actually empty, which is the unsafe state.
            skipped=$((skipped + 1))
            local existing
            existing="$(sqlite3 "$dest/.beads/beads.db" 'SELECT COUNT(*) FROM issues;' 2>/dev/null || echo 0)"
            if [ "${existing:-0}" -gt 0 ]; then
                log_info "workspace already present with a populated store; left untouched" \
                    --arg repo "$name" --argjson beads "$existing"
                usable=$((usable + 1))
            elif hydrate_beads "$dest" "$name"; then
                usable=$((usable + 1))
            fi
            continue
        fi

        # Shallow by default: workers act on current state, and full history on
        # ~90 repos would dominate both startup time and the emptyDir.
        local depth_args=(--depth "${NEEDLE_POD_CLONE_DEPTH:-1}")
        [ "${NEEDLE_POD_CLONE_DEPTH:-1}" = "0" ] && depth_args=()

        if git clone --quiet "${depth_args[@]}" "$url" "$dest" 2>/dev/null; then
            cloned=$((cloned + 1))
            if [ ! -d "$dest/.beads" ]; then
                # Not fatal — but this repo contributes no work, and saying so
                # here is far cheaper than diagnosing an idle worker later.
                log_warn "workspace has no .beads store; Explore will not see it" \
                    --arg repo "$name"
            elif hydrate_beads "$dest" "$name"; then
                usable=$((usable + 1))
            fi
        else
            # One unreachable repo must not stop the worker from starting.
            log_error "workspace clone failed" --arg repo "$name" --arg url "$url"
        fi
    done <<< "$repos"

    log_info "workspace setup complete" \
        --argjson cloned "$cloned" \
        --argjson skipped "$skipped" \
        --argjson usable "$usable" \
        --arg dir "$workspaces_dir"

    # An all-clones-succeeded / nothing-usable run is the silent-idle case.
    # Say it once, loudly, rather than letting it read as a healthy start.
    if [ "$usable" -eq 0 ]; then
        log_warn "no workspace has a usable bead store; this worker will find no work"
    fi
}
