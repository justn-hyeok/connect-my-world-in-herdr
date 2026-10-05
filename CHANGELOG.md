# Changelog

## 0.1.3 — 2026-10-06

First public release.

- macOS menu-bar server status and individual/batch Herdr reconnection.
- Proxmox/VM hierarchy using `(pve)` and `(pn)` labels with `└` markers.
- Correct failure states, batch summaries, current-registry checks and cancellation-safe authentication waiting.
- Exact MADP profile and certificate-expiration checks using tsh JSON.
- Optional launch at login.

MADP's browser-to-tsh adapter is deferred; the login link is empty by default. Developer ID signing and notarization are not included. The release ZIP targets Apple Silicon and macOS 15+.
