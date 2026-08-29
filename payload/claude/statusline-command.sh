#!/bin/bash
# Claude Code statusLine:
#   model | cwd | git branch | ctx/5h/7d katakana meters | code-rain tail

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // empty')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

# Show cwd relative to $HOME as ~
dir="${cwd/#$HOME/~}"

# Git branch + dirty marker, safe outside a git repo (no error output, no lock contention)
branch=""
dirty=""
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1 && \
   git --no-optional-locks -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git --no-optional-locks -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
  [ -z "$branch" ] && branch=$(git --no-optional-locks -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  if [ -n "$(git --no-optional-locks -C "$cwd" status --porcelain 2>/dev/null)" ]; then
    dirty="*"
  fi
fi

# Matrix-style green-on-black palette. Bright green pops for the segments
# that should draw the eye (model name, git dirty marker); every other
# content segment uses standard green. Dim is reserved for the separator
# only, so nothing primary reads as faint on a dark background.
MODEL_COLOR='\033[92m'  # bright green (pop)
DIR_COLOR='\033[32m'    # standard green
GIT_COLOR='\033[32m'    # standard green (branch name)
DIRTY_COLOR='\033[92m'  # bright green (dirty marker pop)
CTX_COLOR='\033[32m'    # standard green
RATE_COLOR='\033[32m'   # standard green
CTX_HEAD='\033[97m'    # near-white leading cell of the fill bar
CTX_EMPTY='\033[2;32m' # dim green dots for unfilled cells
CTX_LOW='\033[93m'     # amber: context nearly exhausted
CTX_CELLS=10
RL_CELLS=6
LABEL_COLOR='\033[2;32m' # dim green for the ctx/5h/7d labels
SEP_COLOR='\033[2;32m'  # dim green (separator only)
RESET='\033[0m'

STATE_FILE="$HOME/.claude/.matrix-frame"
frame=$(cat "$STATE_FILE" 2>/dev/null)
[[ "$frame" =~ ^[0-9]+$ ]] || frame=0
frame=$(( (frame + 1) % 100000 ))
printf '%s' "$frame" > "$STATE_FILE" 2>/dev/null

# Glyph pool: half-width katakana (U+FF66-U+FF9D) + digits + a few symbols.
GLYPHS=(
  'ｦ' 'ｧ' 'ｨ' 'ｩ' 'ｪ' 'ｫ' 'ｬ' 'ｭ' 'ｮ' 'ｯ' 'ｰ' 'ｱ' 'ｲ' 'ｳ' 'ｴ' 'ｵ'
  'ｶ' 'ｷ' 'ｸ' 'ｹ' 'ｺ' 'ｻ' 'ｼ' 'ｽ' 'ｾ' 'ｿ' 'ﾀ' 'ﾁ' 'ﾂ' 'ﾃ' 'ﾄ' 'ﾅ'
  'ﾆ' 'ﾇ' 'ﾈ' 'ﾉ' 'ﾊ' 'ﾋ' 'ﾌ' 'ﾍ' 'ﾎ' 'ﾏ' 'ﾐ' 'ﾑ' 'ﾒ' 'ﾓ' 'ﾔ' 'ﾕ'
  'ﾖ' 'ﾗ' 'ﾘ' 'ﾙ' 'ﾚ' 'ﾛ' 'ﾜ' 'ﾝ'
  '0' '1' '2' '3' '4' '5' '6' '7' '8' '9'
  ':' '.' '=' '*' '+' '-' '<' '>' '|'
)
NG=${#GLYPHS[@]}

# Render one katakana meter into BAR_OUT.
#   $1 percent (0-100)   $2 cell count
#   $3 "low"  -> amber when the value is SMALL (headroom metrics)
#      "high" -> amber when the value is LARGE (consumption metrics)
#   $4 phase offset, so the meters don't all shimmer in lockstep
BAR_OUT=""
render_bar() {
  local pct=$1 cells=$2 warn=$3 offset=$4
  local filled=$(( (pct * cells + 50) / 100 ))
  (( filled < 0 )) && filled=0
  (( filled > cells )) && filled=cells

  local danger=0
  if [ "$warn" = "low" ]; then
    (( pct < 20 )) && danger=1
  else
    (( pct >= 80 )) && danger=1
  fi

  local fc hc
  if (( danger )); then fc="$CTX_LOW"; hc="$CTX_LOW"
  else fc="$CTX_COLOR"; hc="$CTX_HEAD"; fi

  local b="" c gidx
  for (( c = 0; c < cells; c++ )); do
    if (( c < filled )); then
      gidx=$(( ((frame + (c + offset) * 29) * 11) % NG ))
      if (( c == filled - 1 )); then
        b="${b}$(printf "${hc}%s" "${GLYPHS[$gidx]}")"
      else
        b="${b}$(printf "${fc}%s" "${GLYPHS[$gidx]}")"
      fi
    else
      b="${b}$(printf "${CTX_EMPTY}\xc2\xb7")"
    fi
  done
  BAR_OUT="$b"
}

# label + [meter] + number, as one segment
meter_segment() {
  local label=$1 pct=$2 cells=$3 warn=$4 offset=$5
  render_bar "$pct" "$cells" "$warn" "$offset"
  printf "%s%s%s %s%%%s" \
    "$(printf "${LABEL_COLOR}%s ${SEP_COLOR}[${RESET}" "$label")" \
    "$BAR_OUT" \
    "$(printf "${SEP_COLOR}]${RESET}")" \
    "$(printf "${CTX_COLOR}%s" "$pct")" \
    "$(printf "%b" "$RESET")"
}

segments=()

[ -n "$model" ] && segments+=("$(printf "${MODEL_COLOR}%s${RESET}" "$model")")
[ -n "$dir" ] && segments+=("$(printf "${DIR_COLOR}%s${RESET}" "$dir")")
[ -n "$branch" ] && segments+=("$(printf "${GIT_COLOR}%s${DIRTY_COLOR}%s${RESET}" "$branch" "$dirty")")

# Three katakana meters. Each bar visualises the number printed beside it:
# ctx fills with remaining headroom, the rate limits fill with consumption.
if [ -n "$remaining" ]; then
  remaining_r=$(printf '%.0f' "$remaining")
  segments+=("$(meter_segment ctx "$remaining_r" "$CTX_CELLS" low 0)")
fi

if [ -n "$five" ]; then
  five_r=$(printf '%.0f' "$five")
  segments+=("$(meter_segment 5h "$five_r" "$RL_CELLS" high 7)")
fi

if [ -n "$week" ]; then
  week_r=$(printf '%.0f' "$week")
  segments+=("$(meter_segment 7d "$week_r" "$RL_CELLS" high 13)")
fi

# --- Matrix code-rain tail (purely additive, always rendered) ----------

# 11 glyphs: 1 near-white head, 2 bright green, 4 standard green, 4 dim
# green trailing off -- matches the existing palette tiers.
RAIN_LEN=11
RAIN_HEAD='\033[97m'
RAIN_BRIGHT='\033[92m'
RAIN_STD='\033[32m'
RAIN_DIM='\033[2;32m'

rain=""
for ((i = 0; i < RAIN_LEN; i++)); do
  # Pure integer arithmetic, no subprocess per glyph: step the index by a
  # fixed stride each frame (gcd(7, NG) == 1 for our 75-glyph pool, so it
  # walks the whole table before repeating) and offset per column so the
  # tail doesn't look like a single scrolling copy of the same window.
  idx=$(( ((frame + i * 13) * 7) % NG ))
  glyph="${GLYPHS[$idx]}"
  if [ "$i" -eq 0 ]; then
    color="$RAIN_HEAD"
  elif [ "$i" -le 2 ]; then
    color="$RAIN_BRIGHT"
  elif [ "$i" -le 6 ]; then
    color="$RAIN_STD"
  else
    color="$RAIN_DIM"
  fi
  rain="${rain}$(printf "${color}%s" "$glyph")"
done
segments+=("${rain}$(printf "%b" "$RESET")")

out=""
for seg in "${segments[@]}"; do
  if [ -z "$out" ]; then
    out="$seg"
  else
    out="${out} $(printf "${SEP_COLOR}|${RESET}") ${seg}"
  fi
done

printf "%s" "$out"
