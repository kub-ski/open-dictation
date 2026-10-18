#!/usr/bin/env bash
# uninstall.sh "<App Name>"  — removes the app, its signing keychain, and (if you say yes) its settings and history.
set -euo pipefail
NAME="${1:?usage: ./uninstall.sh \"<App Name>\"}"
case "$NAME" in *[!A-Za-z0-9\ -]*|"") echo "uninstall: bad name" >&2; exit 2 ;; esac
SLUG="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
KC="$HOME/Library/Keychains/$SLUG-signing.keychain-db"
pkill -f "$HOME/Applications/$NAME.app/Contents/MacOS/" 2>/dev/null || true
if [ -d "$HOME/Applications/$NAME.app" ]; then rm -rf "$HOME/Applications/$NAME.app"; echo "removed ~/Applications/$NAME.app"; fi
if [ -f "$KC" ]; then
  CUR=(); while IFS= read -r l; do l="${l#*\"}"; l="${l%\"*}"; [ -n "$l" ] && [ "$l" != "$KC" ] && CUR+=("$l"); done < <(security list-keychains -d user)
  security list-keychains -d user -s ${CUR[@]+"${CUR[@]}"}
  security delete-keychain "$KC" 2>/dev/null || true
  echo "removed signing keychain"
fi
if [ -d "$HOME/.$SLUG" ]; then
  read -r -p "Also delete ~/.$SLUG (settings, history, the speech model)? [y/N] " a || a=n
  [ "$a" = y ] || [ "$a" = Y ] && { rm -rf "$HOME/.$SLUG"; echo "removed ~/.$SLUG"; } || echo "kept ~/.$SLUG"
fi
echo "Also remove $NAME from System Settings > Privacy & Security (Accessibility, Input Monitoring) with the minus button."
