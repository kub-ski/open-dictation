#!/usr/bin/env bash
#
# Open Dictation setup. Safe to run again: it only redoes what is missing or changed.
#
#   ./setup.sh                      asks 3 questions (name, language, hotkey)
#   ./setup.sh --name "Whisperer" --language auto --hotkey fn --yes     no questions
#
# Flags: --name  --language (auto, en, pl, de, …)  --hotkey (fn, right-option, right-command,
#        right-control, left-control)  --model (base, small, medium, large-v3-turbo)  --yes  --no-launch
#
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAME=""; LANGUAGE=""; HOTKEY=""; MODEL=""; YES=0; LAUNCH=1; TESTHOOKS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --language) LANGUAGE="$2"; shift 2 ;;
    --hotkey) HOTKEY="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    --test-hooks) TESTHOOKS=true; shift ;;
    -h|--help) sed -n 2,10p "$0"; exit 0 ;;
    *) echo "setup: unknown option $1" >&2; exit 2 ;;
  esac
done

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nsetup: %s\n' "$*" >&2; exit 1; }
slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }

[ "$(uname -s)" = Darwin ] || die "this only runs on a Mac."
[ "$(uname -m)" = arm64 ] || die "this needs an Apple Silicon Mac (M1 or newer)."
OSV="$(sw_vers -productVersion)"; MAJOR="${OSV%%.*}"; MINOR="$(printf '%s' "$OSV" | cut -d. -f2)"; MINOR="${MINOR:-0}"
if [ "$MAJOR" -lt 14 ] || { [ "$MAJOR" -eq 14 ] && [ "$MINOR" -lt 2 ]; }; then die "this needs macOS 14.2 (Sonoma) or newer. You have $OSV."; fi

# ---- 1. the three questions ----------------------------------------------------------------
ask() { # ask "<question>" "<default>" -> prints the answer
  local q="$1" d="$2" a=""
  if [ "$YES" = 1 ] || [ ! -t 0 ]; then printf '%s' "$d"; return; fi
  read -r -p "$q [$d] " a || true
  printf '%s' "${a:-$d}"
}
OLD_CFG="$HOME/.$(slugify "${NAME:-OpenDictation}")/config.json"
cfg_get() { [ -f "$OLD_CFG" ] && /usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$OLD_CFG" "$1" 2>/dev/null || true; }

say "Open Dictation setup"
[ -n "$NAME" ]     || NAME="$(ask "1/3  What should your app be called?" "OpenDictation")" 
OLD_CFG="$HOME/.$(slugify "$NAME")/config.json"
if [ -z "$LANGUAGE" ]; then D="$(cfg_get language || true)"; LANGUAGE="$(ask "2/3  Language you speak (auto = detect it, or en, pl, de, es, fr…)?" "${D:-auto}")"; fi
[ -n "$LANGUAGE" ] || LANGUAGE="auto"
if [ -z "$HOTKEY" ]; then D="$(cfg_get hotkey || true)"; HOTKEY="$(ask "3/3  Hotkey (fn, right-option, right-command, right-control, left-control)?" "${D:-fn}")"; fi
[ -n "$HOTKEY" ]   || HOTKEY="fn"

case "$NAME" in *[!A-Za-z0-9\ -]*|"") die "the name can only use letters, numbers, spaces and dashes." ;; esac
SLUG="$(slugify "$NAME")"; [ -n "$SLUG" ] || die "the name needs at least one letter or number."
LANGUAGE="$(printf '%s' "$LANGUAGE" | tr '[:upper:]' '[:lower:]')"
case "$LANGUAGE" in *[!a-z-]*|"") die "language must be a code like auto, en or pl." ;; esac
case "$HOTKEY" in fn|right-option|right-command|right-control|left-control) ;; *) die "hotkey must be fn, right-option, right-command, right-control or left-control." ;; esac
PACK=en; [ "$LANGUAGE" = pl ] && PACK=pl
# Running setup again keeps what you set before (model, test URLs, AI polish) unless you pass a flag.
if [ -z "$MODEL" ]; then
  OLD_MODEL="$(cfg_get model || true)"
  case "$OLD_MODEL" in ggml-base.bin) MODEL=base ;; ggml-medium.bin) MODEL=medium ;; ggml-large-v3-turbo.bin) MODEL=large-v3-turbo ;; *) MODEL=small ;; esac
fi
if [ -z "$TESTHOOKS" ]; then TESTHOOKS="$(cfg_get testHooks || true)"; case "$TESTHOOKS" in True|true) TESTHOOKS=true ;; *) TESTHOOKS=false ;; esac; fi

case "$MODEL" in
  base) MODEL_FILE=ggml-base.bin;  MODEL_SIZE="about 140 MB" ;;
  small) MODEL_FILE=ggml-small.bin; MODEL_SIZE="about 470 MB" ;;
  medium) MODEL_FILE=ggml-medium.bin; MODEL_SIZE="about 1.5 GB" ;;
  large-v3-turbo) MODEL_FILE=ggml-large-v3-turbo.bin; MODEL_SIZE="about 1.6 GB" ;;
  *) die "model must be base, small, medium or large-v3-turbo." ;;
esac
SUPPORT="$HOME/.$SLUG"
echo "App: $NAME   Language: $LANGUAGE   Hotkey: $HOTKEY   Model: $MODEL ($MODEL_SIZE)"

# ---- 2. prerequisites ----------------------------------------------------------------------
say "Checking Xcode Command Line Tools"
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1 || true
  die "Apple's Command Line Tools are installing (a window just opened). Wait for it to finish, then run ./setup.sh again."
fi
echo "ok"

say "Checking Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)" && break; done
fi
if ! command -v brew >/dev/null 2>&1; then
  [ -t 0 ] || die "Homebrew is missing, and installing it needs your Mac password in Terminal. Open Terminal, paste the one-line command from https://brew.sh, enter your password when asked, then run ./setup.sh again."
  echo "Installing Homebrew (it will ask for your Mac password)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
echo "ok ($(command -v brew))"

say "Checking whisper.cpp and ffmpeg"
# A whisper-cli you built yourself can live in ~/.<name>/bin (the app looks there first).
export PATH="$HOME/.$SLUG/bin:$PATH"
brew_install() {
  brew install "$1" || die "Homebrew could not install $1. If it says /opt/homebrew is not writable, run the 'sudo chown' command it prints, then run ./setup.sh again."
}
command -v whisper-cli >/dev/null 2>&1 || { echo "installing whisper-cpp…"; brew_install whisper-cpp; }
command -v ffmpeg >/dev/null 2>&1      || { echo "installing ffmpeg…"; brew_install ffmpeg; }
command -v whisper-cli >/dev/null 2>&1 || die "whisper-cli still not found after install."
echo "ok"

# ---- 3. model ------------------------------------------------------------------------------
say "Speech model ($MODEL_FILE, $MODEL_SIZE)"
mkdir -p "$SUPPORT/models"
DEST="$SUPPORT/models/$MODEL_FILE"
if [ -s "$DEST" ] && [ "$(stat -f%z "$DEST")" -gt 100000000 ]; then
  echo "already downloaded: $DEST"
else
  curl -L --fail --retry 3 -C - -o "$DEST.part" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_FILE"
  mv "$DEST.part" "$DEST"
fi

# ---- 4. config -----------------------------------------------------------------------------
say "Saving settings to $SUPPORT/config.json"
AIPOLISH=auto; OLD_AI="$(cfg_get aiPolish || true)"; [ -n "$OLD_AI" ] && AIPOLISH="$OLD_AI"
cat > "$SUPPORT/config.json" <<JSON
{
  "language": "$LANGUAGE",
  "pack": "$PACK",
  "hotkey": "$HOTKEY",
  "aiPolish": "$AIPOLISH",
  "model": "$MODEL_FILE",
  "testHooks": $TESTHOOKS
}
JSON
cat "$SUPPORT/config.json"

# ---- 5. signing identity (keeps your permissions across rebuilds) ---------------------------
# A small keychain of its own holds the key, so your login keychain is never touched and no
# password prompt appears. The key only signs this app on this Mac.
say "Signing identity"
ID="$NAME Self-Signed"
KC="$HOME/Library/Keychains/$SLUG-signing.keychain-db"
if [ -f "$KC" ]; then
  security unlock-keychain -p "" "$KC" 2>/dev/null || true
fi
if [ -f "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "\"$ID\""; then
  echo "already there: $ID"
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $ID
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  PASS="$(openssl rand -hex 12)"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/openssl.cnf" \
      -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$PASS" >/dev/null 2>&1
  [ -f "$KC" ] || security create-keychain -p "" "$KC"
  security set-keychain-settings "$KC"            # never auto-lock
  security unlock-keychain -p "" "$KC"
  security import "$TMP/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KC" >/dev/null 2>&1 || true
  echo "created: $ID (in its own keychain: $KC)"
fi
# codesign finds identities through the keychain search list: make sure ours is on it
if ! security list-keychains -d user | grep -q "$SLUG-signing"; then
  CUR=(); while IFS= read -r l; do l="${l#*\"}"; l="${l%\"*}"; [ -n "$l" ] && CUR+=("$l"); done < <(security list-keychains -d user)
  security list-keychains -d user -s "$KC" ${CUR[@]+"${CUR[@]}"}
fi

# ---- 6. build and install ------------------------------------------------------------------
say "Building $NAME (the first build takes a minute or two)"
pkill -f "$HOME/Applications/$NAME.app/Contents/MacOS/" 2>/dev/null || true   # only our own copy
"$REPO/build.sh" "$NAME"
"$HOME/Applications/$NAME.app/Contents/MacOS/$NAME" --check | tail -1

# ---- 7. done -------------------------------------------------------------------------------
say "Installed: ~/Applications/$NAME.app"
cat <<TXT

Two settings to finish (details in the README):
  1. System Settings > Keyboard > "Press 🌐 key to" > Do Nothing   (only if your hotkey is Fn)
  2. When $NAME opens, allow Microphone, then add it in System Settings > Privacy & Security to
     Accessibility and Input Monitoring.

TXT
if [ "$LAUNCH" = 1 ]; then open "$HOME/Applications/$NAME.app"; echo "$NAME is starting: look for the microphone icon in the menu bar."; fi
