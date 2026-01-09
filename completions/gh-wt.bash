_gh_wt() {
    local cur prev words cword
    _init_completion 2>/dev/null || {
        COMPREPLY=()
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
    }

    local subcommands="list add remove rm -- completion"
    local common_commands="cd code nvim vim"

    _gh_wt_get_repo() {
        local current_dir="$(pwd)"
        local ghq_root="$HOME/ghq/github.com"
        if [[ "$current_dir" == "$ghq_root"* ]]; then
            local relative_path="${current_dir#$ghq_root/}"
            local repo_path=$(echo "$relative_path" | cut -d'/' -f1-2)
            echo "$ghq_root/$repo_path"
        fi
    }

    _gh_wt_branches() {
        local repo=$(_gh_wt_get_repo)
        [[ -z "$repo" ]] && return
        (cd "$repo" && git branch -a --format='%(refname:short)' 2>/dev/null | sed 's|^origin/||' | sort -u)
    }

    _gh_wt_worktrees() {
        local repo=$(_gh_wt_get_repo)
        [[ -z "$repo" ]] && return
        (cd "$repo" && git worktree list --porcelain 2>/dev/null | grep "^worktree " | sed 's/^worktree //')
    }

    case "${prev}" in
        add)
            local branches=$(_gh_wt_branches)
            COMPREPLY=($(compgen -W "${branches}" -- "${cur}"))
            return
            ;;
        remove|rm)
            local worktrees=$(_gh_wt_worktrees)
            COMPREPLY=($(compgen -W "${worktrees}" -- "${cur}"))
            return
            ;;
        --)
            COMPREPLY=($(compgen -W "${common_commands}" -- "${cur}"))
            COMPREPLY+=($(compgen -c -- "${cur}"))
            return
            ;;
        completion)
            COMPREPLY=($(compgen -W "bash zsh fish" -- "${cur}"))
            return
            ;;
    esac

    if [[ ${cword} -eq 1 ]]; then
        COMPREPLY=($(compgen -W "${subcommands} ${common_commands}" -- "${cur}"))
        return
    fi

    if [[ ${cword} -eq 3 && "${words[1]}" == "add" ]]; then
        COMPREPLY=($(compgen -d -- "${cur}"))
        return
    fi
}

complete -F _gh_wt gh-wt
