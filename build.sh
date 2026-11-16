#!/bin/zsh
# Pupka for macOS - builds Pupka.app (Swift shell + the web app from ../Pupka + offline fonts + the llama.cpp server) and installs it to /Applications.
set -e
cd "$(dirname "$0")"
WEB="${PUPKA_WEB:-../Pupka}"
APP="build/Pupka.app"
RES="$APP/Contents/Resources"
ARCH="$(uname -m)"
LLAMA="Niepotrzebne/llama"

[ -f "$WEB/index.html" ] || { echo "no web app at $WEB"; exit 1; }
[ -x "$LLAMA/llama-server" ] || zsh Niepotrzebne/get-llama.sh
[ -f fonts/fonts.css ] || python3 Niepotrzebne/get-fonts.py

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$RES/web/assets" "$RES/llama" build/icon.iconset
nice -n 10 swiftc -O -swift-version 5 -target "$ARCH-apple-macosx14.0" Sources/*.swift -o "$APP/Contents/MacOS/Pupka"

cp "$WEB/styles.css" "$RES/web/"
cp -R "$WEB/src" "$WEB/lib" "$WEB/dist" "$RES/web/"
cp -R "$WEB/assets/fonts" "$RES/web/assets/"
cp "$WEB/assets/"*.gif "$RES/web/assets/" 2>/dev/null || true
cp -R fonts "$RES/web/fonts"
python3 - "$WEB/index.html" "$RES/web/index.html" <<'EOF'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
html = re.sub(r'<link[^>]*fonts\.(googleapis|gstatic)\.com[^>]*>\n?', '', html)
html = html.replace('<link rel="stylesheet" href="lib/katex/katex.min.css">', '<link rel="stylesheet" href="fonts/fonts.css">\n<link rel="stylesheet" href="lib/katex/katex.min.css">')
html = html.replace('<html lang="pl">', '<html lang="pl" class="desktop">')
assert 'fonts/fonts.css' in html and 'googleapis' not in html
open(sys.argv[2], "w", encoding="utf-8").write(html)
EOF

cp "$LLAMA/llama-server" "$LLAMA/LICENSE" "$RES/llama/"
for lib in libllama-server-impl libllama-common.1 libmtmd.1 libllama.1 libggml.1 libggml-cpu.1 libggml-blas.1 libggml-rpc.1 libggml-base.1; do
  cp -L "$LLAMA/$lib.dylib" "$RES/llama/$lib.dylib"
done

cp Info.plist "$APP/Contents/Info.plist"
swift icon/make_icon.swift build/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out "build/icon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon.png --out "build/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/icon.iconset -o "$RES/AppIcon.icns"

SIGN_ID="$(security find-identity -p codesigning 2>/dev/null | grep -o '"[^"]*Local Signing"' | head -1 | tr -d '"')"
for f in "$RES"/llama/*.dylib "$RES/llama/llama-server"; do codesign -s "${SIGN_ID:--}" --force "$f"; done
codesign -s "${SIGN_ID:--}" --force --identifier fun.gzowo.pupka "$APP"

if [ "${NO_INSTALL:-}" = "" ]; then
  DEST="/Applications"
  [ -w "$DEST" ] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  WAS_OPEN=""
  if pgrep -x Pupka >/dev/null; then
    WAS_OPEN=1
    notifyutil -p fun.gzowo.pupka.quit
    for i in $(seq 1 30); do pgrep -x Pupka >/dev/null || break; sleep 0.2; done
    pkill -x Pupka 2>/dev/null || true
    sleep 0.5
  fi
  rm -rf "$DEST/Pupka.app"
  ditto "$APP" "$DEST/Pupka.app"
  echo "installed: $DEST/Pupka.app"
  [ -n "$WAS_OPEN" ] && open -a "$DEST/Pupka.app" && echo "reopened"
else
  echo "built: $APP"
fi
