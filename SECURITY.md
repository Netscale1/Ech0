# Security policy

## Supported versions

Security fixes are applied to the latest release and the current `main` branch.
Older releases are not maintained unless a security advisory states otherwise.

| Version | Supported |
| --- | --- |
| 0.2.x | Yes |
| Earlier versions | No |

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private
security advisory form:

https://github.com/Netscale1/Ech0/security/advisories/new

Include affected versions, reproduction steps, impact, and any suggested fix.
Do not include live pairing secrets, private keys, signing credentials, personal
audio, or unrelated system information.

The maintainers will acknowledge a complete report when they can reproduce or
meaningfully assess it. No fixed response or disclosure deadline is promised.
Please allow time to coordinate fixes across both endpoints before publishing
protocol or pairing vulnerabilities.

## Scope

High-value areas include authentication and pairing, key storage, protocol
parsing, update integrity, network exposure, microphone activation, and unsafe
installer behavior. Reports that require exposing port 48484 directly to the
public Internet are still useful, but Internet exposure is outside Ech0's
supported deployment model.
