
# ─── Matrix theme kit ───
export PATH="$HOME/.local/bin:$PATH"
alias matrix="python3 ~/.claude/matrix-rain.py"

# ─── Matrix theme (added 2026-08-29; backup: ~/.zshrc.pre-matrix) ───
# Green prompt: user@matrix ~/path (git-branch) ❯
autoload -Uz vcs_info add-zsh-hook
zstyle ':vcs_info:git:*' formats ' %F{28}(%b)%f'
_matrix_vcs() { vcs_info }
add-zsh-hook precmd _matrix_vcs
setopt PROMPT_SUBST
PROMPT=$'%F{46}%n@matrix%f %F{40}%~%f${vcs_info_msg_0_}\n%F{82}❯%f '

# Green file listings & previews
if command -v eza >/dev/null; then
  alias ls="eza"
  alias ll="eza -la --git"
  alias tree="eza --tree"
  export EZA_COLORS="di=1;32:ln=36:ex=1;92:ur=32:uw=32:ux=92:gr=2;32:gw=2;32:gx=2;32:tr=2;32:tw=2;32:tx=2;32:sn=32:sb=2;32:uu=2;32:gu=2;32:da=2;32"
else
  # green-tinted BSD ls (eza has no macOS build yet — swap in later via brew)
  export LSCOLORS="Cxcxcxcxcxcxcxcxcxcxcx"
  alias ll="ls -laG"
fi
if command -v bat >/dev/null; then
  alias cat="bat --paging=never"
  export BAT_THEME="ansi"   # inherits the terminal's Matrix palette
fi
export CLICOLOR=1
command -v cmatrix >/dev/null && alias rain="cmatrix -ab"

# Wake up, Neo — typed greeting in new terminal windows
if [[ -o interactive && -t 1 && -z "$MATRIX_GREETED" ]]; then
  export MATRIX_GREETED=1
  _mq=(
    "Wake up, Neo..."
    "The Matrix has you..."
    "Follow the white rabbit."
    "Knock, knock, Neo."
    "There is no spoon."
    "Free your mind."
    "Welcome to the desert of the real."
    "I know kung fu."
    "Unfortunately, no one can be told what the Matrix is."
  )
  _q=${_mq[$((RANDOM % ${#_mq[@]} + 1))]}
  printf '\033[1;32m'
  for ((_i=1; _i<=${#_q}; _i++)); do printf '%s' "${_q[_i]}"; sleep 0.025; done
  printf '\033[0m\n\n'
  unset _q _mq _i
fi
