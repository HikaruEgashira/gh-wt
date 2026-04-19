#!/usr/bin/env bash

# Dependency linking for the `none` backend. Overlay backends share unchanged
# lower layers through the overlay itself; `none` has no such mechanism, so we
# symlink common build/dep dirs (node_modules, .venv, target, ...) back to the
# parent worktree. This reproduces the pre-overlay behaviour of gh-wt where a
# fresh branch inherited its sibling's installed dependencies for free.

# Languages are keyed off lockfiles/manifests so we only link directories the
# project actually uses. Keep this list conservative — each entry must be a
# path that is almost always gitignored, otherwise we risk shadowing tracked
# content on future checkouts.
deps_detect_lang_dirs() {
    local src="$1"
    local dirs=()
    [[ -f "$src/pnpm-lock.yaml" || -f "$src/yarn.lock" || -f "$src/package-lock.json" || -f "$src/package.json" ]] && dirs+=("node_modules")
    [[ -f "$src/uv.lock" || -f "$src/poetry.lock" || -f "$src/pyproject.toml" || -f "$src/requirements.txt" ]] && dirs+=(".venv")
    [[ -f "$src/Cargo.lock" || -f "$src/Cargo.toml" ]] && dirs+=("target")
    [[ -f "$src/go.mod" || -f "$src/go.sum" ]] && dirs+=("vendor")
    [[ -f "$src/Gemfile" || -f "$src/Gemfile.lock" ]] && dirs+=("vendor/bundle")
    [[ -f "$src/Package.swift" ]] && dirs+=(".build")
    [[ -f "$src/build.zig" || -f "$src/build.zig.zon" ]] && dirs+=("zig-cache" ".zig-cache")
    [[ -f "$src/deno.json" || -f "$src/deno.jsonc" || -f "$src/deno.lock" ]] && dirs+=("deno_dir")

    [[ ${#dirs[@]} -eq 0 ]] && return 0
    printf '%s\n' "${dirs[@]}"
}

# Directories ignored by .gitignore are by definition not tracked, so linking
# them to the parent is safe. We only consider literal directory entries that
# already exist in the parent — wildcards/negations are skipped because they
# can't be resolved without a full ignore engine.
#
# We read .gitignore via `git show HEAD:.gitignore` rather than the working
# tree so this works with --no-checkout (async) worktrees too.
deps_detect_gitignore_dirs() {
    local worktree="$1" parent="$2"
    local content
    content=$(git -C "$worktree" show HEAD:.gitignore 2>/dev/null) || return 0
    [[ -n "$content" ]] || return 0

    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == \!* ]] && continue
        line="${line%/}"
        [[ "$line" == *[\*\?\[]* ]] && continue
        [[ "$line" == /* ]] && line="${line:1}"
        [[ -z "$line" ]] && continue
        [[ -d "$parent/$line" ]] && printf '%s\n' "$line"
    done <<<"$content"
}

# Link parent dep dirs into the worktree. Never clobbers an existing dst.
link_parent_deps() {
    local parent="$1" worktree="$2"
    [[ -d "$parent" && -d "$worktree" ]] || return 0

    local targets
    targets=$({
        deps_detect_lang_dirs "$parent"
        deps_detect_gitignore_dirs "$worktree" "$parent"
    } | sort -u)
    [[ -n "$targets" ]] || return 0

    local target src dst
    while IFS= read -r target; do
        [[ -z "$target" ]] && continue
        src="$parent/$target"
        dst="$worktree/$target"
        [[ -d "$src" ]] || continue
        [[ -e "$dst" || -L "$dst" ]] && continue
        [[ "$target" == */* ]] && mkdir -p "$(dirname "$dst")"
        ln -s "$src" "$dst" && echo "  linked $target -> parent"
    done <<<"$targets"
}
