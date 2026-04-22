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

# Returns the path of the worktree that currently has `refs/heads/<branch>`
# checked out, or empty if the branch is not checked out anywhere. We parse
# `git worktree list --porcelain` instead of `git config --file` because the
# linked-worktree config is not the source of truth for the checked-out
# branch — git's porcelain enumeration is.
_branch_in_use_worktree() {
    local repo="$1" branch="$2"
    git -C "$repo" worktree list --porcelain 2>/dev/null \
        | awk -v b="refs/heads/$branch" '
            /^worktree / { wt = substr($0, 10) }
            $0 == "branch " b { print wt; exit }
          '
}

# Atomic directory rename via rename(2). GNU `mv -T` isn't on macOS BSD mv;
# Perl's rename() is portable (ships in base macOS and every Linux distro)
# and uses renameat2/rename(2) underneath — replaces empty target dir,
# fails with ENOTEMPTY if a concurrent builder beat us to it.
_atomic_rename_dir() {
    perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"
}

# Returns 0 if the target dir's filesystem treats names case-insensitively
# (e.g. APFS default, HFS+ default). Result is memoised per parent dir.
_fs_is_case_insensitive() {
    local probe_dir="$1"
    mkdir -p "$probe_dir"
    local marker="$probe_dir/.gh-wt-case-probe.$$"
    rm -f "$marker" "${marker}_UPPER" 2>/dev/null
    : > "$marker"
    # If creating "$marker" makes "$marker_UPPER" appear too, the FS folds case.
    local upper="${marker}_UPPER"
    : > "$upper"
    local lower="${marker}_upper"
    local result=1
    if [[ -e "$lower" ]]; then result=0; fi
    rm -f "$marker" "$upper" 2>/dev/null
    return $result
}

# Refuse to build a reference whose tree contains paths that differ only
# in case when the cache dir is on a case-insensitive volume — tar would
# silently overwrite one with the other, leaving the worktree with the
# wrong content for at least one entry. linux/torvalds is the canonical
# example (xt_CONNMARK.h vs xt_connmark.h, and ~12 more pairs).
_check_case_collisions() {
    local repo="$1" tree_sha="$2" probe_dir="$3"
    if ! _fs_is_case_insensitive "$probe_dir"; then
        return 0
    fi
    local dupes
    dupes=$(git -C "$repo" ls-tree -r --name-only "$tree_sha" \
        | awk '{ orig=$0; lc=tolower($0); if (seen[lc]++) print orig }' \
        | head -5)
    if [[ -n "$dupes" ]]; then
        local count
        count=$(git -C "$repo" ls-tree -r --name-only "$tree_sha" \
            | awk '{ lc=tolower($0); if (seen[lc]++) c++ } END { print c+0 }')
        die "tree $tree_sha has $count case-duplicate path(s) on this case-insensitive volume; refusing to build a corrupt reference. Examples:
$dupes"
    fi
}

build_reference() {
    local repo="$1" tree_sha="$2" ref_path="$3"
    _check_case_collisions "$repo" "$tree_sha" "$(dirname "$ref_path")"
    local tmp="${ref_path}.tmp.$$"
    local idx="${ref_path}.idx.$$"
    rm -rf "$tmp" "$idx"
    mkdir -p "$tmp"
    # Populate a disposable index from the tree, then materialise it via
    # checkout-index. Cheaper than `git archive | tar` (no pack → tar → untar
    # round-trip) and honours the caseful names stored in the tree — tar's
    # extractor would silently collapse case-fold pairs on APFS/HFS+, while
    # checkout-index writes exactly the bytes git records. The upstream
    # case-collision scan (_check_case_collisions) is still the fail-fast
    # guard because checkout-index itself reports no error on overwrite.
    if ! GIT_INDEX_FILE="$idx" git -C "$repo" read-tree "$tree_sha" \
        || ! GIT_INDEX_FILE="$idx" git -C "$repo" \
               checkout-index --all --prefix="$tmp/"; then
        rm -rf "$tmp" "$idx"
        return 1
    fi
    rm -f "$idx"
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

_usage_add() {
    die "usage: gh wt add [--new|-b] <branch> [path]"
}

# Decide whether to materialise a branch that neither exists locally nor
# matches a remote-tracking ref. Silent creation from HEAD is a footgun
# (typo 'mian' → new branch 'mian'); require explicit opt-in via flag,
# env var, or interactive [y/N] confirmation on a TTY.
_confirm_new_branch() {
    local branch="$1" allow_new="$2"
    [[ "$allow_new" -eq 1 ]] && return 0
    [[ "${GH_WT_ASSUME_NEW:-}" == "1" ]] && return 0
    if [[ -t 0 && -t 2 ]]; then
        local reply
        printf "[gh-wt] branch '%s' does not exist. Create new from HEAD? [y/N] " \
            "$branch" >&2
        read -r reply || reply=""
        case "$reply" in
            y|Y|yes|YES|Yes) return 0 ;;
        esac
    fi
    return 1
}

cmd_add() {
    local branch="" mountpoint="" allow_new=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --new|-b) allow_new=1; shift ;;
            --) shift
                # End-of-options marker: remaining argv are positionals,
                # filling whichever positional slots are still empty. Must
                # not clobber a branch already supplied before `--` —
                # `gh wt add foo -- bar` means branch=foo, mountpoint=bar,
                # not the other way around.
                while [[ $# -gt 0 ]]; do
                    if [[ -z "$branch" ]]; then branch="$1"
                    elif [[ -z "$mountpoint" ]]; then mountpoint="$1"
                    else _usage_add
                    fi
                    shift
                done
                break
                ;;
            -*) die "unknown flag: $1 (usage: gh wt add [--new|-b] <branch> [path])" ;;
            *)
                if [[ -z "$branch" ]]; then branch="$1"
                elif [[ -z "$mountpoint" ]]; then mountpoint="$1"
                else _usage_add
                fi
                shift
                ;;
        esac
    done
    [[ -n "$branch" ]] || _usage_add

    local repo
    repo=$(require_main_repo)
    check_repo_sanity "$repo"

    local kind
    kind=$(resolve_branch "$repo" "$branch")

    # Block silent branch creation *before* any other work: if the user
    # typo'd a branch name and hits a non-interactive shell, we'd rather
    # die with a hint than create 'mian' from HEAD and build its cache.
    if [[ "$kind" == "new" ]]; then
        _confirm_new_branch "$branch" "$allow_new" || die \
"branch '$branch' does not exist locally or on origin.
Pass --new to create it from HEAD, set GH_WT_ASSUME_NEW=1 for scripted use, or check for a typo."
    fi

    # Fail fast on preconditions that `git worktree add` would reject later
    # anyway. Doing this *before* `build_reference` keeps ~$(du ref) of cache
    # bytes from being written for a run that was never going to succeed
    # (e.g. branch already checked out in another worktree).
    if [[ "$kind" == "local" ]]; then
        local in_use
        in_use=$(_branch_in_use_worktree "$repo" "$branch")
        if [[ -n "$in_use" ]]; then
            die "branch '$branch' is already checked out at $in_use"
        fi
    fi

    [[ -n "$mountpoint" ]] || mountpoint=$(default_mountpoint "$repo" "$branch")
    mountpoint=$(canonical_path "$mountpoint")
    [[ ! -e "$mountpoint" ]] || die "mountpoint already exists: $mountpoint"

    case "$kind" in
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
        # Parallelism: APFS spine-lock contention is per-parent-dir; spreading
        # top-level entries across workers gives ~1.7× speedup at P=4 on M3
        # (measured), with diminishing/negative returns past the P-core count.
        # Override via GH_WT_CLONE_PARALLELISM=N (1 = serial, useful for
        # debugging or single-core hosts).
        local par="${GH_WT_CLONE_PARALLELISM:-4}"
        if ! find "$ref_path" -mindepth 1 -maxdepth 1 -print0 \
            | xargs -0 -n 1 -P "$par" -I{} cp -cRp '{}' "$mountpoint/"; then
            git -C "$repo" worktree remove --force "$mountpoint" >/dev/null 2>&1 || true
            rm -rf "$mountpoint"
            die "apfs clone failed (is $mountpoint on the same APFS volume as $ref_path?)"
        fi

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
    # --select-1 short-circuits fzf when there's only one candidate (no
    # UI, no /dev/tty open) — covers the 80 % daily case where the user
    # has just one worktree besides main, or an --at would be redundant.
    # --exit-0 mirrors the empty-list guard above defensively.
    fzf --prompt="$prompt" --select-1 --exit-0 <<<"$list"
}

# Bail with a helpful error when select_session cannot prompt — set when
# stdin is not a TTY (CI, nohup, agent-driven shells like Claude Code)
# or the user has explicitly opted out via GH_WT_NONINTERACTIVE=1. Prints
# the candidate list so the caller can re-invoke with --at <branch|path>.
_require_interactive_or_die() {
    local repo="$1"
    if [[ "${GH_WT_NONINTERACTIVE:-}" == "1" ]]; then
        {
            echo "gh-wt: GH_WT_NONINTERACTIVE=1 — refusing to spawn fzf."
            echo "candidate worktrees (pass --at <branch|path> to pick):"
            git -C "$repo" worktree list --porcelain 2>/dev/null \
                | awk '/^worktree / { print "  " substr($0, 10) }'
        } >&2
        exit 2
    fi
}

_list_worktree_paths() {
    git -C "$1" worktree list --porcelain \
        | awk '/^worktree / { print substr($0, 10) }'
}

# Match user input against an existing linked worktree. Accepts:
#   - an absolute or relative path to the worktree root
#   - a branch name whose linked worktree is registered
# Returns 0 and echoes the canonical registered path on match, else 1.
resolve_worktree_arg() {
    local repo="$1" arg="$2"
    [[ -n "$arg" ]] || return 1

    local candidate
    if [[ "$arg" == /* || "$arg" == ./* || "$arg" == ../* || -e "$arg" ]]; then
        candidate=$(canonical_path "$arg" 2>/dev/null || true)
    fi

    local wt
    while IFS= read -r wt; do
        [[ -n "$wt" ]] || continue
        if [[ -n "${candidate:-}" && "$wt" == "$candidate" ]]; then
            echo "$wt"; return 0
        fi
        if [[ -f "$wt/.git" ]] || [[ -d "$wt/.git" ]]; then
            local br
            br=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
            if [[ -n "$br" && "$br" == "$arg" ]]; then
                echo "$wt"; return 0
            fi
        fi
    done < <(_list_worktree_paths "$repo")
    return 1
}

cmd_remove() {
    local repo selected sid sdir arg="${1:-}"
    repo=$(require_main_repo)
    if [[ -n "$arg" ]]; then
        selected=$(resolve_worktree_arg "$repo" "$arg") \
            || die "no registered worktree matches: $arg"
    else
        _require_interactive_or_die "$repo"
        selected=$(select_session "$repo" "remove: ") || return 0
    fi
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
    local target="${1:-}"; shift || true
    local repo selected
    repo=$(require_main_repo)
    if [[ -n "$target" ]]; then
        selected=$(resolve_worktree_arg "$repo" "$target") \
            || die "no registered worktree matches: $target"
    else
        _require_interactive_or_die "$repo"
        selected=$(select_session "$repo") || return 0
    fi
    [[ -n "$selected" ]] || return 0
    cd "$selected" || die "cannot cd into $selected"
    exec "$@"
}

cmd_exec_with() {
    local target="${1:-}"; shift || true
    local repo selected
    repo=$(require_main_repo)
    if [[ -n "$target" ]]; then
        selected=$(resolve_worktree_arg "$repo" "$target") \
            || die "no registered worktree matches: $target"
    else
        _require_interactive_or_die "$repo"
        selected=$(select_session "$repo") || return 0
    fi
    [[ -n "$selected" ]] || return 0
    exec "$@" "$selected"
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
