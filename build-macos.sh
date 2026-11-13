#!/bin/sh
set -eu
cd "$(dirname "$0")"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"

cargo build --release --lib
swift package resolve --disable-sandbox
APP="target/PgQuery.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
sparkle_framework="$(find .build/artifacts -type d -name Sparkle.framework -print -quit)"
if [ -z "$sparkle_framework" ]; then
  echo "Sparkle.framework was not found after resolving Swift packages" >&2
  exit 1
fi
swiftc -parse-as-library \
  -module-cache-path target/swift-module-cache \
  -import-objc-header macos/PgQueryCore.h \
  macos/PgQuery.swift target/release/libpgquery_core.a \
  -o "$APP/Contents/MacOS/PgQuery" \
  -framework AppKit -framework Security -framework SystemConfiguration \
  -F "$(dirname "$sparkle_framework")" -framework Sparkle \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks'
ditto "$sparkle_framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp macos/Info.plist "$APP/Contents/Info.plist"
cp macos/PkgInfo "$APP/Contents/PkgInfo"
swift -module-cache-path target/swift-module-cache macos/make-icon.swift "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${PGQUERY_VERSION:-0.1.1}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${PGQUERY_BUILD_NUMBER:-1}" "$APP/Contents/Info.plist"
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey ${SPARKLE_PUBLIC_ED_KEY}" "$APP/Contents/Info.plist"
fi
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  # A self-signed certificate has no Team ID. Sparkle's privileged updater
  # helpers enforce matching Team IDs when they are conventionally signed,
  # which makes those helpers unable to talk to this app. Keep the app signed
  # with its stable identity for update validation, but ad-hoc sign Sparkle's
  # nested code so its helper IPC does not require a Team ID.
  codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force --sign "$CODESIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
printf 'Built %s\n' "$APP"
