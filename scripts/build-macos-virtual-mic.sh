#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
source_dir="$repo_root/macos/Driver/Ech0VirtualMic"
bundle_dir="$repo_root/dist/macos/Ech0VirtualMic.driver"
binary_dir="$bundle_dir/Contents/MacOS"
smoke_binary="$repo_root/dist/macos/Ech0VirtualMicSmoke"

rm -rf "$bundle_dir"
mkdir -p "$binary_dir"
cp "$source_dir/Info.plist" "$bundle_dir/Contents/Info.plist"

xcrun --sdk macosx clang \
  -std=c11 \
  -fblocks \
  -mmacosx-version-min=13.0 \
  -bundle \
  -Wl,-no_adhoc_codesign \
  -framework CoreAudio \
  -framework CoreFoundation \
  "$source_dir/Ech0VirtualMic.c" \
  -o "$binary_dir/Ech0VirtualMic"

xcrun --sdk macosx clang \
  -std=c11 \
  -fblocks \
  -mmacosx-version-min=13.0 \
  -framework CoreAudio \
  -framework CoreFoundation \
  "$source_dir/Ech0VirtualMic.c" \
  "$source_dir/Ech0VirtualMicSmoke.c" \
  -o "$smoke_binary"

plutil -lint "$bundle_dir/Contents/Info.plist"
file "$binary_dir/Ech0VirtualMic"
"$smoke_binary"
echo "$bundle_dir"
