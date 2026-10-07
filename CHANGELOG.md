# Changelog

## Unreleased

- Replace 전체 재연결 with 선택 재연결: each row has a checkbox and only checked connections reconnect. The selection is remembered; on first run only connections Herdr already has enabled are checked.
- Add a `Tailscale만` button that checks only connections whose effective SSH host (`ssh -G`) is a `*.ts.net` name or a tailnet address (100.64.0.0/10, fd7a:115c:a1e0::/48). A host reached through a ProxyJump on a LAN address is not counted.

## 0.2.1 — 2026-10-07

- Remove an unbounded process-exit wait that could leave server status checking busy after the child command had already exited. This fix existed in an unreleased local 0.1.5 build and was missing from 0.2.0.

## 0.2.0 — 2026-10-07

- Removed the Teleport/tsh MADP path: the authentication state, login link, browser/terminal login waiting and the `tsh` requirement. Every server, MADP included, is now checked and reconnected as a plain OpenSSH target.

## 0.1.3 — 2026-10-06

First public release.

- macOS menu-bar server status and individual/batch Herdr reconnection.
- Proxmox/VM hierarchy using `(pve)` and `(pn)` labels with `└` markers.
- Correct failure states, batch summaries, current-registry checks and cancellation-safe authentication waiting.
- Exact MADP profile and certificate-expiration checks using tsh JSON.
- Optional launch at login.

MADP's browser-to-tsh adapter is deferred; the login link is empty by default. Developer ID signing and notarization are not included. The release ZIP targets Apple Silicon and macOS 15+.
