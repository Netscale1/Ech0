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
development_archive="$dist_dir/Ech0Mac-$release_version-development.zip"
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
  check             Run the strict Swift tests, build the app ad-hoc, build and
                    smoke-test the unsigned HAL driver, and validate structure.
  sign-local        Sign the built app and driver with the identity in
                    ECH0_MACOS_SIGNING_IDENTITY, then verify both bundles.
  package-dev       Create an explicitly non-release ZIP from checked artifacts.
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

  [[ "$(plutil -extract CFBundleIdentifier raw "$app_bundle/Contents/Info.plist")" == "net.ech0.mac" ]] ||
    fail "unexpected app bundle identifier"
  [[ "$(plutil -extract CFBundleIdentifier raw "$driver_bundle/Contents/Info.plist")" == "net.ech0.virtual-mic" ]] ||
    fail "unexpected driver bundle identifier"

  file "$app_binary" | grep -F "Mach-O 64-bit executable arm64" >/dev/null ||
    fail "app executable is not a 64-bit arm64 Mach-O"
  file "$driver_binary" | grep -F "Mach-O 64-bit bundle arm64" >/dev/null ||
    fail "driver executable is not a 64-bit arm64 Mach-O bundle"

  codesign --verify --deep --strict "$app_bundle" ||
    fail "app signature validation failed"
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
  validate_structure

  print "macOS check passed"
  shasum -a 256 "$app_binary" "$driver_binary"
  print "The app is ad-hoc signed and the driver is unsigned; neither is an official release."
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

package_development()
{
  require_command ditto
  require_artifacts
  validate_structure

  cleanup_stage="$(mktemp -d /private/tmp/ech0-development-package.XXXXXX)"
  cleanup_temporary_artifact="$(mktemp /private/tmp/ech0-development-package.XXXXXX)"

  mkdir -p "$cleanup_stage/Ech0Mac-$release_version-development"
  ditto "$app_bundle" "$cleanup_stage/Ech0Mac-$release_version-development/Ech0Mac.app"
  ditto "$driver_bundle" "$cleanup_stage/Ech0Mac-$release_version-development/Ech0VirtualMic.driver"
  cp "$repo_root/docs/macos-release.md" "$cleanup_stage/Ech0Mac-$release_version-development/INSTALL.md"

  COPYFILE_DISABLE=1 ditto \
    -c \
    -k \
    --norsrc \
    --noextattr \
    --noqtn \
    --noacl \
    --keepParent \
    "$cleanup_stage/Ech0Mac-$release_version-development" \
    "$cleanup_temporary_artifact"
  mv -f "$cleanup_temporary_artifact" "$development_archive"
  cleanup_temporary_artifact=""

  print "$development_archive"
  shasum -a 256 "$development_archive"
  print "Development package created. It is not a notarized public release."
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
    --identifier net.ech0.macos \
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
  package-dev)
    package_development
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
