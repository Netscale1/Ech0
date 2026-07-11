#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
dotnet_bin="${DOTNET_BIN:-dotnet}"
output_dir="$repo_root/dist/windows"

rm -rf "$output_dir"
mkdir -p "$output_dir"
DOTNET_CLI_TELEMETRY_OPTOUT=1 "$dotnet_bin" publish \
  "$repo_root/windows/Ech0Windows/Ech0Windows.csproj" \
  -c Release \
  -r win-x64 \
  --self-contained true \
  -o "$output_dir/publish"

cp "$output_dir/publish/Ech0Windows.exe" "$output_dir/Ech0Windows.exe"
cp "$repo_root/windows/Update-Ech0.cmd" "$output_dir/Update-Ech0.cmd"
(cd "$output_dir" && zip -q Ech0Windows-win-x64.zip Ech0Windows.exe)
(cd "$output_dir" && zip -q Ech0Windows-update.zip Ech0Windows.exe Update-Ech0.cmd)
shasum -a 256 \
  "$output_dir/Ech0Windows.exe" \
  "$output_dir/Ech0Windows-win-x64.zip" \
  "$output_dir/Ech0Windows-update.zip" > "$output_dir/SHA256SUMS"

echo "$output_dir/Ech0Windows-win-x64.zip"
