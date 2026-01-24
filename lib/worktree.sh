#!/usr/bin/env bash

get_current_repo() {
    local current_dir="$(pwd)"
    local ghq_root="$HOME/ghq/github.com"

    if [[ "$current_dir" == "$ghq_root"* ]]; then
        local relative_path="${current_dir#$ghq_root/}"
        local repo_path=$(echo "$relative_path" | cut -d'/' -f1-2)
        echo "$ghq_root/$repo_path"
    fi
}

require_current_repo() {
    local repo
    if repo=$(get_current_repo) && [ -n "$repo" ]; then
        echo "$repo"
    else
        echo "Error: Not in a git repository" >&2
        exit 1
    fi
}

select_worktree() {
    local repo="$1"
    local prompt="${2:-Select worktree: }"
    local temp_file selected

    temp_file=$(mktemp)
    trap "rm -f '$temp_file'" RETURN

    (cd "$repo" && git worktree list --porcelain 2>/dev/null | grep "^worktree " | sed 's/^worktree //' >> "$temp_file") || true

    if [ ! -s "$temp_file" ]; then
        echo "No worktrees found" >&2
        return 1
    fi

    selected=$(cat "$temp_file" | fzf --prompt="$prompt" || true)
    echo "$selected"
}

add_worktree_for_branch() {
    local repo="$1"
    local branch="$2"
    local worktree_path="$3"
    local create_if_missing="${4:-true}"

    if (cd "$repo" && git show-ref --verify --quiet refs/heads/"$branch"); then
        # Local branch exists
        (cd "$repo" && git worktree add "$worktree_path" "$branch")
    elif (cd "$repo" && git show-ref --verify --quiet refs/remotes/origin/"$branch"); then
        # Remote branch exists, create local tracking branch
        (cd "$repo" && git worktree add "$worktree_path" -b "$branch" "origin/$branch")
    elif [ "$create_if_missing" = "true" ]; then
        # Branch doesn't exist, create new branch
        (cd "$repo" && git worktree add "$worktree_path" -b "$branch")
    else
        echo "Error: Branch '$branch' not found locally or remotely" >&2
        return 1
    fi
}
