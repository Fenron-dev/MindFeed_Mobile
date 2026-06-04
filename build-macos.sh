#!/bin/bash
# MindFeed macOS Build-Skript
#
# Verwendet einen externen Derived-Data-Pfad (/tmp) um den bekannten
# iCloud-Drive-Codesign-Fehler zu umgehen:
#   "resource fork, Finder information, or similar detritus not allowed"
#
# Falls das Projekt NICHT in einem iCloud-synchronisierten Ordner liegt,
# kann auch einfach `flutter build macos` verwendet werden.

set -e

DERIVED=/tmp/MindFeedDerived
OBJ=/tmp/MindFeedObj
SYM=/tmp/MindFeedSym
CONFIG="${1:-Debug}"   # Debug | Release | Profile

echo "→ flutter pub get"
flutter pub get

echo "→ flutter config (pod install etc.)"
flutter build macos --config-only

echo "→ xcodebuild -configuration $CONFIG"
cd macos
/usr/bin/arch -arm64e xcrun xcodebuild \
  -workspace Runner.xcworkspace \
  -scheme Runner \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  OBJROOT="$OBJ" \
  SYMROOT="$SYM" \
  2>&1 | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)|note:" | grep -v "note:.*run.*script"

echo ""
echo "✓ App liegt in: $SYM/$CONFIG/mindfeed_mobile.app"
echo "  Starte mit: open \"$SYM/$CONFIG/mindfeed_mobile.app\""
