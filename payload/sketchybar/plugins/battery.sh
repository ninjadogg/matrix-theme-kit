#!/bin/bash
PCT=$(pmset -g batt | grep -Eo "[0-9]+%" | head -1 | tr -d '%')
[ -z "$PCT" ] && exit 0
if pmset -g batt | grep -q "AC Power"; then
  ICON="充"   # charging (充電)
else
  ICON="電"   # on battery power
fi
COLOR=0xff00ff41
[ "$PCT" -le 20 ] && COLOR=0xffff4136
sketchybar --set "$NAME" icon="$ICON" icon.color=$COLOR label="${PCT}%"
