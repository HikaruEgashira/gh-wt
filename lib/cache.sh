#!/usr/bin/env bash

get_parent_repo() {
    local git_dir
    git_dir=$(git -C "$1" rev-parse --git-dir 2>/dev/null) || return 1
    [[ "$git_dir" == *"/worktrees/"* ]] || return 1
    local p="${git_dir%/worktrees/*}"
    p="${p%.git}"
    echo "${p%/}"
}

detect_target_dirs() {
    local dirs=()
    # Node.js
    [[ -f "$1/pnpm-lock.yaml" || -f "$1/yarn.lock" || -f "$1/package-lock.json" || -f "$1/package.json" ]] && dirs+=("node_modules")
    # Python
    [[ -f "$1/uv.lock" || -f "$1/poetry.lock" || -f "$1/pyproject.toml" || -f "$1/requirements.txt" ]] && dirs+=(".venv")
    # Rust
    [[ -f "$1/Cargo.lock" || -f "$1/Cargo.toml" ]] && dirs+=("target")
    # Go
    [[ -f "$1/go.mod" || -f "$1/go.sum" ]] && dirs+=("vendor")
    # Ruby
    [[ -f "$1/Gemfile" || -f "$1/Gemfile.lock" ]] && dirs+=("vendor/bundle")
    # Swift
    [[ -f "$1/Package.swift" ]] && dirs+=(".build")
    # Zig
    [[ -f "$1/build.zig" || -f "$1/build.zig.zon" ]] && dirs+=("zig-cache" ".zig-cache")
    # Deno
    [[ -f "$1/deno.json" || -f "$1/deno.jsonc" || -f "$1/deno.lock" ]] && dirs+=("deno_dir")

    [[ ${#dirs[@]} -eq 0 ]] && return 1
    # Remove duplicates
    printf '%s\n' "${dirs[@]}" | sort -u
}

setup_worktree() {
    local parent=$(get_parent_repo "$1") || return 0
    local targets
    targets=$(detect_target_dirs "$1") || return 0

    local target
    while IFS= read -r target; do
        [[ -z "$target" ]] && continue
        local src="$parent/$target" dst="$1/$target"
        [[ -L "$dst" || ! -d "$src" ]] && continue
        # Create parent dir for nested paths like vendor/bundle
        [[ "$target" == */* ]] && mkdir -p "$(dirname "$dst")"
        [[ -d "$dst" ]] && rm -rf "$dst"
        ln -s "$src" "$dst" && echo "  Linked $target -> parent"
    done <<< "$targets"
}
