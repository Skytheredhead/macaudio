#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

echo "==> Building MacAudio and VirtualMic driver"
xcodegen generate
xcodebuild -project MacAudio.xcodeproj -scheme MacAudio -configuration Debug -destination 'platform=macOS' build

DRIVER_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*MacAudio*Build/Products/Debug/VirtualMic.driver' -maxdepth 8 | head -n 1)"
if [[ -z "${DRIVER_PATH:-}" ]]; then
  echo "ERROR: Could not find built VirtualMic.driver in DerivedData."
  read -r "?Press Enter to close..."
  exit 1
fi

echo "==> Installing driver (macOS will ask for your admin password)"
osascript - "$DRIVER_PATH" <<'APPLESCRIPT'
on run argv
  set driverPath to item 1 of argv
  set targetDir to "/Library/Audio/Plug-Ins/HAL"
  set installedDriver to targetDir & "/VirtualMic.driver"
  set cmd to "mkdir -p " & quoted form of targetDir & "; " & "rm -rf " & quoted form of installedDriver & "; " & "cp -R " & quoted form of driverPath & " " & quoted form of installedDriver & "; " & "chown -R root:wheel " & quoted form of installedDriver & "; " & "chmod -R 755 " & quoted form of installedDriver & "; " & "launchctl kickstart -k system/com.apple.audio.coreaudiod || true"
  do shell script cmd with administrator privileges
end run
APPLESCRIPT

echo
if spctl --assess -vv "/Library/Audio/Plug-Ins/HAL/VirtualMic.driver" >/dev/null 2>&1; then
  echo "==> Driver accepted by macOS security"
else
  echo "==> Driver installed, but macOS security is rejecting it"
  echo "    Virtual Mic will not appear until the HAL bundle is signed with a real Apple code-signing identity."
fi

APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*MacAudio*Build/Products/Debug/MacAudio.app' -maxdepth 8 -print0 | xargs -0 ls -td | head -n 1)"
if [[ -z "${APP_PATH:-}" ]]; then
  echo "ERROR: Build finished but MacAudio.app was not found."
  read -r "?Press Enter to close..."
  exit 1
fi

echo "==> Launching MacAudio"
pkill -x MacAudio || true
sleep 1
open -n "$APP_PATH"

echo
echo "Done. In Discord, set Input Device to: Virtual Mic"
read -r "?Press Enter to close..."
