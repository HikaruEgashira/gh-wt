# Fish completion for gh-wt

function __gh_wt_get_repo
    set -l current_dir (pwd)
    set -l ghq_root "$HOME/ghq/github.com"
    if string match -q "$ghq_root*" "$current_dir"
        set -l relative_path (string replace "$ghq_root/" "" "$current_dir")
        set -l repo_path (string split '/' "$relative_path" | head -2 | string join '/')
        echo "$ghq_root/$repo_path"
    end
end

function __gh_wt_branches
    set -l repo (__gh_wt_get_repo)
    test -z "$repo"; and return
    cd "$repo"; and git branch -a --format='%(refname:short)' 2>/dev/null | sed 's|^origin/||' | sort -u
end

function __gh_wt_worktrees
    set -l repo (__gh_wt_get_repo)
    test -z "$repo"; and return
    cd "$repo"; and git worktree list --porcelain 2>/dev/null | grep "^worktree " | sed 's/^worktree //'
end

function __gh_wt_needs_command
    set -l cmd (commandline -opc)
    test (count $cmd) -eq 1
end

function __gh_wt_using_command
    set -l cmd (commandline -opc)
    if test (count $cmd) -gt 1
        if test "$argv[1]" = "$cmd[2]"
            return 0
        end
    end
    return 1
end

# Disable file completion by default
complete -c gh-wt -f

# Subcommands
complete -c gh-wt -n __gh_wt_needs_command -a list -d 'List git worktrees in current repository'
complete -c gh-wt -n __gh_wt_needs_command -a add -d 'Add a new worktree for a branch'
complete -c gh-wt -n __gh_wt_needs_command -a remove -d 'Remove a worktree (interactive)'
complete -c gh-wt -n __gh_wt_needs_command -a rm -d 'Remove a worktree (interactive)'
complete -c gh-wt -n __gh_wt_needs_command -a co -d 'Checkout a PR as a new worktree'
complete -c gh-wt -n __gh_wt_needs_command -a -- -d 'Run command inside selected worktree directory'
complete -c gh-wt -n __gh_wt_needs_command -a completion -d 'Output shell completion script'

# Common commands (shortcuts)
complete -c gh-wt -n __gh_wt_needs_command -a cd -d 'Change to worktree directory'
complete -c gh-wt -n __gh_wt_needs_command -a code -d 'Open worktree in VS Code'
complete -c gh-wt -n __gh_wt_needs_command -a nvim -d 'Open worktree in Neovim'
complete -c gh-wt -n __gh_wt_needs_command -a vim -d 'Open worktree in Vim'

# Branch completion for 'add' command
complete -c gh-wt -n '__gh_wt_using_command add' -a '(__gh_wt_branches)' -d 'Branch'

# Worktree completion for 'remove' and 'rm' commands
complete -c gh-wt -n '__gh_wt_using_command remove' -a '(__gh_wt_worktrees)' -d 'Worktree'
complete -c gh-wt -n '__gh_wt_using_command rm' -a '(__gh_wt_worktrees)' -d 'Worktree'

# Shell completion for 'completion' command
complete -c gh-wt -n '__gh_wt_using_command completion' -a 'bash zsh fish' -d 'Shell'
