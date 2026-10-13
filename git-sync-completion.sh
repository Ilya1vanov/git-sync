# git-sync shell completion with descriptions ("hints") for bash and zsh.
# bash: add to ~/.bashrc:                 . /path/to/git-sync-completion.sh
# zsh:  add to ~/.zshrc after compinit:   . /path/to/git-sync-completion.sh

# ---- hints (shared by both shells) ----

# __git_sync_hint WORD DESC: prints one candidate line.
__git_sync_hint() { printf '%s\t%s\n' "$1" "$2"; }

# __git_sync_repos: one candidate per registered repo; silent if not initialized.
__git_sync_repos() {
  local r
  git config -f "${GIT_SYNC_HOME:-$HOME/.git-sync}/config" --get-all sync.repo 2>/dev/null |
    while IFS= read -r r; do __git_sync_hint "$r" "registered repo"; done
}

# __git_sync_keys: settable config keys (sync.repo is managed by install/uninstall).
__git_sync_keys() {
  __git_sync_hint sync.period "Agent run interval (global)"
  __git_sync_hint sync.mode "What a sync does"
  __git_sync_hint sync.branches "Branches to fast-forward"
  __git_sync_hint sync.ffCheckedOut "Fast-forward checked-out branches too"
  __git_sync_hint sync.jobs "Repos synced in parallel (global)"
  __git_sync_hint sync.jitter "Random delay before each repo (global)"
  __git_sync_hint log.maxSize "Log rotation size (global)"
  __git_sync_hint notify.enabled "Send notifications (global)"
  __git_sync_hint notify.events "Events that notify (global)"
}

# __git_sync_values KEY: value candidates, or an @msg hint for free-form values.
__git_sync_values() {
  case $1 in
    sync.mode)
      __git_sync_hint maintain-only "Only housekeeping"
      __git_sync_hint maintain-and-fetch "Fetch all remotes, then housekeeping"
      __git_sync_hint fast-forward "Fetch, fast-forward selected branches, housekeeping" ;;
    sync.ffCheckedOut|notify.enabled)
      __git_sync_hint true "Enable"
      __git_sync_hint false "Disable" ;;
    notify.events)
      __git_sync_hint blocked "A repo gained a new blocker"
      __git_sync_hint finished "Run summary counts" ;;
    sync.period) __git_sync_hint @msg "number with optional s/m/h, at least 60s (e.g. 20m)" ;;
    sync.branches) __git_sync_hint @msg "space-separated branch names" ;;
    sync.jobs) __git_sync_hint @msg "repos synced in parallel, 1-64" ;;
    sync.jitter) __git_sync_hint @msg "max random delay in seconds, 0-60" ;;
    log.maxSize) __git_sync_hint @msg "number with optional K/M/G (e.g. 3M)" ;;
  esac
}

# __git_sync_hints WORD...: WORDs are the words after "git-sync", excluding the
# one being completed. Prints one hint per line, unfiltered:
#   <word><TAB><description>   candidate
#   @dirs                      complete directory paths
#   @msg<TAB><text>            free-form value; show <text>
__git_sync_hints() {
  local cmd a key= npos=0 has_unset=0
  if [ $# -eq 0 ]; then
    __git_sync_hint init "Create ~/.git-sync with default config"
    __git_sync_hint install "Add a repo (default: current) to the sync list"
    __git_sync_hint uninstall "Remove a repo from the sync list"
    __git_sync_hint list "List synced repos"
    __git_sync_hint status "Show agent state and per-repo sync status"
    __git_sync_hint start "Install and load the launchd agent"
    __git_sync_hint stop "Unload and remove the launchd agent"
    __git_sync_hint config "Show or change configuration"
    __git_sync_hint sync "Sync the current (or given) repo, or all listed repos"
    __git_sync_hint notifications "Show or toggle notifications"
    __git_sync_hint help "Show help"
    return 0
  fi
  cmd=$1; shift
  case $cmd in
    install)
      if [ $# -eq 0 ]; then
        __git_sync_hint -r "Add every repo directly inside <dir>"
        echo @dirs
      elif [ $# -eq 1 ] && [ "$1" = -r ]; then
        echo @dirs
      fi ;;
    uninstall)
      if [ $# -eq 0 ]; then __git_sync_repos; fi ;;
    sync)
      if [ $# -eq 0 ]; then
        __git_sync_hint --all "Sync every listed repo"
        __git_sync_repos
      fi ;;
    status)
      case " $* " in *" -v "*|*" --verbose "*) ;; *) __git_sync_hint --verbose "Full per-repo detail" ;; esac
      case " $* " in *" -l "*|*" --list-order "*) ;; *) __git_sync_hint --list-order "Keep sync-list order" ;; esac ;;
    config)
      for a in "$@"; do
        case $a in
          --unset) has_unset=1 ;;
          -*) ;;
          *) npos=$((npos + 1)); if [ "$npos" -eq 1 ]; then key=$a; fi ;;
        esac
      done
      if [ "$npos" -eq 0 ]; then
        case " $* " in *" --global "*) ;; *) __git_sync_hint --global "Global config, not this repo" ;; esac
        case " $* " in *" --force "*) ;; *) __git_sync_hint --force "Allow unknown keys" ;; esac
        case " $* " in *" --unset "*) ;; *) __git_sync_hint --unset "Revert key to the next level" ;; esac
        __git_sync_keys
      elif [ "$npos" -eq 1 ] && [ "$has_unset" -eq 0 ]; then
        __git_sync_values "$key"
      fi ;;
    notifications)
      if [ $# -eq 0 ]; then
        __git_sync_hint enable "Turn notifications on"
        __git_sync_hint disable "Turn notifications off"
      fi ;;
  esac
  return 0
}

# ---- shell frontends ----
if [ -n "${ZSH_VERSION-}" ]; then
  :
elif [ -n "${BASH_VERSION-}" ]; then
  # Several matches are listed as "word  -- description"; a single match is
  # inserted bare. Empty COMPREPLY falls back to filenames (-o default).
  _git_sync() {
    local cur=${COMP_WORDS[COMP_CWORD]} line word max=0 dirs=0 i
    local -a words=() descs=()
    while IFS= read -r line; do
      case $line in
        @dirs) dirs=1 ;;
        @msg*) ;;
        *)
          printf -v word '%q' "${line%%$'\t'*}"
          [[ $word == "$cur"* ]] || continue
          words+=("$word"); descs+=("${line#*$'\t'}")
          if (( ${#word} > max )); then max=${#word}; fi ;;
      esac
    done < <(__git_sync_hints "${COMP_WORDS[@]:1:COMP_CWORD-1}")
    COMPREPLY=()
    if (( dirs )) && [[ $cur != -* ]]; then return 0; fi
    if (( ${#words[@]} == 1 )); then COMPREPLY=("${words[0]}"); return 0; fi
    for i in "${!words[@]}"; do
      COMPREPLY+=("$(printf '%-*s  -- %s' "$max" "${words[i]}" "${descs[i]}")")
    done
  }
  complete -o default -F _git_sync git-sync
fi
