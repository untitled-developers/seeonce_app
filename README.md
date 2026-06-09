# seeonce_app

An image sharing app with webrtc support, two way encrypted see once features

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Security notes

### Screenshot protection (platform differences)
Screenshot blocking is enforced on Android via both `FLAG_SECURE`
(`MainActivity.kt`) and the `no_screenshot` plugin (`app.dart`).

On iOS there is no public API to block screenshots. The OS only lets an app
*detect* that a screenshot was taken (`UIApplicationUserDidTakeScreenshotNotification`),
not prevent it. Treat "see once" on iOS as best-effort: it auto-dismisses on
backgrounding and evicts decoded image bytes, but a determined user can still
capture the screen. Do not advertise screenshot prevention on iOS.

### Pairing and reconnect trust model
- First pairing exchanges SDP (including the DTLS fingerprint) in person via QR
  scan, so the data channel that carries the public-key swap is authenticated
  out of band.
- LAN reconnect (`local_reconnect_service.dart`) identifies peers by the full
  SHA-256 hash of their public key and runs a mutual nonce challenge-response
  (RSASSA-PKCS1-v1_5 / SHA-256) before a channel is trusted as online. This
  proves private-key possession and prevents presence spoofing.

### Text messaging
Text messages are end-to-end encrypted with the same hybrid scheme as images
(RSA-OAEP wrapping AES-256-GCM) and sent over the WebRTC data channel. They are
held in memory only (never written to disk) and disappear from the chat 30
minutes after they enter the chat. Ordering and expiry use each device's own
local clock (the time the message was created or received), NOT the sender's
timestamp: the two devices' clocks can differ by seconds, and keying off the
sender's time interleaves messages out of order. Closing the app also clears
them.

### View-once video
Videos are limited to **10 seconds** (camera capture is capped; longer gallery
clips are trimmed during compression) and downscaled/compressed before sending
(`video_compress`). They are encrypted and chunked over the data channel like
images, and are **view-once**: removed and zero-filled after a single play.

To keep the decrypted video out of disk (matching the image guarantee), the
receiver plays it from memory via a **loopback HTTP server** on `127.0.0.1`
(`SecureVideoWidget`) that `video_player` streams from; the server is closed and
the bytes zero-filled on dismiss. This requires cleartext to loopback only:
Android uses a `network_security_config.xml` that permits cleartext for
`127.0.0.1`/`localhost` and forbids it elsewhere; iOS uses
`NSAllowsLocalNetworking`.

### Background connectivity
A `ConnectionSupervisor` (`lib/rtc/connection_supervisor.dart`) watches every
paired peer and auto-reconnects any dropped connection with exponential backoff
(5s → 60s), resetting once healthy and sweeping again immediately on app resume.
Per-packet keepalive on a live link is handled by WebRTC's own ICE consent
freshness.

To keep that running when the app is **backgrounded on Android**, a foreground
service (`lib/services/background_service.dart`, via `flutter_foreground_task`)
holds the process alive with a persistent "SeeOnce connected" notification. It
starts once at least one peer is paired and requires the notification +
battery-optimization permissions it requests.

**iOS has no equivalent.** There is no general long-running background service,
so on iOS the connection is maintained only while the app is foregrounded and
re-established on resume. True backgrounded/cross-network delivery on iOS would
require server-side push (APNs) plus a TURN relay.

### Wire-format compatibility
The following are on-the-wire / handshake changes. Both devices must run a
build that includes them, and existing installs may need to re-pair:
- RSA-OAEP now uses SHA-256 (previously the SHA-1 default).
- Reconnect key-hash identifiers are now the full 256-bit hash (previously a
  64-bit truncation).
- Reconnect adds an `auth_challenge` / `auth_response` step on the data channel.
