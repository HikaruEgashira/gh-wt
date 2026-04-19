#!/usr/bin/env bash

require_main_repo() {
    local common_dir toplevel
    if ! common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
        echo "Error: not inside a git repository" >&2
        exit 1
    fi
    toplevel="${common_dir%/.git}"
    if [[ "$toplevel" == "$common_dir" ]]; then
        echo "Error: bare repositories are not supported" >&2
        exit 1
    fi
    if [[ ! -d "$toplevel" ]]; then
        echo "Error: could not locate main worktree root ($toplevel)" >&2
        exit 1
    fi
    printf '%s\n' "$toplevel"
}

select_worktree() {
    local repo="$1"
    local prompt="${2:-Select worktree: }"
    local list selected

    list=$(cd "$repo" && git worktree list --porcelain 2>/dev/null \
        | awk '/^worktree /{sub(/^worktree /, ""); print}')

    if [[ -z "$list" ]]; then
        echo "No worktrees found" >&2
        return 1
    fi

    selected=$(printf '%s\n' "$list" | fzf --prompt="$prompt" || true)
    [[ -z "$selected" ]] && return 1
    printf '%s\n' "$selected"
}
