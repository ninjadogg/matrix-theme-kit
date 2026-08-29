#!/bin/bash
# Reload the Matrix wallpaper agent under launchd.
launchctl bootout "gui/$(id -u)/local.matrixrain.wallpaper" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.matrixrain.wallpaper.plist"
echo "reloaded; agent log:"
sleep 3
cat "$HOME/.claude/matrix-saver/agent.log" 2>/dev/null || echo "(no log yet)"
