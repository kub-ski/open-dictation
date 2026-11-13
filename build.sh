#!/usr/bin/env bash
#
# build.sh "<App Name>"  — compile the app and assemble a signed <App Name>.app in ~/Applications.
# setup.sh calls this for you. You can also run it by hand after changing the code.
#
set -euo pipefail

NAME="${1:-OpenDictation}"
SLUG="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
[ -n "$SLUG" ] || { echo "build: the name needs at least one letter or number" >&2; exit 1; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use Xcode only when its license is accepted; otherwise the Command Line Tools work fine.
if [ -d /Applications/Xcode.app ] && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
   /usr/bin/xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  echo "build: toolchain = Xcode"
else
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  echo "build: toolchain = Command Line Tools"
fi

SCRATCH="$HOME/.$SLUG/build"
APP="$HOME/Applications/$NAME.app"

echo "build: compiling (release)…"
swift build -c release -Xswiftc -suppress-warnings --package-path "$REPO" --scratch-path "$SCRATCH"
BIN="$(swift build -c release --package-path "$REPO" --scratch-path "$SCRATCH" --show-bin-path)/OpenDictation"
[ -f "$BIN" ] || { echo "build: binary not found at $BIN" >&2; exit 1; }

echo "build: assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/prompts"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
sed -e "s/__NAME__/$NAME/g" -e "s/__SLUG__/$SLUG/g" "$REPO/Info.plist.template" > "$APP/Contents/Info.plist"
cp "$REPO"/prompts/*.md "$APP/Contents/Resources/prompts/"

# A stable signing identity keeps your Microphone / Accessibility permissions across rebuilds.
# setup.sh creates "<Name> Self-Signed"; without it we sign ad-hoc and macOS asks again after every rebuild.
# The hardened runtime stops other programs from loading their code into the app (DYLD_INSERT_LIBRARIES)
# and borrowing its Microphone / Accessibility / Input Monitoring permissions. The microphone then needs
# the entitlement in OpenDictation.entitlements.
ID="$NAME Self-Signed"
SIGN=(--force --deep --options runtime --entitlements "$REPO/OpenDictation.entitlements")
if codesign "${SIGN[@]}" --sign "$ID" "$APP" 2>/dev/null; then
  echo "build: signed with \"$ID\""
else
  codesign "${SIGN[@]}" --sign - "$APP"
  echo "build: signed ad-hoc (no \"$ID\" identity found; permissions will reset on each rebuild)"
fi
echo "build: done → $APP"
