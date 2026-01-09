#compdef gh-wt

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

_gh_wt() {
    local -a subcommands
    subcommands=(
        'list:List git worktrees in current repository'
        'add:Add a new worktree for a branch'
        'remove:Remove a worktree (interactive)'
        'rm:Remove a worktree (interactive)'
        '--:Run command inside selected worktree directory'
        'completion:Output shell completion script'
    )

    local -a common_commands
    common_commands=(
        'cd:Change to worktree directory'
        'code:Open worktree in VS Code'
        'nvim:Open worktree in Neovim'
        'vim:Open worktree in Vim'
    )

    _arguments -C \
        '1:command:->command' \
        '*::arg:->args'

    case "$state" in
        command)
            _describe -t subcommands 'subcommand' subcommands
            _describe -t commands 'common command' common_commands
            ;;
        args)
            case "$words[1]" in
                add)
                    case "$CURRENT" in
                        2)
                            local -a branches
                            branches=(${(f)"$(_gh_wt_branches)"})
                            _describe -t branches 'branch' branches
                            ;;
                        3)
                            _files -/
                            ;;
                    esac
                    ;;
                remove|rm)
                    local -a worktrees
                    worktrees=(${(f)"$(_gh_wt_worktrees)"})
                    _describe -t worktrees 'worktree' worktrees
                    ;;
                --)
                    _command_names
                    ;;
                completion)
                    local -a shells
                    shells=('bash:Bash completion' 'zsh:Zsh completion')
                    _describe -t shells 'shell' shells
                    ;;
                *)
                    local -a worktrees
                    worktrees=(${(f)"$(_gh_wt_worktrees)"})
                    _describe -t worktrees 'worktree' worktrees
                    ;;
            esac
            ;;
    esac
}

_gh_wt "$@"
