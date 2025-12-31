#!/usr/bin/env bash

get_parent_repo() {
    local git_dir
    git_dir=$(git -C "$1" rev-parse --git-dir 2>/dev/null) || return 1
    [[ "$git_dir" == *"/worktrees/"* ]] || return 1
    local p="${git_dir%/worktrees/*}"
    echo "${p%.git}"
}

detect_target_dir() {
    [[ -f "$1/pnpm-lock.yaml" || -f "$1/yarn.lock" || -f "$1/package-lock.json" || -f "$1/package.json" ]] && echo "node_modules" && return
    [[ -f "$1/uv.lock" || -f "$1/poetry.lock" || -f "$1/pyproject.toml" || -f "$1/requirements.txt" ]] && echo ".venv" && return
    [[ -f "$1/Cargo.lock" || -f "$1/Cargo.toml" ]] && echo "target" && return
    return 1
}

setup_worktree() {
    local parent=$(get_parent_repo "$1") || return 0
    local target=$(detect_target_dir "$1") || return 0
    local src="$parent/$target" dst="$1/$target"
    [[ -L "$dst" || ! -d "$src" ]] && return 0
    [[ -d "$dst" ]] && rm -rf "$dst"
    ln -s "$src" "$dst" && echo "  Linked $target -> parent"
}
