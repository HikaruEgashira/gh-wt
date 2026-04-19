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

build_reference() {
    local repo="$1" branch="$2" ref_path="$3"
    mkdir -p "$ref_path"
    git -C "$repo" archive "$branch" | tar -x -C "$ref_path"
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

    local tree_sha
    tree_sha=$(tree_sha_for_branch "$repo" "$branch") \
        || die "cannot resolve tree for '$branch'"

    [[ -n "$mountpoint" ]] || mountpoint=$(default_mountpoint "$repo" "$branch")
    mountpoint=$(readlink -m "$mountpoint")
    [[ ! -e "$mountpoint" ]] || die "mountpoint already exists: $mountpoint"

    ensure_cache_dirs "$repo"

    local ref_path
    ref_path=$(ref_dir "$repo" "$tree_sha")
    if [[ ! -d "$ref_path" ]]; then
        echo "preparing reference $tree_sha..."
        build_reference "$repo" "$branch" "$ref_path"
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

    overlay_mount "$ref_path" "$sdir/upper" "$sdir/workdir" "$mountpoint" \
        || die "overlay mount failed"

    configure_worktree_stat "$repo" "$mountpoint"
    git -C "$mountpoint" update-index --refresh >/dev/null 2>&1 || true

    echo "session ready: $mountpoint"
    echo "  branch:    $branch"
    echo "  reference: $ref_path"
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

    check_mountpoint_free "$selected"

    sid=$(session_id_from_gitfile "$selected" || true)

    if is_mounted "$selected"; then
        overlay_umount "$selected" || die "umount failed: $selected"
    fi

    git -C "$repo" worktree remove --force "$selected"

    if [[ -n "$sid" ]]; then
        sdir=$(session_dir "$repo" "$sid")
        [[ -d "$sdir" ]] && run_as_root rm -rf "$sdir"
    fi

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

cmd_gc() {
    local repo
    repo=$(require_main_repo)
    local base
    base=$(repo_cache_dir "$repo")
    [[ -d "$base/ref" ]] || { echo "nothing to gc"; return 0; }

    local live_lowers
    live_lowers=$(live_overlay_lowerdirs | sort -u)

    local removed=0 ref
    while IFS= read -r -d '' ref; do
        if ! grep -Fxq "$ref" <<<"$live_lowers"; then
            echo "gc: $ref"
            run_as_root rm -rf "$ref"
            removed=$((removed + 1))
        fi
    done < <(find "$base/ref" -mindepth 1 -maxdepth 1 -type d -print0)

    echo "gc: removed $removed reference(s)"
}
