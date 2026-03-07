#!/usr/bin/env zsh
set -euo pipefail

TARGET="/Library/Audio/Plug-Ins/HAL/VirtualMic.driver"

echo "Removing $TARGET"
sudo rm -rf "$TARGET"
sudo launchctl kickstart -k system/com.apple.audio.coreaudiod || true

echo "Uninstalled VirtualMic driver."
