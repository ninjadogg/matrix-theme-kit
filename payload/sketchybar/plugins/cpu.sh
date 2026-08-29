#!/bin/bash
CPU=$(top -l 1 -n 0 | awk '/CPU usage/ {gsub("%",""); printf "%.0f", $3 + $5}')
sketchybar --set "$NAME" label="${CPU:-?}%"
