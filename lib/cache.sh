#!/usr/bin/env bash
# gh-wt cache system
# Automatically detect and restore dependencies when creating worktrees

get_cache_dir() {
    echo "${XDG_CACHE_HOME:-$HOME/.cache}/gh-wt"
}

compute_hash() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | cut -d' ' -f1 | head -c 12
    else
        shasum -a 256 "$file" | cut -d' ' -f1 | head -c 12
    fi
}

parse_toml_bool() {
    local file="$1"
    local key="$2"
    local default="$3"
    local value
    value=$(grep "^${key}\s*=" "$file" 2>/dev/null | sed 's/.*=\s*//' | tr -d ' "'"'" | tr '[:upper:]' '[:lower:]')
    if [[ -z "$value" ]]; then
        echo "$default"
    elif [[ "$value" == "false" || "$value" == "0" ]]; then
        echo "false"
    else
        echo "true"
    fi
}

detect_package_manager() {
    local dir="$1"

    # Node.js (priority: pnpm > yarn > npm)
    if [[ -f "$dir/pnpm-lock.yaml" ]]; then
        echo "nodejs:pnpm:pnpm-lock.yaml:node_modules"
        return 0
    elif [[ -f "$dir/yarn.lock" ]]; then
        echo "nodejs:yarn:yarn.lock:node_modules"
        return 0
    elif [[ -f "$dir/package-lock.json" ]]; then
        echo "nodejs:npm:package-lock.json:node_modules"
        return 0
    fi

    # Python
    if [[ -f "$dir/uv.lock" ]]; then
        echo "python:uv:uv.lock:.venv"
        return 0
    elif [[ -f "$dir/poetry.lock" ]]; then
        echo "python:poetry:poetry.lock:.venv"
        return 0
    elif [[ -f "$dir/requirements.txt" ]]; then
        echo "python:pip:requirements.txt:.venv"
        return 0
    fi

    # Rust
    if [[ -f "$dir/Cargo.lock" ]]; then
        echo "rust:cargo:Cargo.lock:target"
        return 0
    fi

    # Go (uses global cache, no symlink needed)
    if [[ -f "$dir/go.sum" ]]; then
        echo "go:gomod:go.sum:"
        return 0
    fi

    return 1
}

restore_from_cache() {
    local worktree_path="$1"
    local cache_path="$2"
    local target_dir="$3"

    [[ -z "$target_dir" ]] && return 0

    local src="$cache_path/$target_dir"
    local dst="$worktree_path/$target_dir"

    if [[ -d "$src" ]]; then
        ln -s "$src" "$dst"
        return 0
    fi
    return 1
}

install_and_cache() {
    local worktree_path="$1"
    local lang="$2"
    local pm="$3"
    local lockfile="$4"
    local target_dir="$5"

    local hash
    hash=$(compute_hash "$worktree_path/$lockfile")
    local cache_path
    cache_path="$(get_cache_dir)/$lang/$hash"

    echo "  Installing dependencies with $pm..."
    (
        cd "$worktree_path" || exit 1
        case "$pm" in
            npm)    npm ci --silent 2>/dev/null || npm install --silent ;;
            yarn)   yarn install --frozen-lockfile --silent 2>/dev/null || yarn install --silent ;;
            pnpm)   pnpm install --frozen-lockfile --silent 2>/dev/null || pnpm install --silent ;;
            uv)     uv sync --quiet ;;
            poetry) poetry install --quiet ;;
            pip)    python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt ;;
            cargo)  cargo fetch --quiet ;;
            gomod)  go mod download ;;
        esac
    )

    # Cache for languages with local target directories
    if [[ -n "$target_dir" && -d "$worktree_path/$target_dir" ]]; then
        mkdir -p "$cache_path"
        mv "$worktree_path/$target_dir" "$cache_path/$target_dir"
        ln -s "$cache_path/$target_dir" "$worktree_path/$target_dir"
        echo "  Cached $target_dir"
    fi
}

run_custom_setup() {
    local worktree_path="$1"
    local config_file="$worktree_path/.gh-wt.toml"

    [[ ! -f "$config_file" ]] && return 0

    # Extract commands from [setup] section
    local in_setup=false
    local cmd
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[setup\] ]]; then
            in_setup=true
            continue
        elif [[ "$line" =~ ^\[.*\] ]]; then
            in_setup=false
            continue
        fi

        if $in_setup && [[ "$line" =~ ^commands ]]; then
            # Extract command strings from array
            while IFS= read -r cmd_line; do
                cmd=$(echo "$cmd_line" | sed -n 's/.*"\([^"]*\)".*/\1/p')
                if [[ -n "$cmd" ]]; then
                    echo "  Running: $cmd"
                    (cd "$worktree_path" && eval "$cmd")
                fi
            done
        fi
    done < "$config_file"
}

setup_worktree() {
    local worktree_path="$1"

    # Check if cache is disabled in .gh-wt.toml
    local config_file="$worktree_path/.gh-wt.toml"
    if [[ -f "$config_file" ]]; then
        local enabled
        enabled=$(parse_toml_bool "$config_file" "enabled" "true")
        if [[ "$enabled" == "false" ]]; then
            return 0
        fi
    fi

    echo "Setting up worktree..."

    local detection
    if detection=$(detect_package_manager "$worktree_path"); then
        IFS=':' read -r lang pm lockfile target_dir <<< "$detection"

        echo "  Detected: $lang ($pm)"

        local hash
        hash=$(compute_hash "$worktree_path/$lockfile")
        local cache_path
        cache_path="$(get_cache_dir)/$lang/$hash"

        if [[ -d "$cache_path/$target_dir" ]] && [[ -n "$target_dir" ]]; then
            restore_from_cache "$worktree_path" "$cache_path" "$target_dir"
            echo "  Restored $target_dir from cache"
        else
            install_and_cache "$worktree_path" "$lang" "$pm" "$lockfile" "$target_dir"
        fi
    fi

    run_custom_setup "$worktree_path"
}
