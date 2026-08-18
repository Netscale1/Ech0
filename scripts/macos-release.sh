#!/bin/zsh
set -euo pipefail

export LC_ALL=C
export LANG=C
export TZ=UTC
export ZERO_AR_DATE=1

repo_root="${0:A:h:h}"
dist_dir="$repo_root/dist/macos"
app_bundle="$dist_dir/Ech0Mac.app"
driver_bundle="$dist_dir/Ech0VirtualMic.driver"
app_binary="$app_bundle/Contents/MacOS/Ech0Mac"
driver_binary="$driver_bundle/Contents/MacOS/Ech0VirtualMic"
release_version="$(
  plutil -extract CFBundleShortVersionString raw "$repo_root/macos/Info.plist"
)"
community_archive="$dist_dir/Ech0Mac-$release_version-community.zip"
official_package="$dist_dir/Ech0Mac-$release_version.pkg"
cleanup_stage=""
cleanup_temporary_artifact=""

cleanup()
{
  if [[ -n "$cleanup_stage" && -d "$cleanup_stage" ]]; then
    rm -rf "$cleanup_stage"
  fi
  if [[ -n "$cleanup_temporary_artifact" && -f "$cleanup_temporary_artifact" ]]; then
    rm -f "$cleanup_temporary_artifact"
  fi
}

trap cleanup EXIT

fail()
{
  print -u2 "error: $1"
  exit 1
}

usage()
{
  cat <<'EOF'
Usage: ./scripts/macos-release.sh <command>

Commands:
  check             Run the strict Swift tests, build the app and HAL driver
                    with ad-hoc signatures, smoke-test, and validate structure.
  sign-local        Sign the built app and driver with the identity in
                    ECH0_MACOS_SIGNING_IDENTITY, then verify both bundles.
  package-community Create an explicitly unnotarized ZIP from checked artifacts.
  package-official  Require Developer ID Application and Installer identities,
                    sign both bundles, and create a signed installer package.
  notarize          Submit the signed installer with the externally provisioned
                    keychain profile in ECH0_NOTARY_KEYCHAIN_PROFILE, then staple
                    and validate the notarization ticket.
EOF
}

require_command()
{
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_artifacts()
{
  [[ -x "$app_binary" ]] ||
    fail "missing app artifact; run './scripts/macos-release.sh check' first"
  [[ -x "$driver_binary" ]] ||
    fail "missing driver artifact; run './scripts/macos-release.sh check' first"
}

require_identity()
{
  local identity="$1"
  local variable_name="$2"
  [[ -n "$identity" ]] ||
    fail "$variable_name is required and must name a keychain signing identity"
  security find-identity -v 2>/dev/null |
    grep -F -- "$identity" >/dev/null ||
    fail "signing identity from $variable_name was not found or is not valid"
}

validate_structure()
{
  require_artifacts

  plutil -lint "$app_bundle/Contents/Info.plist" >/dev/null
  plutil -lint "$driver_bundle/Contents/Info.plist" >/dev/null

  [[ "$(plutil -extract CFBundleIdentifier raw "$app_bundle/Contents/Info.plist")" == "io.github.netscale1.ech0" ]] ||
    fail "unexpected app bundle identifier"
  [[ "$(plutil -extract CFBundleIdentifier raw "$driver_bundle/Contents/Info.plist")" == "io.github.netscale1.ech0.virtual-mic" ]] ||
    fail "unexpected driver bundle identifier"
  [[ "$(plutil -extract CFBundleShortVersionString raw "$driver_bundle/Contents/Info.plist")" == "$release_version" ]] ||
    fail "app and driver release versions do not match"

  file "$app_binary" | grep -F "Mach-O 64-bit executable arm64" >/dev/null ||
    fail "app executable is not a 64-bit arm64 Mach-O"
  file "$driver_binary" | grep -F "Mach-O 64-bit bundle arm64" >/dev/null ||
    fail "driver executable is not a 64-bit arm64 Mach-O bundle"

  codesign --verify --deep --strict "$app_bundle" ||
    fail "app signature validation failed"
  codesign --verify --strict "$driver_bundle" ||
    fail "driver signature validation failed"
}

require_adhoc_signatures()
{
  codesign -dv --verbose=4 "$app_bundle" 2>&1 |
    grep -F "Signature=adhoc" >/dev/null ||
    fail "community app must use an ad-hoc signature"
  codesign -dv --verbose=4 "$driver_bundle" 2>&1 |
    grep -F "Signature=adhoc" >/dev/null ||
    fail "community driver must use an ad-hoc signature"
}

sign_bundles()
{
  local identity="$1"
  local timestamp_option="$2"

  codesign \
    --force \
    --options runtime \
    "$timestamp_option" \
    --sign "$identity" \
    "$driver_bundle"
  codesign \
    --force \
    --deep \
    --options runtime \
    "$timestamp_option" \
    --sign "$identity" \
    "$app_bundle"

  codesign --verify --deep --strict --verbose=2 "$driver_bundle"
  codesign --verify --deep --strict --verbose=2 "$app_bundle"
}

check_artifacts()
{
  require_command swift
  require_command xcrun
  require_command codesign
  require_command plutil
  require_command file

  ECH0_CODESIGN_IDENTITY=- "$repo_root/scripts/build-macos-app.sh"
  "$repo_root/scripts/build-macos-virtual-mic.sh"
  codesign --force --options runtime --sign - "$driver_bundle"
  validate_structure
  require_adhoc_signatures

  print "macOS check passed"
  shasum -a 256 "$app_binary" "$driver_binary"
  print "The app and driver are ad-hoc signed and are not notarized."
}

sign_local()
{
  require_command security
  require_command codesign
  require_artifacts

  local identity="${ECH0_MACOS_SIGNING_IDENTITY:-}"
  require_identity "$identity" "ECH0_MACOS_SIGNING_IDENTITY"
  sign_bundles "$identity" "--timestamp=none"
  validate_structure
  print "Local signing and strict bundle validation passed."
}

package_community()
{
  require_command ditto
  require_artifacts
  validate_structure
  require_adhoc_signatures

  cleanup_stage="$(mktemp -d /private/tmp/ech0-community-package.XXXXXX)"
  cleanup_temporary_artifact="$(mktemp /private/tmp/ech0-community-package.XXXXXX)"

  local package_root="$cleanup_stage/Ech0Mac-$release_version-community"
  mkdir -p "$package_root"
  ditto "$app_bundle" "$package_root/Ech0Mac.app"
  ditto "$driver_bundle" "$package_root/Ech0VirtualMic.driver"
  cp "$repo_root/docs/macos-release.md" "$package_root/INSTALL.md"
  cp "$repo_root/LICENSE" "$package_root/LICENSE"
  cp "$repo_root/NOTICE" "$package_root/NOTICE"
  cp "$repo_root/THIRD_PARTY_NOTICES.md" "$package_root/THIRD_PARTY_NOTICES.md"
  (
    cd "$package_root"
    shasum -a 256 \
      "Ech0Mac.app/Contents/MacOS/Ech0Mac" \
      "Ech0VirtualMic.driver/Contents/MacOS/Ech0VirtualMic" \
      > "SHA256SUMS"
  )

  COPYFILE_DISABLE=1 ditto \
    -c \
    -k \
    --norsrc \
    --noextattr \
    --noqtn \
    --noacl \
    --keepParent \
    "$package_root" \
    "$cleanup_temporary_artifact"
  mv -f "$cleanup_temporary_artifact" "$community_archive"
  cleanup_temporary_artifact=""

  print "$community_archive"
  shasum -a 256 "$community_archive"
  print "Community package created. It is ad-hoc signed and not notarized."
}

package_official()
{
  require_command security
  require_command codesign
  require_command pkgbuild
  require_command pkgutil
  require_artifacts

  local application_identity="${ECH0_DEVELOPER_ID_APPLICATION:-}"
  local installer_identity="${ECH0_DEVELOPER_ID_INSTALLER:-}"
  [[ "$application_identity" == "Developer ID Application:"* ]] ||
    fail "ECH0_DEVELOPER_ID_APPLICATION must name a Developer ID Application identity"
  [[ "$installer_identity" == "Developer ID Installer:"* ]] ||
    fail "ECH0_DEVELOPER_ID_INSTALLER must name a Developer ID Installer identity"
  require_identity "$application_identity" "ECH0_DEVELOPER_ID_APPLICATION"
  require_identity "$installer_identity" "ECH0_DEVELOPER_ID_INSTALLER"

  sign_bundles "$application_identity" "--timestamp"
  validate_structure

  cleanup_stage="$(mktemp -d /private/tmp/ech0-official-package.XXXXXX)"
  cleanup_temporary_artifact="$(mktemp /private/tmp/ech0-official-package.XXXXXX)"
  rm -f "$cleanup_temporary_artifact"

  mkdir -p \
    "$cleanup_stage/Applications" \
    "$cleanup_stage/Library/Audio/Plug-Ins/HAL"
  ditto "$app_bundle" "$cleanup_stage/Applications/Ech0Mac.app"
  ditto "$driver_bundle" "$cleanup_stage/Library/Audio/Plug-Ins/HAL/Ech0VirtualMic.driver"

  pkgbuild \
    --root "$cleanup_stage" \
    --identifier io.github.netscale1.ech0.package \
    --version "$release_version" \
    --install-location / \
    --ownership recommended \
    --sign "$installer_identity" \
    "$cleanup_temporary_artifact"
  mv -f "$cleanup_temporary_artifact" "$official_package"
  cleanup_temporary_artifact=""

  pkgutil --check-signature "$official_package"
  print "$official_package"
  print "Signed installer created. Run the notarize command before distribution."
}

notarize_package()
{
  require_command xcrun
  require_command pkgutil
  require_command spctl

  local profile="${ECH0_NOTARY_KEYCHAIN_PROFILE:-}"
  [[ -n "$profile" ]] ||
    fail "ECH0_NOTARY_KEYCHAIN_PROFILE is required; provision it outside the repository with 'xcrun notarytool store-credentials'"
  [[ -f "$official_package" ]] ||
    fail "missing signed installer package; run package-official first"
  pkgutil --check-signature "$official_package" >/dev/null ||
    fail "installer signature validation failed before notarization"

  xcrun notarytool submit \
    "$official_package" \
    --keychain-profile "$profile" \
    --wait
  xcrun stapler staple "$official_package"
  xcrun stapler validate "$official_package"
  spctl --assess --verbose=2 --type install "$official_package"
  print "Notarization, stapling, and Gatekeeper validation passed: $official_package"
}

command_name="${1:-}"
case "$command_name" in
  check)
    check_artifacts
    ;;
  sign-local)
    sign_local
    ;;
  package-community)
    package_community
    ;;
  package-official)
    package_official
    ;;
  notarize)
    notarize_package
    ;;
  help|-h|--help)
    usage
    ;;
  "")
    usage
    exit 2
    ;;
  *)
    usage
    fail "unknown command: $command_name"
    ;;
esac
