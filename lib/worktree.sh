#!/usr/bin/env bash

resolve_branch() {
    local repo="$1" branch="$2"
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
        echo "local"
    elif git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        echo "remote"
    else
        echo "new"
    fi
}

tree_sha_for_branch() {
    local repo="$1" branch="$2"
    git -C "$repo" rev-parse --verify "$branch^{tree}" 2>/dev/null
}

# Atomic directory rename via rename(2). GNU `mv -T` isn't on macOS BSD mv;
# Perl's rename() is portable (ships in base macOS and every Linux distro)
# and uses renameat2/rename(2) underneath — replaces empty target dir,
# fails with ENOTEMPTY if a concurrent builder beat us to it.
_atomic_rename_dir() {
    perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"
}

build_reference() {
    local repo="$1" tree_sha="$2" ref_path="$3"
    local tmp="${ref_path}.tmp.$$"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    if ! git -C "$repo" archive "$tree_sha" | tar -x -C "$tmp"; then
        rm -rf "$tmp"
        return 1
    fi
    if ! _atomic_rename_dir "$tmp" "$ref_path" 2>/dev/null; then
        rm -rf "$tmp"
        [[ -d "$ref_path" ]] || return 1
    fi
}

default_mountpoint() {
    local repo="$1" branch="$2"
    local parent
    parent=$(dirname "$repo")
    echo "$parent/$(sanitize_branch "$branch")"
}

configure_worktree_stat() {
    local repo="$1" mountpoint="$2"
    git -C "$repo" config extensions.worktreeConfig true
    git -C "$mountpoint" config --worktree core.checkStat minimal
    git -C "$mountpoint" config --worktree core.trustctime false
}

cmd_add() {
    local branch="${1:-}" mountpoint="${2:-}"
    [[ -n "$branch" ]] || die "usage: gh wt add <branch> [path]"

    local repo
    repo=$(require_main_repo)
    check_repo_sanity "$repo"

    case "$(resolve_branch "$repo" "$branch")" in
        local) ;;
        remote)
            git -C "$repo" branch --track "$branch" "origin/$branch" >/dev/null
            ;;
        new)
            git -C "$repo" branch "$branch" >/dev/null \
                || die "cannot create branch '$branch'"
            ;;
    esac

    check_branch_no_submodules "$repo" "$branch"

    [[ -n "$mountpoint" ]] || mountpoint=$(default_mountpoint "$repo" "$branch")
    mountpoint=$(canonical_path "$mountpoint")
    [[ ! -e "$mountpoint" ]] || die "mountpoint already exists: $mountpoint"

    if [[ "$(resolve_backend)" == "apfs" ]]; then
        local tree_sha
        tree_sha=$(tree_sha_for_branch "$repo" "$branch") \
            || die "cannot resolve tree for '$branch'"

        ensure_cache_dirs "$repo"

        local ref_path
        ref_path=$(ref_dir "$repo" "$tree_sha")
        if [[ ! -d "$ref_path" ]]; then
            echo "preparing reference $tree_sha..."
            build_reference "$repo" "$tree_sha" "$ref_path" \
                || die "failed to build reference $tree_sha"
        fi

        git -C "$repo" worktree add --no-checkout "$mountpoint" "$branch" \
            || die "git worktree add failed"

        # clonefile(2) via `cp -c`: files share blocks with the reference
        # until modified, so N sessions cost ~1x disk for unchanged content.
        # -p preserves timestamps so git's stat cache stays accurate against
        # the committed tree.
        local entry
        while IFS= read -r -d '' entry; do
            if ! cp -cRp "$entry" "$mountpoint/"; then
                git -C "$repo" worktree remove --force "$mountpoint" >/dev/null 2>&1 || true
                rm -rf "$mountpoint"
                die "apfs clone failed (is $mountpoint on the same APFS volume as $ref_path?)"
            fi
        done < <(find "$ref_path" -mindepth 1 -maxdepth 1 -print0)

        # Remember which reference this worktree cloned from so `gc` knows
        # it's still live. Hide the marker from `git status` via the linked
        # worktree's private info/exclude (scoped to this worktree only).
        printf '%s\n' "$ref_path" > "$mountpoint/.gh-wt-ref"
        local wt_gitdir
        wt_gitdir=$(git -C "$mountpoint" rev-parse --git-path info/exclude 2>/dev/null) || wt_gitdir=""
        if [[ -n "$wt_gitdir" ]]; then
            mkdir -p "$(dirname "$wt_gitdir")"
            grep -qxF '.gh-wt-ref' "$wt_gitdir" 2>/dev/null \
                || printf '.gh-wt-ref\n' >> "$wt_gitdir"
        fi

        # Working tree already matches HEAD; just sync the index so
        # `git status` reports a clean tree.
        git -C "$mountpoint" reset --mixed HEAD >/dev/null 2>&1 || true

        configure_worktree_stat "$repo" "$mountpoint"

        echo "worktree ready: $mountpoint"
        echo "  branch:    $branch"
        echo "  reference: $ref_path (APFS clonefile)"
        return 0
    fi

    if [[ "$(resolve_backend)" == "none" ]]; then
        # --no-checkout returns as soon as the .git pointer is written. Files
        # stream in via a detached `git reset --hard` that survives the parent
        # shell (`nohup` + `&`). Dep symlinks are made up front because
        # they're gitignored and won't race the checkout. `reset --hard HEAD`
        # is used instead of `checkout` because --no-checkout leaves the index
        # empty, so checkout-by-pathspec finds nothing to materialise.
        git -C "$repo" worktree add --no-checkout "$mountpoint" "$branch" \
            || die "git worktree add failed"
        link_parent_deps "$repo" "$mountpoint"
        local log="$mountpoint/.gh-wt-checkout.log"
        nohup git -C "$mountpoint" reset --hard HEAD \
            </dev/null >"$log" 2>&1 &
        local pid=$!
        disown "$pid" 2>/dev/null || true
        echo "worktree ready: $mountpoint"
        echo "  branch:    $branch"
        echo "  checkout:  async (pid=$pid, log=$log) — plain git worktree"
        return 0
    fi

    local tree_sha
    tree_sha=$(tree_sha_for_branch "$repo" "$branch") \
        || die "cannot resolve tree for '$branch'"

    ensure_cache_dirs "$repo"

    local ref_path
    ref_path=$(ref_dir "$repo" "$tree_sha")
    if [[ ! -d "$ref_path" ]]; then
        echo "preparing reference $tree_sha..."
        build_reference "$repo" "$tree_sha" "$ref_path" \
            || die "failed to build reference $tree_sha"
    fi

    mkdir -p "$mountpoint"
    git -C "$repo" worktree add --no-checkout "$mountpoint" "$branch" \
        || { rmdir "$mountpoint"; die "git worktree add failed"; }

    local sid
    sid=$(session_id_from_gitfile "$mountpoint") \
        || die "cannot read linked worktree gitdir"
    local sdir
    sdir=$(session_dir "$repo" "$sid")
    mkdir -p "$sdir/upper" "$sdir/workdir"

    mv "$mountpoint/.git" "$sdir/upper/.git"

    if ! overlay_mount "$ref_path" "$sdir/upper" "$sdir/workdir" "$mountpoint"; then
        mv "$sdir/upper/.git" "$mountpoint/.git" 2>/dev/null || true
        git -C "$repo" worktree remove --force "$mountpoint" >/dev/null 2>&1 || true
        remove_session_dir "$sdir"
        rmdir "$mountpoint" 2>/dev/null || true
        die "overlay mount failed"
    fi

    configure_worktree_stat "$repo" "$mountpoint"
    git -C "$mountpoint" update-index --refresh >/dev/null 2>&1 || true

    echo "worktree ready: $mountpoint"
    echo "  branch:    $branch"
    echo "  reference: $ref_path (OverlayFS lower)"
    echo "  session:   $sdir"
}

cmd_list() {
    local repo
    repo=$(require_main_repo)
    git -C "$repo" worktree list
}

select_session() {
    local repo="$1" prompt="${2:-select worktree: }"
    local list
    list=$(git -C "$repo" worktree list --porcelain \
        | awk '/^worktree / { print substr($0, 10) }')
    [[ -n "$list" ]] || { echo "no worktrees" >&2; return 1; }
    fzf --prompt="$prompt" <<<"$list"
}

cmd_remove() {
    local repo selected sid sdir
    repo=$(require_main_repo)
    selected=$(select_session "$repo" "remove: ") || return 0
    [[ -n "$selected" ]] || return 0
    [[ "$selected" != "$repo" ]] || die "refusing to remove main worktree"

    case "$(resolve_backend)" in
        none|apfs)
            git -C "$repo" worktree remove --force "$selected"
            echo "removed: $selected"
            return 0
            ;;
    esac

    sid=$(session_id_from_gitfile "$selected") \
        || die "not a gh-wt session (no linked gitdir pointer): $selected"
    sdir=$(session_dir "$repo" "$sid")
    [[ -d "$sdir/upper" && -d "$sdir/workdir" ]] \
        || die "refusing to remove non-gh-wt worktree: $selected"

    if is_mounted "$selected"; then
        check_mountpoint_free "$selected"
        overlay_umount "$selected" || die "umount failed: $selected"
    fi

    git -C "$repo" worktree remove --force "$selected"
    remove_session_dir "$sdir"

    echo "removed: $selected"
}

cmd_exec_in() {
    local repo selected
    repo=$(require_main_repo)
    selected=$(select_session "$repo") || return 0
    [[ -n "$selected" ]] || return 0
    cd "$selected" || die "cannot cd into $selected"
    exec "$@"
}

cmd_exec_with() {
    local repo selected
    repo=$(require_main_repo)
    selected=$(select_session "$repo") || return 0
    [[ -n "$selected" ]] || return 0
    exec "$@" "$selected"
}

cmd_doctor() {
    local mode
    mode=$(resolve_backend)
    echo "platform: $(uname -s)"
    case "$mode" in
        apfs)
            echo "mode:     APFS clonefile(2) — helper-free CoW"
            apfs_clone_available || { echo "  clonefile: unavailable on this volume" >&2; exit 1; }
            echo "  clonefile: ok"
            ;;
        overlayfs)
            echo "mode:     Linux OverlayFS"
            check_kernel && echo "  kernel >= 5.11: ok"
            check_overlay_fs && echo "  overlayfs available: ok"
            if have_mount_cap; then
                echo "  mount capability: ok"
            else
                echo "  mount capability: MISSING (need root or passwordless sudo)" >&2
                exit 1
            fi
            ;;
        none)
            echo "mode:     plain git worktree (no CoW support on this host)"
            ;;
        *) die "unresolved platform mode: $mode" ;;
    esac
}

cmd_gc() {
    if [[ "$(resolve_backend)" == "none" ]]; then
        echo "nothing to gc (backend=none uses no cache)"
        return 0
    fi
    local repo
    repo=$(require_main_repo)
    local base
    base=$(repo_cache_dir "$repo")
    [[ -d "$base/ref" ]] || { echo "nothing to gc"; return 0; }

    local live_lowers
    if [[ "$(resolve_backend)" == "apfs" ]]; then
        # apfs has no mount state — each worktree stores its ref path in a
        # .gh-wt-ref sidecar. Walk the worktree list and collect them.
        # `|| true` guards against set -e killing the sub when no sidecar
        # file exists (common during partial cleanup).
        live_lowers=$(
            git -C "$repo" worktree list --porcelain \
                | awk '/^worktree / { print substr($0, 10) }' \
                | while IFS= read -r wt; do
                    if [[ -f "$wt/.gh-wt-ref" ]]; then
                        cat "$wt/.gh-wt-ref"
                    fi
                done \
                | sort -u || true
        )
    else
        live_lowers=$(live_overlay_lowerdirs | sort -u)
    fi

    local removed=0 ref
    while IFS= read -r -d '' ref; do
        if ! grep -Fxq "$ref" <<<"$live_lowers"; then
            echo "gc: $ref"
            remove_cache_path "$ref"
            removed=$((removed + 1))
        fi
    done < <(find "$base/ref" -mindepth 1 -maxdepth 1 -type d -print0)

    echo "gc: removed $removed reference(s)"
}
