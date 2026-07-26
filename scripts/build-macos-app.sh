#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
output_dir="$repo_root/dist/macos"
app_dir="$output_dir/Ech0Mac.app"

swift test \
  --package-path "$repo_root/macos" \
  -Xswiftc -warn-concurrency \
  -Xswiftc -strict-concurrency=complete
swift build --package-path "$repo_root/macos" -c release
binary_dir="$(swift build --package-path "$repo_root/macos" -c release --show-bin-path)"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$binary_dir/Ech0Mac" "$app_dir/Contents/MacOS/Ech0Mac"
cp "$repo_root/macos/Info.plist" "$app_dir/Contents/Info.plist"
xcrun actool "$repo_root/macos/Resources/Ech0StatusAssets.xcassets" \
  --compile "$app_dir/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --output-format human-readable-text \
  --warnings \
  --notices
for asset in "$repo_root"/macos/Resources/Ech0Brand*.png; do
  cp "$asset" "$app_dir/Contents/Resources/"
done
cp "$repo_root/macos/Resources/Ech0.icns" "$app_dir/Contents/Resources/Ech0.icns"

signing_identity="${ECH0_CODESIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Apple Development:/{print $2; exit}'
  )"
fi

if [[ -n "$signing_identity" ]]; then
  codesign --force --deep --options runtime --sign "$signing_identity" "$app_dir"
else
  codesign --force --deep --sign - "$app_dir"
fi

codesign --verify --deep --strict "$app_dir"
plutil -lint "$app_dir/Contents/Info.plist"
echo "$app_dir"
