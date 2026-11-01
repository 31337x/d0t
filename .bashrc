# ~/.bashrc

# Add local commands to PATH once.
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# Interactive shells only below this line.
[[ $- == *i* ]] || return 0
[[ -f /etc/bashrc ]] && . /etc/bashrc

# History.
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth:erasedups
HISTTIMEFORMAT='%F %T '
shopt -s histappend checkwinsize
_bashrc_history_sync() { history -a; history -n; }
[[ ";${PROMPT_COMMAND[*]};" == *'_bashrc_history_sync'* ]] || PROMPT_COMMAND+=(_bashrc_history_sync)

# Readline / terminal basics.
bind 'set bell-style none'
bind 'set completion-ignore-case on'
bind 'set show-all-if-ambiguous on'
[[ -t 0 ]] && stty -ixon

export EDITOR=hx
export VISUAL="$EDITOR"

# Safe/common aliases.
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'
alias mkdir='mkdir -p'
alias ls='ls -Fh --color=auto'
alias ll='ls -lh'
alias la='ls -Alh'
alias grep='grep --color=auto'
alias less='less -R'
alias cls='clear'
alias ..='cd ..'
alias ...='cd ../..'
alias ebrc='$EDITOR "$HOME/.bashrc"'

# Fuzzy file picker: preview files, then open the selection in Helix.
ff() {
    local selected_file
    selected_file=$(fzf --preview 'bat --style=numbers --color=always -- {}') || return
    [[ -n $selected_file ]] && hx -- "$selected_file"
}

# Startup system summary.
[[ -t 1 ]] && command -v fastfetch >/dev/null 2>&1 && fastfetch

command -v starship >/dev/null 2>&1 && eval "$(starship init bash)"

# Shell integrations.
fzf_theme="${XDG_CONFIG_HOME:-$HOME/.config}/fzf/themes/noctalia.sh"
[[ ! -r $fzf_theme ]] || source "$fzf_theme"
unset fzf_theme
command -v fzf >/dev/null 2>&1 && eval "$(fzf --bash)"
if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init bash)"
    bind '"\C-f":"zi\n"'
fi
