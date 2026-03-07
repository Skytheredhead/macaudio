#!/usr/bin/env zsh
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <path-to-VirtualMic.driver>"
  exit 1
fi

DRIVER_PATH="$1"
TARGET_DIR="/Library/Audio/Plug-Ins/HAL"

if [[ ! -d "$DRIVER_PATH" ]]; then
  echo "driver bundle not found: $DRIVER_PATH"
  exit 1
fi

echo "Installing $DRIVER_PATH -> $TARGET_DIR"
sudo mkdir -p "$TARGET_DIR"
sudo rm -rf "$TARGET_DIR/VirtualMic.driver"
sudo cp -R "$DRIVER_PATH" "$TARGET_DIR/VirtualMic.driver"
sudo chown -R root:wheel "$TARGET_DIR/VirtualMic.driver"
sudo chmod -R 755 "$TARGET_DIR/VirtualMic.driver"

echo "Restarting coreaudiod"
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod || true

if spctl --assess -vv "$TARGET_DIR/VirtualMic.driver" >/dev/null 2>&1; then
  echo "Installed. Open System Settings -> Sound -> Input and look for 'Virtual Mic'."
else
  echo "Installed, but macOS security is rejecting VirtualMic.driver."
  echo "A real Apple code-signing identity is required before coreaudiod will register it as an input device."
fi
