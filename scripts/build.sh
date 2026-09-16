#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/PixyBar.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
APP_RESOURCES="$CONTENTS/Resources"
CACHE="$ROOT/.build/module-cache"

mkdir -p "$MACOS" "$APP_RESOURCES" "$CACHE"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"

clang -std=c17 -Wall -Wextra -O2 \
  "$ROOT/Sources/pixyctl/pixyctl.c" \
  -framework IOKit \
  -framework CoreFoundation \
  -o "$MACOS/pixyctl"

CLANG_MODULE_CACHE_PATH="$CACHE" swiftc -O \
  -module-cache-path "$CACHE" \
  -framework AppKit \
  -framework Carbon \
  -framework ServiceManagement \
  "$ROOT/Sources/PixyBar/main.swift" \
  -o "$MACOS/PixyBar"

echo "Built $APP"
