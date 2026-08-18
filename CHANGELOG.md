# Changelog

All notable user-facing changes are recorded here. Ech0 uses semantic version
tags where practical.

## 0.2.0 - Unreleased

- Added authenticated, encrypted protocol v3 with trusted reconnect.
- Added the input-only Ech0 Virtual Microphone for isolated macOS capture.
- Made BlackHole 2ch an optional fallback instead of a startup prerequisite.
- Added system-wide Core Audio demand detection and reduced macOS UI energy use.
- Added reproducible macOS and Windows test/build gates.
- Added Apache-2.0 licensing, third-party notices, and contributor/security
  documentation for the first public release.
- Changed macOS identifiers to the public project namespace
  `io.github.netscale1.ech0`.

Community macOS builds are ad-hoc signed and not notarized. Community Windows
builds are unsigned. Neither platform has an automatic updater until trusted
release-signing credentials are provisioned.
