#!/bin/bash
# Compila "DualSense Battery.app".
#   bash build.sh            → crea l'app in ./build
#   bash build.sh --install  → la copia anche in /Applications e la avvia
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DualSense Battery"
APP="build/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if ! XCRUN_ERROR=$(xcrun --find swiftc 2>&1 >/dev/null); then
  echo "Non trovo il compilatore Swift."
  echo "Errore di xcrun: $XCRUN_ERROR"
  echo "Percorso strumenti attivo: $(xcode-select -p 2>&1)"
  echo "Se mancano gli strumenti: xcode-select --install"
  exit 1
fi

# Pulizia della build precedente
if ! rm -rf build 2>/dev/null; then
  echo "Non riesco a cancellare la cartella build: spostala nel Cestino dal Finder e rilancia."
  exit 1
fi
mkdir -p build

# Compila fuori dal bundle, poi assembla l'app
xcrun swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos14" \
  -o build/DualSenseBattery \
  main.swift

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -X build/DualSenseBattery "$APP/Contents/MacOS/DualSenseBattery"
cp -X Info.plist "$APP/Contents/Info.plist"
cp -X AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Creata: $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x DualSenseBattery 2>/dev/null || true
  if [[ -e "$DEST" ]] && ! rm -rf "$DEST" 2>/dev/null; then
    echo "Non riesco a sostituire $DEST: spostala nel Cestino dal Finder e rilancia."
    exit 1
  fi
  ditto --noextattr "$APP" "$DEST"
  touch "$DEST"   # fa aggiornare al Finder l'icona in cache
  "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
  open "$DEST"
  echo "Installata in /Applications e avviata."
fi
