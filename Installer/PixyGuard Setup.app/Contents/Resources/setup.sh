#!/bin/zsh
set -euo pipefail
MODE="${1:-install}"
STATUS_FILE="${2:-/tmp/pixyguard-setup-$(id -u).status}"
PRIVACY_ON_LOCK="${3:-true}"
AUTO_TRACKING="${4:-true}"
NORMAL_WHEN_IDLE="${5:-true}"
LANG_CODE="${6:-en}"
VERSION="0.5.9-unified"
APP="/Applications/PixyGuard.app"
APP_SUPPORT="$HOME/Library/Application Support/PixyGuard"
LOG_DIR="$HOME/Library/Logs/PixyGuard"

finalize_installed_pixyguard() {
  [[ -d "$APP" ]] || { echo "❌ Installed PixyGuard.app not found"; return 1; }
  echo "🧬 Finalizing installed PixyGuard identity..."

  if [[ -f "$APP/Contents/MacOS/PixyBar" && ! -f "$APP/Contents/MacOS/PixyGuard" ]]; then
    /usr/bin/sudo /bin/mv "$APP/Contents/MacOS/PixyBar" "$APP/Contents/MacOS/PixyGuard"
  fi

  /usr/bin/sudo /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.rosewavestudio.pixyguard" "$APP/Contents/Info.plist"
  /usr/bin/sudo /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable PixyGuard" "$APP/Contents/Info.plist"
  /usr/bin/sudo /usr/libexec/PlistBuddy -c "Set :CFBundleName PixyGuard" "$APP/Contents/Info.plist"
  /usr/bin/sudo /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName PixyGuard" "$APP/Contents/Info.plist"
  /usr/bin/sudo /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist"
  /usr/bin/sudo /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.5.9-unified" "$APP/Contents/Info.plist"
  /usr/bin/sudo /usr/libexec/PlistBuddy -c "Set :CFBundleVersion 509" "$APP/Contents/Info.plist"

  echo "🎨 Rebuilding all AppIcon representations..."
  local ICON="$APP/Contents/Resources/AppIcon.icns"
  local ICONSET="$TMP/PixyGuard.fixed.iconset"
  local FIXED="$TMP/AppIcon-fixed.icns"
  /bin/rm -rf "$ICONSET" "$FIXED"
  /usr/bin/iconutil -c iconset "$ICON" -o "$ICONSET"
  local SRC="$ICONSET/icon_512x512@2x.png"
  [[ -f "$SRC" ]] || SRC="$ICONSET/icon_512x512.png"
  [[ -f "$SRC" ]] || { echo "❌ No valid high-resolution AppIcon source found"; return 1; }

  /usr/bin/sips -z 16 16 "$SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
  /usr/bin/sips -z 32 32 "$SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  /usr/bin/sips -z 32 32 "$SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
  /usr/bin/sips -z 64 64 "$SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  /usr/bin/sips -z 128 128 "$SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
  /usr/bin/sips -z 256 256 "$SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  /usr/bin/sips -z 256 256 "$SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
  /usr/bin/sips -z 512 512 "$SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  /usr/bin/sips -z 512 512 "$SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
  if [[ "$SRC" != "$ICONSET/icon_512x512@2x.png" ]]; then /bin/cp "$SRC" "$ICONSET/icon_512x512@2x.png"; fi
  /usr/bin/iconutil -c icns "$ICONSET" -o "$FIXED"
  /usr/bin/sudo /bin/cp "$FIXED" "$ICON"

  echo "🔏 Signing final installed bundle..."
  /usr/bin/sudo /bin/chmod +x "$APP/Contents/MacOS/PixyGuard" "$APP/Contents/MacOS/pixyctl" "$APP/Contents/MacOS/pixyusage"
  /usr/bin/sudo /usr/bin/codesign --force --sign - "$APP/Contents/MacOS/PixyGuard"
  /usr/bin/sudo /usr/bin/codesign --force --sign - "$APP/Contents/MacOS/pixyctl"
  /usr/bin/sudo /usr/bin/codesign --force --sign - "$APP/Contents/MacOS/pixyusage"
  /usr/bin/sudo /bin/rm -rf "$APP/Contents/_CodeSignature"
  /usr/bin/sudo /usr/bin/codesign --force --deep --sign - "$APP"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

  local LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true

  echo "✅ Installed bundle finalized as com.rosewavestudio.pixyguard / 0.5.9-unified (509)"
}

BUNDLE_ID="com.rosewavestudio.pixyguard"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

msg() { [[ "$LANG_CODE" == "pt-BR" ]] && print -r -- "$2" || print -r -- "$1"; }
finish_status() { print -r -- "$1" >| "$STATUS_FILE" 2>/dev/null || true; }
trap 'rc=$?; if (( rc != 0 )); then finish_status "failure:$rc"; fi' EXIT

header() {
  clear
  echo ""
  echo "  ╔══════════════════════════════════════╗"
  echo "  ║        PixyGuard Unified             ║"
  printf "  ║        %-22s ║\n" "$VERSION"
  echo "  ╚══════════════════════════════════════╝"
  echo "  Created by Fábio Vamp 😎"
  echo ""
}

remove_login_item_named() {
  local item="$1"
  /usr/bin/osascript - "$item" <<'OSA' >/dev/null 2>&1 || true
on run argv
  set itemName to item 1 of argv
  tell application "System Events"
    if exists login item itemName then delete login item itemName
  end tell
end run
OSA
}

service_absent() {
  ! /bin/launchctl print "gui/$(id -u)/$1" >/dev/null 2>&1
}

verify_uninstall() {
  local failed=0
  echo ""
  msg "Verifying uninstall..." "Verificando desinstalação..."

  pixy_processes=$(/usr/bin/pgrep -afil 'PixyGuard|PixyBar|pixyctl' 2>/dev/null | /usr/bin/grep -v 'PixyGuard Setup.app/Contents/Resources/setup.sh' || true)
  if [[ -n "$pixy_processes" ]]; then
    echo "❌ Processes still found:"; print -r -- "$pixy_processes"; failed=1
  else echo "✅ No Pixy processes"; fi

  for label in com.pixyguard.app com.pixyguard.agent com.fabiovamp.pixyguard.guard; do
    if service_absent "$label"; then echo "✅ $label absent"; else echo "❌ $label still loaded"; failed=1; fi
  done

  local paths=(
    "/Applications/PixyGuard.app"
    "/Applications/PixyBar.app"
    "$HOME/Applications/PixyGuard.app"
    "$HOME/Applications/PixyBar.app"
    "$HOME/Library/Application Support/PixyGuard"
    "$HOME/Library/Logs/PixyGuard"
    "$HOME/Library/LaunchAgents/com.pixyguard.agent.plist"
    "$HOME/Library/LaunchAgents/com.pixyguard.app.plist"
    "$HOME/Library/LaunchAgents/com.fabio.pixylock.plist"
    "$HOME/Library/LaunchAgents/com.fabiovamp.pixyguard.guard.plist"
    "$HOME/Library/Preferences/com.fabiovamp.pixyguard.plist"
  )
  for p in "${paths[@]}"; do
    [[ -e "$p" ]] && { echo "❌ Residual: $p"; failed=1; } || echo "✅ Absent: $p"
  done

  local li
  li=$(/usr/bin/osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null || true)
  if print -r -- "$li" | /usr/bin/grep -qiE 'PixyGuard|PixyBar'; then echo "❌ Pixy login item still present: $li"; failed=1; else echo "✅ No Pixy login item"; fi

  if (( failed == 0 )); then
    msg "✅ Uninstall verification passed." "✅ Verificação da desinstalação aprovada."
    return 0
  fi
  msg "⚠️ Uninstall left one or more residual items." "⚠️ A desinstalação deixou um ou mais resíduos."
  return 1
}

complete_uninstall() {
  msg "Removing PixyGuard/PixyBar..." "Removendo PixyGuard/PixyBar..."
  /bin/launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.pixyguard.agent.plist" >/dev/null 2>&1 || true
  /bin/launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.pixyguard.app.plist" >/dev/null 2>&1 || true
  /bin/launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.fabiovamp.pixyguard.guard.plist" >/dev/null 2>&1 || true
  /bin/launchctl remove com.pixyguard.app >/dev/null 2>&1 || true
  /bin/launchctl remove com.pixyguard.agent >/dev/null 2>&1 || true
  /bin/launchctl remove com.fabiovamp.pixyguard.guard >/dev/null 2>&1 || true
  /usr/bin/pkill -f 'PixyGuard|PixyBar|pixyctl' >/dev/null 2>&1 || true
  remove_login_item_named "PixyGuard"
  remove_login_item_named "PixyBar"

  # Reset Input Monitoring while the bundle IDs are still knowable.
  if [[ -f "$APP/Contents/Info.plist" ]]; then
    local oldid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
    [[ -n "$oldid" ]] && /usr/bin/tccutil reset ListenEvent "$oldid" >/dev/null 2>&1 || true
  fi
  if [[ -f /Applications/PixyBar.app/Contents/Info.plist ]]; then
    local pbid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/PixyBar.app/Contents/Info.plist 2>/dev/null || true)
    [[ -n "$pbid" ]] && /usr/bin/tccutil reset ListenEvent "$pbid" >/dev/null 2>&1 || true
  fi

  /bin/rm -rf "$APP_SUPPORT" "$LOG_DIR"
  /bin/rm -f "$HOME/Library/Preferences/com.fabiovamp.pixyguard.plist" 2>/dev/null || true
  /bin/rm -f "$HOME/Library/Preferences/com.rosewavestudio.pixyguard.plist" 2>/dev/null || true
  /usr/bin/defaults delete com.rosewavestudio.pixyguard >/dev/null 2>&1 || true
  /usr/bin/defaults delete com.rosewavestudio.pixyguard >/dev/null 2>&1 || true
  /bin/rm -f "$HOME/Library/LaunchAgents/com.pixyguard.agent.plist" "$HOME/Library/LaunchAgents/com.pixyguard.app.plist" "$HOME/Library/LaunchAgents/com.fabio.pixylock.plist" "$HOME/Library/LaunchAgents/com.fabiovamp.pixyguard.guard.plist"
  /usr/bin/defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  /bin/rm -f "$HOME/Library/Preferences/${BUNDLE_ID}.plist" >/dev/null 2>&1 || true
  if [[ -w /Applications ]]; then
    /bin/rm -rf /Applications/PixyGuard.app /Applications/PixyBar.app
  else
    /usr/bin/sudo /bin/rm -rf /Applications/PixyGuard.app /Applications/PixyBar.app
  fi
  sleep 1

  if ! verify_uninstall; then
    msg "Retrying cleanup once..." "Tentando a limpeza mais uma vez..."
    /usr/bin/pkill -f 'PixyGuard|PixyBar|pixyctl' >/dev/null 2>&1 || true
    /bin/launchctl remove com.pixyguard.app >/dev/null 2>&1 || true
    /bin/launchctl remove com.pixyguard.agent >/dev/null 2>&1 || true
    /bin/launchctl remove com.fabiovamp.pixyguard.guard >/dev/null 2>&1 || true
    /bin/rm -rf "$APP_SUPPORT" "$LOG_DIR" /Applications/PixyGuard.app /Applications/PixyBar.app 2>/dev/null || true
    /usr/bin/defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    /bin/rm -f "$HOME/Library/Preferences/${BUNDLE_ID}.plist" >/dev/null 2>&1 || true
    verify_uninstall || return 1
  fi
}

header

if [[ "$MODE" == "uninstall" ]]; then
  complete_uninstall
  finish_status success
  trap - EXIT
  if [[ "$LANG_CODE" == "pt-BR" ]]; then FINAL="PixyGuard foi removido completamente e a verificação final passou."; BTN="Concluir"; else FINAL="PixyGuard was completely removed and the final verification passed."; BTN="Finish"; fi
  /usr/bin/osascript - "$FINAL" "$BTN" <<'OSA' >/dev/null 2>&1 || true
on run argv
  display dialog (item 1 of argv) buttons {(item 2 of argv)} default button (item 2 of argv) with title "PixyGuard"
end run
OSA
  exit 0
fi

if [[ "$MODE" == "clean" ]]; then complete_uninstall; fi

if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1 || ! /usr/bin/xcrun --find clang >/dev/null 2>&1; then
  msg "Apple Command Line Tools are required by this lab build. macOS will offer to install them now. Run Setup again after it finishes." "As Apple Command Line Tools são necessárias nesta build de laboratório. O macOS vai oferecer a instalação agora. Rode o Setup novamente quando terminar."
  /usr/bin/xcode-select --install >/dev/null 2>&1 || true
  read -r "?Press Enter to close..."
  exit 1
fi

mkdir -p "$APP_SUPPORT" "$LOG_DIR"
TMP="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$TMP"' EXIT
ZIP="$TMP/PixyBar.zip"
SRCROOT="$TMP/src"
URL="https://github.com/RoseWaveStudio/PixyBar/archive/refs/heads/main.zip"

echo "📦 Fetching PixyBar upstream source..."
/usr/bin/curl -fL --progress-bar "$URL" -o "$ZIP"
/usr/bin/ditto -x -k "$ZIP" "$SRCROOT"
SRC="$(/usr/bin/find "$SRCROOT" -maxdepth 1 -type d -name 'PixyBar-*' -print -quit)"
[[ -n "$SRC" ]] || { echo "❌ PixyBar source not found"; exit 1; }

# Preserve upstream MIT license in our final bundle.
UPSTREAM_LICENSE=""
for f in "$SRC/LICENSE" "$SRC/LICENSE.txt" "$SRC/LICENCE"; do [[ -f "$f" ]] && { UPSTREAM_LICENSE="$f"; break; }; done

MAIN_SWIFT="$(/usr/bin/grep -rl --include='*.swift' 'Tracking works while video is open' "$SRC/Sources" 2>/dev/null | /usr/bin/head -1 || true)"
if [[ -z "$MAIN_SWIFT" ]]; then MAIN_SWIFT="$(/usr/bin/grep -rl --include='*.swift' 'Launch at Login' "$SRC/Sources" 2>/dev/null | /usr/bin/head -1 || true)"; fi
[[ -n "$MAIN_SWIFT" ]] || { echo "❌ Could not locate PixyBar UI source to unify."; exit 1; }

echo "🧬 Installing the unified AppKit PixyGuard source..."
SCRIPT_RES="$(cd "$(dirname "$0")" && pwd)"
if [[ "$LANG_CODE" == "pt-BR" ]]; then
  BUNDLED_MAIN="$SCRIPT_RES/PixyGuard-main-pt.swift"
else
  BUNDLED_MAIN="$SCRIPT_RES/PixyGuard-main-en.swift"
fi
[[ -f "$BUNDLED_MAIN" ]] || { echo "❌ Bundled PixyGuard source is missing"; exit 1; }
/bin/cp "$BUNDLED_MAIN" "$MAIN_SWIFT"

# Pin the tested HID controller source too, avoiding upstream drift during this beta.
UPSTREAM_PIXYCTL="$(/usr/bin/find "$SRC/Sources" -type f -name 'pixyctl.c' -print -quit)"
if [[ -n "$UPSTREAM_PIXYCTL" && -f "$SCRIPT_RES/pixyctl.c" ]]; then
  /bin/cp "$SCRIPT_RES/pixyctl.c" "$UPSTREAM_PIXYCTL"
fi

echo "✅ Unified AppKit source staged (PixyBar UI + Guard automation)."

echo "🔨 Building unified PixyGuard app..."
/bin/chmod +x "$SRC/scripts/build.sh"
(cd "$SRC" && ./scripts/build.sh)
BUILT="$(/usr/bin/find "$SRC" -maxdepth 3 -type d -name 'PixyBar.app' -print -quit)"
[[ -n "$BUILT" ]] || { echo "❌ PixyBar.app not found after build"; exit 1; }

TMPAPP="$TMP/PixyGuard.app"
/usr/bin/ditto "$BUILT" "$TMPAPP"

# CoreMediaIO usage probe: exact mechanism validated on the test Mac.
echo "🔎 Building CoreMediaIO PIXY usage probe..."
/usr/bin/xcrun clang -framework CoreMediaIO -framework CoreFoundation -framework Foundation \
  "$SCRIPT_RES/pixyusage.m" -o "$TMPAPP/Contents/MacOS/pixyusage"
/bin/chmod +x "$TMPAPP/Contents/MacOS/pixyusage"

# Rebrand while preserving upstream icon/resources and its menu-bar look.
/usr/libexec/PlistBuddy -c 'Set :CFBundleName PixyGuard' "$TMPAPP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Add :CFBundleName string PixyGuard' "$TMPAPP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName PixyGuard' "$TMPAPP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string PixyGuard' "$TMPAPP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.rosewavestudio.pixyguard' "$TMPAPP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.5.3-unified' "$TMPAPP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 503' "$TMPAPP/Contents/Info.plist" 2>/dev/null || true

mkdir -p "$TMPAPP/Contents/Resources/PixyGuardNotices"
/bin/cp "$SCRIPT_RES/TERMS.txt" "$SCRIPT_RES/PRIVACY.txt" "$SCRIPT_RES/THIRD-PARTY-NOTICES.txt" "$SCRIPT_RES/LICENSE.txt" "$TMPAPP/Contents/Resources/PixyGuardNotices/"
[[ -n "$UPSTREAM_LICENSE" ]] && /bin/cp "$UPSTREAM_LICENSE" "$TMPAPP/Contents/Resources/PixyGuardNotices/PixyBar-LICENSE.txt"

if [[ -w /Applications ]]; then /bin/rm -rf "$APP"; /usr/bin/ditto "$TMPAPP" "$APP"; else /usr/bin/sudo /bin/rm -rf "$APP"; /usr/bin/sudo /usr/bin/ditto "$TMPAPP" "$APP"; fi

# Seed unified app preferences chosen in wizard.
/usr/bin/defaults write "$BUNDLE_ID" privacyOnLock -bool "$PRIVACY_ON_LOCK"
/usr/bin/defaults write "$BUNDLE_ID" autoTracking -bool "$AUTO_TRACKING"
/usr/bin/defaults write "$BUNDLE_ID" normalWhenIdle -bool "$NORMAL_WHEN_IDLE"
/usr/bin/defaults write "$BUNDLE_ID" uiLanguage -string "$LANG_CODE"


# Finalize the installed application before macOS registers or launches it.
finalize_installed_pixyguard

remove_login_item_named "PixyBar"
remove_login_item_named "PixyGuard"
/usr/bin/osascript <<OSA >/dev/null 2>&1 || true
tell application "System Events"
  make login item at end with properties {name:"PixyGuard", path:"$APP", hidden:false}
end tell
OSA

# Launch once so macOS associates the preserved PixyBar icon/look with PixyGuard.
/bin/killall PixyGuard >/dev/null 2>&1 || true
/bin/killall PixyBar >/dev/null 2>&1 || true
/usr/bin/open "$APP"
sleep 2

open_input_monitoring() {
  /usr/bin/open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent" >/dev/null 2>&1 || /usr/bin/open -a "System Settings" >/dev/null 2>&1 || true
  sleep 1
  /usr/bin/osascript -e 'tell application "System Settings" to activate' >/dev/null 2>&1 || true
}
open_input_monitoring

while true; do
  if [[ "$LANG_CODE" == "pt-BR" ]]; then
    ACTION=$(/usr/bin/osascript <<'OSA' 2>/dev/null || true
button returned of (display dialog "Ajustes do Sistema deve estar aberto em:\nPrivacidade e Segurança → Monitoramento de Entrada\n\n1. Habilite PixyGuard.\n2. Se o macOS pedir, escolha Encerrar e Reabrir.\n3. Confirme que o PixyGuard mostra Conectada.\n\nDepois clique Verificar permissão." buttons {"Abrir Ajustes novamente", "Verificar permissão"} default button "Verificar permissão" with title "PixyGuard · Controle da câmera")
OSA
)
    [[ "$ACTION" == "Abrir Ajustes novamente" ]] && { open_input_monitoring; continue; }
  else
    ACTION=$(/usr/bin/osascript <<'OSA' 2>/dev/null || true
button returned of (display dialog "System Settings should be open at:\nPrivacy & Security → Input Monitoring\n\n1. Enable PixyGuard.\n2. If macOS asks, choose Quit & Reopen.\n3. Confirm PixyGuard shows Connected.\n\nThen click Verify Permission." buttons {"Open Settings Again", "Verify Permission"} default button "Verify Permission" with title "PixyGuard · Camera Control")
OSA
)
    [[ "$ACTION" == "Open Settings Again" ]] && { open_input_monitoring; continue; }
  fi

  PIXYCTL="$APP/Contents/MacOS/pixyctl"
  set +e; TEST_OUTPUT="$("$PIXYCTL" mode normal 2>&1)"; RC=$?; set -e
  print -r -- "$TEST_OUTPUT"
  if [[ $RC -eq 0 ]] && ! print -r -- "$TEST_OUTPUT" | /usr/bin/grep -qiE 'could not open|not permitted|not available|error'; then break; fi
  open_input_monitoring
  sleep 1
done

echo "✅ PIXY HID control responded."
finish_status success
trap - EXIT

if [[ "$LANG_CODE" == "pt-BR" ]]; then

echo "🚀 Ensuring PixyGuard is running..."
local_lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$local_lsregister" -f "$APP" >/dev/null 2>&1 || true
/usr/bin/open "$APP"
launched=0
for _ in {1..20}; do
  if /usr/bin/pgrep -f "$APP/Contents/MacOS/PixyGuard" >/dev/null 2>&1; then
    launched=1
    break
  fi
  /bin/sleep 0.25
done
if [[ "$launched" -eq 1 ]]; then
  echo "✅ PixyGuard is running."
else
  echo "⚠️ PixyGuard installed successfully but did not remain open."
fi

  FINAL="PixyGuard $VERSION está pronto.\n\nUm único ícone na barra de menus, com o visual do PixyBar, PTZ/presets e automações Guard no mesmo app.\n\nCreated by Fábio Vamp 😎"; BTN="Concluir"
else
  FINAL="PixyGuard $VERSION is ready.\n\nOne menu-bar icon with the PixyBar look, PTZ/presets and Guard automation in the same app.\n\nCreated by Fábio Vamp 😎"; BTN="Finish"
fi
/usr/bin/osascript - "$FINAL" "$BTN" <<'OSA' >/dev/null 2>&1 || true
on run argv
  display dialog (item 1 of argv) buttons {(item 2 of argv)} default button (item 2 of argv) with title "PixyGuard"
end run
OSA

echo ""
echo "PixyGuard $VERSION READY"
echo "Created by Fábio Vamp 😎"
read -r "?Press Enter to close..."
