#!/bin/bash
# Readable clock with a kanji weekday accent: 08.29（金）14:52:03
wd=(月 火 水 木 金 土 日)
u=$(date +%u)
sketchybar --set "$NAME" label="$(date +%m.%d)（${wd[$((u - 1))]}）$(date +%H:%M:%S)"
