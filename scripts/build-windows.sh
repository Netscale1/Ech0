#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
dotnet_bin="${DOTNET_BIN:-dotnet}"
output_dir="$repo_root/dist/windows"
nuget_source="https://api.nuget.org/v3/index.json"

DOTNET_CLI_TELEMETRY_OPTOUT=1 "$dotnet_bin" restore \
  "$repo_root/windows/Ech0Windows.Tests/Ech0Windows.Tests.csproj" \
  --source "$nuget_source"

DOTNET_CLI_TELEMETRY_OPTOUT=1 "$dotnet_bin" test \
  "$repo_root/windows/Ech0Windows.Tests/Ech0Windows.Tests.csproj" \
  -c Release \
  --no-restore

rm -rf "$output_dir"
mkdir -p "$output_dir"
DOTNET_CLI_TELEMETRY_OPTOUT=1 "$dotnet_bin" publish \
  "$repo_root/windows/Ech0Windows/Ech0Windows.csproj" \
  -c Release \
  -r win-x64 \
  --self-contained true \
  --no-restore \
  -o "$output_dir/publish"

cp "$output_dir/publish/Ech0Windows.exe" "$output_dir/Ech0Windows.exe"
cp "$repo_root/LICENSE" "$output_dir/LICENSE"
cp "$repo_root/NOTICE" "$output_dir/NOTICE"
cp "$repo_root/THIRD_PARTY_NOTICES.md" "$output_dir/THIRD_PARTY_NOTICES.md"
(cd "$output_dir" && zip -q Ech0Windows-win-x64.zip \
  Ech0Windows.exe LICENSE NOTICE THIRD_PARTY_NOTICES.md)
shasum -a 256 \
  "$output_dir/Ech0Windows.exe" \
  "$output_dir/Ech0Windows-win-x64.zip" > "$output_dir/SHA256SUMS"

echo "Unsigned community build: no automatic update package was created." >&2
echo "$output_dir/Ech0Windows-win-x64.zip"
