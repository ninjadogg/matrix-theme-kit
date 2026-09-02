#!/bin/bash
# Reload the Matrix wallpaper agent under launchd.
#
# bootout is ASYNCHRONOUS. Bootstrapping straight after it races launchd's
# teardown and fails with "Bootstrap failed: 5: Input/output error" -- which
# this script used to discard, so it printed "reloaded" while leaving the
# wallpaper dead and the service unloaded. Observed on 2026-09-02. Wait for the
# service to actually go, retry the bootstrap, and confirm a process exists.
set -u

LABEL=local.matrixrain.wallpaper
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
EXE='MatrixWallpaper.app/Contents/MacOS/MatrixWallpaper'

[ -f "$PLIST" ] || { echo "reload FAILED: no plist at $PLIST" >&2; exit 1; }

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in $(seq 1 50); do                      # up to 5s for teardown
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.1
done

ok=0
for _ in $(seq 1 10); do                      # up to 5s of retries
  if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then ok=1; break; fi
  sleep 0.5
done
if [ "$ok" -ne 1 ]; then
  echo "reload FAILED: could not bootstrap $LABEL. Unmuted retry:" >&2
  launchctl bootstrap "$DOMAIN" "$PLIST"      # run once more to show the error
  exit 1
fi

for _ in $(seq 1 50); do                      # bootstrapped != running
  pgrep -f "$EXE" >/dev/null && break
  sleep 0.1
done
PID=$(pgrep -f "$EXE" | head -1)
if [ -z "$PID" ]; then
  echo "reload FAILED: bootstrapped but no process appeared" >&2
  exit 1
fi

echo "reloaded; pid $PID"
echo "--- agent log (last 20 lines) ---"
tail -n 20 "$HOME/.claude/matrix-saver/agent.log" 2>/dev/null || echo "(no log yet)"
