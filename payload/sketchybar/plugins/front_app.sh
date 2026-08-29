#!/bin/bash
# Trailing space matters: sketchybar under-measures labels ending in a
# full-width CJK glyph and clips the closing bracket without it.
sketchybar --set "$NAME" label="「 ${INFO} 」 "
