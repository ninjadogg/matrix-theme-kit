#!/bin/bash
# Lights up when macOS secure keyboard input is active (password entry,
# or Ghostty auto-enabling it for a no-echo TUI). The pid key only exists
# in IOConsoleUsers while secure input is held.
pid=$(ioreg -l -d 1 -w 0 2>/dev/null | grep -o '"kCGSSessionSecureInputPID"=[0-9]*' | head -1 | cut -d= -f2)
if [ -n "$pid" ] && [ "$pid" != "0" ]; then
  sketchybar --set "$NAME" drawing=on
else
  sketchybar --set "$NAME" drawing=off
fi
