#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

xcodebuild -project MacAudio.xcodeproj -scheme MacAudio -configuration Debug -destination 'platform=macOS' build >/tmp/macaudio-build.log

APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*MacAudio*Build/Products/Debug/MacAudio.app' -maxdepth 8 -print0 | xargs -0 ls -td | head -n 1)"
if [[ -z "${APP_PATH:-}" ]]; then
  echo "ERROR: Build finished but MacAudio.app was not found."
  read -r "?Press Enter to close..."
  exit 1
fi

pkill -x MacAudio || true
sleep 1
open -n "$APP_PATH"
