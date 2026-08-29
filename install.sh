#!/bin/zsh
# Matrix theme kit — turn a Mac phosphor green.
# Run from the kit directory:  ./install.sh
# Safe to re-run; every step is idempotent, originals are backed up once,
# and any step whose prerequisites are missing is skipped with a note.
set -e
KIT="$(cd "$(dirname "$0")" && pwd)"
P="$KIT/payload"
TS=$(date +%Y%m%d-%H%M%S)
ARCH=$(uname -m)

# Expand the __HOME__ placeholder used by portable configs.
expand() { sed "s|__HOME__|$HOME|g" "$1"; }
note()   { print -P "%F{2}$1%f"; }
warn()   { print -P "%F{3}skip: $1%f"; }

print -P "%B%F{2}— Matrix theme kit: jacking in —%f%b"

# ── 1. Shell ─────────────────────────────────────────────────────────
if ! grep -q "Matrix theme kit" ~/.zshrc 2>/dev/null; then
  [ -f ~/.zshrc ] && cp ~/.zshrc ~/.zshrc.pre-matrix
  cat "$P/zsh/zshrc-matrix-block.zsh" >> ~/.zshrc
  note "zshrc: Matrix block appended (backup: ~/.zshrc.pre-matrix)"
else
  note "zshrc: Matrix block already present"
fi

# ── 2. Vim ───────────────────────────────────────────────────────────
mkdir -p ~/.vim/colors
cp "$P/vim/colors/matrix.vim" ~/.vim/colors/
grep -q "colorscheme matrix" ~/.vimrc 2>/dev/null || echo "colorscheme matrix" >> ~/.vimrc
note "vim: matrix colorscheme installed"

# ── 3. Cica font (SIL OFL 1.1, fetched from its official releases) ──
if ls ~/Library/Fonts/Cica-Regular* >/dev/null 2>&1; then
  note "fonts: Cica already installed"
else
  note "fonts: downloading Cica from github.com/miiton/Cica ..."
  FT=$(mktemp -d)
  if url=$(curl -fsSL https://api.github.com/repos/miiton/Cica/releases/latest \
        | grep -o '"browser_download_url": *"[^"]*"' | grep -o 'https[^"]*' \
        | grep -i '\.zip' | grep -vi without_emoji | head -1) \
     && [ -n "$url" ] && curl -fsSL -o "$FT/cica.zip" "$url"; then
    unzip -o -j -q "$FT/cica.zip" '*.ttf' -d "$FT"
    cp "$FT"/Cica-*.ttf ~/Library/Fonts/
    note "fonts: Cica installed"
  else
    warn "Cica download failed — grab it from https://github.com/miiton/Cica/releases and install the .ttf files, then re-run"
  fi
  rm -rf "$FT"
fi

# ── 4. Ghostty ───────────────────────────────────────────────────────
mkdir -p ~/.config/ghostty/shaders
[ -f ~/.config/ghostty/config ] && cp ~/.config/ghostty/config ~/.config/ghostty/config.pre-matrix-$TS
expand "$P/ghostty/config" > ~/.config/ghostty/config
cp "$P/ghostty/shaders/matrix.glsl" ~/.config/ghostty/shaders/
note "ghostty: config + rain shader installed (install Ghostty itself if missing)"

# ── 5. Terminal.app profiles ────────────────────────────────────────
open "$P/terminal/Matrix.terminal" "$P/terminal/Matrix-Code.terminal"
sleep 1
defaults write com.apple.Terminal "Default Window Settings" -string "Matrix"
defaults write com.apple.Terminal "Startup Window Settings" -string "Matrix"
note "terminal: Matrix profiles imported and set as default"

# ── 6. CLI tools: bat, cmatrix, sketchybar ──────────────────────────
mkdir -p ~/.local/bin
fetch_release() {  # repo asset-pattern binary-name
  local T=$(mktemp -d) url
  url=$(curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
      | grep -o '"browser_download_url": *"[^"]*"' | grep -o 'https[^"]*' \
      | grep -E "$2" | head -1)
  [ -n "$url" ] || { rm -rf "$T"; return 1; }
  curl -fsSL -o "$T/pkg" "$url" || { rm -rf "$T"; return 1; }
  case "$url" in
    *.zip)    unzip -o -q "$T/pkg" -d "$T" ;;
    *.tar.gz) tar xzf "$T/pkg" -C "$T" ;;
  esac
  local bin=$(find "$T" -name "$3" -type f | head -1)
  [ -n "$bin" ] || { rm -rf "$T"; return 1; }
  install -m 755 "$bin" ~/.local/bin/"$3"
  rm -rf "$T"
}
if command -v brew >/dev/null; then
  brew list bat >/dev/null 2>&1        || brew install bat
  brew list cmatrix >/dev/null 2>&1    || brew install cmatrix
  brew list sketchybar >/dev/null 2>&1 || { brew tap FelixKratz/formulae; brew install sketchybar; }
  note "tools: bat/cmatrix/sketchybar via Homebrew"
else
  case "$ARCH" in arm64) BA=aarch64; SA=arm64 ;; *) BA=x86_64; SA=x86 ;; esac
  command -v bat >/dev/null        || fetch_release sharkdp/bat "$BA-apple-darwin.tar.gz" bat \
    || warn "bat download failed (optional — green cat previews)"
  command -v sketchybar >/dev/null || fetch_release FelixKratz/SketchyBar "$SA.*zip|zip.*$SA" sketchybar \
    || warn "sketchybar download failed — HUD needs it; easiest fix: install Homebrew"
  command -v cmatrix >/dev/null    || warn "cmatrix has no prebuilt binaries; 'brew install cmatrix' for the 'rain' alias (optional)"
fi

# ── 7. SketchyBar HUD ───────────────────────────────────────────────
SB=$(command -v sketchybar || true)
if [ -n "$SB" ]; then
  mkdir -p ~/.config
  rsync -a "$P/sketchybar/" ~/.config/sketchybar/
  chmod +x ~/.config/sketchybar/sketchybarrc ~/.config/sketchybar/plugins/*.sh
  expand "$P/launchagents/local.matrix.sketchybar.plist" \
    | sed "s|$HOME/.local/bin/sketchybar|$SB|" > ~/Library/LaunchAgents/local.matrix.sketchybar.plist
  launchctl bootout gui/$(id -u)/local.matrix.sketchybar 2>/dev/null || true
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.matrix.sketchybar.plist
  note "sketchybar: HUD config installed and agent loaded"
else
  warn "sketchybar not installed — HUD step skipped"
fi

# ── 8. Green accent + optional movie-ring alert sound ───────────────
defaults write NSGlobalDomain AppleAccentColor -int 3
defaults write NSGlobalDomain AppleHighlightColor -string "0.752941 0.964706 0.678431 Green"
RING=""
for f in "$KIT"/matrix-ring.aiff "$KIT"/matrix-ring.mp3 "$KIT"/matrix-ring.m4a "$KIT"/matrix-ring.wav; do
  [ -f "$f" ] && RING="$f" && break
done
mkdir -p ~/Library/Sounds
if [ -n "$RING" ]; then
  afconvert -f AIFF -d BEI16 "$RING" ~/Library/Sounds/MatrixRing.aiff
  cp ~/Library/Sounds/MatrixRing.aiff ~/Library/Sounds/MatrixRingLong.aiff
  note "sound: your matrix-ring file installed as the alert sound"
else
  cp "$P/sounds/MatrixRing.aiff" "$P/sounds/MatrixRingLong.aiff" ~/Library/Sounds/
  note "sound: synthesized warble installed as the alert sound (drop a matrix-ring.mp3 next to install.sh and re-run to use your own ring — this kit ships no movie audio)"
fi
defaults write NSGlobalDomain com.apple.sound.beep.sound -string "$HOME/Library/Sounds/MatrixRing.aiff"
note "  (if the alert ever goes silent: re-pick MatrixRing in System Settings → Sound)"
killall cfprefsd 2>/dev/null || true
note "accent: green (log out/in to apply everywhere)"

# ── 9. Live wallpaper + screensaver (built from source) ─────────────
if command -v swiftc >/dev/null 2>&1; then
  mkdir -p ~/.claude/matrix-saver
  rsync -a "$P/matrix-saver/" ~/.claude/matrix-saver/
  cd ~/.claude/matrix-saver
  mkdir -p MatrixWallpaper.app/Contents/MacOS MatrixRain.saver/Contents/MacOS
  note "matrix-saver: compiling (first run takes ~30s) ..."
  swiftc -O main.swift MatrixRainView.swift hotkey.swift \
    -o MatrixWallpaper.app/Contents/MacOS/MatrixWallpaper \
    -framework Cocoa -framework ScreenSaver -framework Carbon
  BT=$(mktemp -d)
  swiftc -O -parse-as-library -c MatrixRainView.swift -o "$BT/mrv.o" -module-name MatrixRain
  clang -bundle -o MatrixRain.saver/Contents/MacOS/MatrixRain "$BT/mrv.o" \
    -framework Cocoa -framework ScreenSaver -L/usr/lib/swift -lobjc
  rm -rf "$BT"
  codesign -f -s - MatrixRain.saver MatrixWallpaper.app
  mkdir -p "$HOME/Library/Screen Savers"
  rm -rf "$HOME/Library/Screen Savers/MatrixRain.saver"
  cp -R MatrixRain.saver "$HOME/Library/Screen Savers/"
  expand "$P/launchagents/local.matrixrain.wallpaper.plist" > ~/Library/LaunchAgents/local.matrixrain.wallpaper.plist
  launchctl bootout gui/$(id -u)/local.matrixrain.wallpaper 2>/dev/null || true
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.matrixrain.wallpaper.plist
  cd "$KIT"
  note "wallpaper: live-rain agent loaded (⌃⌥⌘M launches the screensaver on demand)"
  note "screensaver: pick 'MatrixRain' in System Settings → Screen Saver"
else
  warn "swiftc not found — wallpaper/screensaver skipped. Run 'xcode-select --install' and re-run."
fi

# ── 10. Rain script (always) + Claude Code (if installed) ───────────
mkdir -p ~/.claude
cp "$P/claude/matrix-rain.py" ~/.claude/
chmod +x ~/.claude/matrix-rain.py
note "rain: 'matrix' command installed (~/.claude/matrix-rain.py)"
if [ -d ~/.claude/projects ] || command -v claude >/dev/null 2>&1; then
  mkdir -p ~/.claude/themes
  cp "$P/claude/statusline-command.sh" ~/.claude/
  chmod +x ~/.claude/statusline-command.sh
  cp "$P"/claude/themes/*.json ~/.claude/themes/
  python3 - "$P/claude/settings-matrix-fragment.json" <<'EOF'
import json, os, sys, shutil
sp = os.path.expanduser('~/.claude/settings.json')
frag = json.load(open(sys.argv[1]))
cur = json.load(open(sp)) if os.path.exists(sp) else {}
if os.path.exists(sp):
    shutil.copy(sp, sp + '.pre-matrix')
for k, v in frag.items():
    if k == 'hooks':
        cur.setdefault('hooks', {}).update(v)   # keep hooks for other events
    else:
        cur[k] = v
json.dump(cur, open(sp, 'w'), indent=2, ensure_ascii=False)
EOF
  note "claude code: theme, statusline, spinner verbs, hooks merged (backup: settings.json.pre-matrix)"
else
  warn "Claude Code not detected — its theming skipped (re-run after installing it)"
fi

echo ""
print -P "%B%F{2}— TRANSMISSION COMPLETE —%f%b"
echo "Follow-ups:"
echo "  • Open a new terminal window for the prompt + greeting"
echo "  • System Settings → Screen Saver → choose MatrixRain"
echo "  • Log out/in for the green accent everywhere"
echo "  • Restart Claude Code (if installed) for the theme"
