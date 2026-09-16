#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
[[ -n "$VERSION" ]] || { echo "VERSION vazio"; exit 1; }

IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
BUILD="$((10#$MINOR * 100 + 10#$PATCH))"

DIST="$ROOT/dist"
WORK="$(mktemp -d)"
SETUP_TEMPLATE="$ROOT/Installer/PixyGuard Setup.app"
SETUP="$WORK/PixyGuard Setup.app"
OUT="$DIST/PixyGuard-$VERSION-unified.dmg"
SHA="$DIST/PixyGuard-$VERSION-unified.sha256"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

required=(
  "$SETUP_TEMPLATE"
  "$ROOT/Installer/setup.sh"
  "$ROOT/Sources/PixyGuard/main-en.swift"
  "$ROOT/Sources/PixyGuard/main-pt.swift"
  "$ROOT/Sources/pixyctl/pixyctl.c"
  "$ROOT/Sources/pixyusage/pixyusage.m"
  "$ROOT/Resources/AppIcon.icns"
  "$ROOT/Resources/Info.plist"
  "$ROOT/scripts/build.sh"
)

for f in "${required[@]}"; do
  [[ -e "$f" ]] || { echo "ERRO: faltando $f"; exit 1; }
done

echo "======================================================"
echo " PixyGuard Release $VERSION ($BUILD)"
echo "======================================================"

echo "[1/6] Validando setup shell..."
/bin/zsh -n "$ROOT/Installer/setup.sh"

echo "[2/6] Validando Swift EN..."
cp "$ROOT/Sources/PixyGuard/main-en.swift" "$ROOT/Sources/PixyBar/main.swift"
"$ROOT/scripts/build.sh" >/dev/null
rm -rf "$ROOT/PixyBar.app"

echo "[3/6] Validando Swift PT..."
cp "$ROOT/Sources/PixyGuard/main-pt.swift" "$ROOT/Sources/PixyBar/main.swift"
"$ROOT/scripts/build.sh" >/dev/null
rm -rf "$ROOT/PixyBar.app"

cp "$ROOT/Sources/PixyGuard/main-en.swift" "$ROOT/Sources/PixyBar/main.swift"

echo "[4/6] Montando Setup.app..."
/usr/bin/ditto "$SETUP_TEMPLATE" "$SETUP"

RES="$SETUP/Contents/Resources"
PLIST="$SETUP/Contents/Info.plist"

cp "$ROOT/Installer/setup.sh" "$RES/setup.sh"
chmod +x "$RES/setup.sh"
cp "$ROOT/Sources/PixyGuard/main-en.swift" "$RES/PixyGuard-main-en.swift"
cp "$ROOT/Sources/PixyGuard/main-pt.swift" "$RES/PixyGuard-main-pt.swift"
cp "$ROOT/Sources/pixyctl/pixyctl.c" "$RES/pixyctl.c"
cp "$ROOT/Sources/pixyusage/pixyusage.m" "$RES/pixyusage.m"
cp "$ROOT/scripts/build.sh" "$RES/build.sh"
chmod +x "$RES/build.sh"
cp "$ROOT/Resources/Info.plist" "$RES/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
cp "$ROOT/Installer/LICENSE.txt" "$RES/LICENSE.txt"
cp "$ROOT/Installer/PRIVACY.txt" "$RES/PRIVACY.txt"
cp "$ROOT/Installer/TERMS.txt" "$RES/TERMS.txt"
cp "$ROOT/Installer/THIRD-PARTY-NOTICES.txt" "$RES/THIRD-PARTY-NOTICES.txt"

python3 - "$RES/setup.sh" "$VERSION" "$BUILD" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
version = sys.argv[2]
build = sys.argv[3]
s = p.read_text()
s = re.sub(r'^VERSION=.*$', f'VERSION="{version}-unified"', s, flags=re.M)
s = re.sub(r'\d+\.\d+\.\d+-unified', f'{version}-unified', s)
s = re.sub(r'CFBundleVersion \d+', f'CFBundleVersion {build}', s)
s = re.sub(r'\(\d+\)', f'({build})', s)
p.write_text(s)
PY

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.fabioasouza.pixyguard.setup" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION-unified" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"

echo "[5/6] Assinando Setup.app..."
rm -rf "$SETUP/Contents/_CodeSignature" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$SETUP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$SETUP"

echo "[6/6] Gerando DMG + SHA256..."
mkdir -p "$DIST"
rm -f "$OUT" "$SHA"

/usr/bin/hdiutil create \
  -volname "PIXYGUARD" \
  -srcfolder "$SETUP" \
  -ov \
  -format UDZO \
  "$OUT" >/dev/null

/usr/bin/shasum -a 256 "$OUT" | tee "$SHA"

echo
echo "PRONTO:"
echo "  $OUT"
echo "  $SHA"
