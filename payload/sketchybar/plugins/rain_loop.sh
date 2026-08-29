#!/bin/bash
# Persistent animator for the center code-rain (started by sketchybarrc,
# which pkills any previous instance first). Exits when sketchybar dies.
CELLS=21
HOLD=20                    # ticks to linger fully-written
CYCLE=$((CELLS + HOLD))
TICK=0.25                  # seconds per animation tick
GLYPHS=(
  'ｦ' 'ｧ' 'ｨ' 'ｩ' 'ｪ' 'ｫ' 'ｬ' 'ｭ' 'ｮ' 'ｯ' 'ｰ' 'ｱ' 'ｲ' 'ｳ' 'ｴ' 'ｵ'
  'ｶ' 'ｷ' 'ｸ' 'ｹ' 'ｺ' 'ｻ' 'ｼ' 'ｽ' 'ｾ' 'ｿ' 'ﾀ' 'ﾁ' 'ﾂ' 'ﾃ' 'ﾄ' 'ﾅ'
  'ﾆ' 'ﾇ' 'ﾈ' 'ﾉ' 'ﾊ' 'ﾋ' 'ﾌ' 'ﾍ' 'ﾎ' 'ﾏ' 'ﾐ' 'ﾑ' 'ﾒ' 'ﾓ' 'ﾔ' 'ﾕ'
  'ﾖ' 'ﾗ' 'ﾘ' 'ﾙ' 'ﾚ' 'ﾛ' 'ﾜ' 'ﾝ'
  '0' '1' '2' '3' '4' '5' '6' '7' '8' '9'
  ':' '.' '=' '*' '+' '-' '<' '>' '|'
)
NG=${#GLYPHS[@]}

frame=0
while :; do
  frame=$(( (frame + 1) % 100000 ))
  pos=$(( frame % CYCLE ))
  shim=$(( frame / 3 ))    # glyph shimmer runs slower than the pen
  args=()
  for (( i = 0; i < CELLS; i++ )); do
    k=$(( CELLS - 1 - i ))   # write order counts from the right edge
    if (( k > pos )); then
      args+=(--set "rain.$i" label="·" label.color=0x55008f11)
    else
      dist=$(( pos - k ))
      idx=$(( ((shim + i * 13) * 7) % NG ))
      if   (( dist == 0 )); then c=0xffffffff
      elif (( dist <= 2 )); then c=0xff66ff88
      elif (( dist <= 8 )); then c=0xff00ff41
      else                       c=0xff008f11
      fi
      args+=(--set "rain.$i" label="${GLYPHS[$idx]}" label.color=$c)
    fi
  done
  sketchybar "${args[@]}" 2>/dev/null || exit 0
  sleep "$TICK"
done
