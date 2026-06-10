# SeeOnce

**Serverless, peer-to-peer, end-to-end-encrypted "see once" sharing.**

SeeOnce is a Flutter app for sharing images, short videos, and text messages that can be viewed exactly once, directly between two devices over WebRTC. There is no backend, no account, no cloud: peers pair in person by scanning QR codes, then talk to each other directly. All media lives in memory, is never written to disk, and is destroyed after a single view.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.41-blue.svg)](https://flutter.dev)

## Why

Most "disappearing message" apps still route your media through someone else's servers and trust the provider to delete it. SeeOnce takes the opposite approach:

- **No server.** Signaling for the first connection happens via QR codes exchanged in person. After that, paired devices find each other on the local network and connect directly over WebRTC data channels.
- **No disk.** Received media is decrypted into memory, shown once, then zero-filled. Nothing media-related is ever persisted; only peer metadata and settings are stored locally.
- **No third party to trust.** Encryption keys are generated on your device and exchanged peer-to-peer over a channel that was authenticated in person.

## Features

- **View-once images** with configurable compression.
- **View-once videos**, capped at 10 seconds (longer clips are trimmed), downscaled and compressed before sending. Played back from memory through a loopback HTTP server so the decrypted video never touches disk.
- **Ephemeral text chat**: end-to-end encrypted, held in memory only, gone 30 minutes after arrival or when the app closes.
- **In-person pairing** via QR code exchange; no phone numbers, emails, or accounts.
- **Automatic LAN reconnect**: paired devices re-find each other on the same network after restarts, with mutual cryptographic authentication before either side is trusted.
- **Connection supervision** with exponential backoff (5s to 60s), immediate retry on app resume, and an Android foreground service to keep links alive in the background.
- **Screenshot blocking** on Android (`FLAG_SECURE`).
- **On-device connection logs**: tap the "Reconnecting…" ribbon to see a live, memory-only diagnostic log, so connectivity issues can be debugged even on release builds.

## How it works

### Pairing

1. Both users open the pairing screen, one shows a QR code, the other scans it (and vice versa for the answer).
2. The QR payload carries the WebRTC SDP and bundled ICE candidates; the devices then connect directly.
3. RSA-4096 public keys are exchanged over the established DTLS-secured data channel. Because the SDP (including the DTLS certificate fingerprint) was exchanged face to face, the key swap is authenticated out of band by the physical scan.

### Sending

Every payload (image, video, or text) goes through the same pipeline:

```
compress → encrypt (AES-256-GCM, fresh key per payload)
        → wrap the AES key with the recipient's RSA-OAEP (SHA-256) public key
        → split into 16 KB chunks → WebRTC data channel
```

The receiver reassembles, unwraps, decrypts into memory, and displays. After one view (or expiry), the plaintext bytes are zero-filled.

### Reconnecting

After an app restart, paired peers re-discover each other via UDP broadcast on the local network (port 54321), identified by the full SHA-256 hash of their public key. Before a reconnected channel is trusted, both sides must pass a mutual challenge-response:

- Each side signs the partner's random nonce **bound to the DTLS channel** (a hash of both certificate fingerprints) with its RSA private key (RSASSA-PKCS1-v1_5 / SHA-256).
- The signature is verified against the stored public key from pairing.

This proves private-key possession (no presence spoofing) and detects relays or LAN man-in-the-middle attempts, since a relay must terminate DTLS with its own certificates and the channel binding will not match.

## Security model and honest limitations

SeeOnce is designed to make casual and remote capture of your media as hard as practical, but you should understand the boundaries:

- **A determined recipient can always capture content.** Screenshot blocking works on Android, but iOS has no public API to prevent screenshots (only detect them), and nothing stops anyone from photographing the screen with another device. Treat "see once" as a strong social contract enforced as well as each platform allows, not an absolute guarantee.
- **Connectivity is LAN-first.** Devices connect directly. Without a TURN relay (not configured, by design: no server), connections across different networks depend on NAT friendliness. The reliable path is both devices on the same Wi-Fi.
- **Background delivery is Android-only.** Android keeps connections alive with a foreground service. iOS has no equivalent long-running background mechanism, so on iOS the connection only lives while the app is in the foreground and is re-established on resume.
- **Ephemerality depends on both ends.** Your device destroys what it promised to destroy; the protocol cannot force the other device (if modified) to do the same. Pair only with people you trust.

Defensive details worth knowing:

- Private keys live in platform secure storage (`flutter_secure_storage`); keys are generated on first launch in a background isolate.
- All incoming data-channel traffic is treated as attacker-influenced: the chunk reassembler bounds payload size (25 MB), caps chunk counts, and rejects out-of-range or duplicate indices.
- Cleartext HTTP is permitted **only** to `127.0.0.1` (for the in-memory loopback video player); the Android network security config forbids it everywhere else.
- Diagnostic logs never leave the device: they live in a capped in-memory ring buffer, are viewable only in the UI, and are printed to the console only in debug builds.

## Getting started

### Requirements

- Flutter 3.41.x / Dart 3.11+
- Two physical devices (Android and/or iOS). WebRTC, the camera, and LAN discovery make emulators impractical for the full flow.

### Build and run

```bash
git clone https://github.com/untitled-developers/seeonce_app.git
cd seeonce_app
flutter pub get
flutter run
```

First launch generates an RSA-4096 keypair, which can take several seconds; the app shows a setup screen until it finishes.

### Development

```bash
flutter analyze          # static analysis (flutter_lints)
flutter test             # full test suite

# Regenerate Hive/json_serializable code after editing annotated models
flutter pub run build_runner build --delete-conflicting-outputs
```

A GitHub Actions workflow (`.github/workflows/build-apk.yml`) builds the Android APK on push.

## Project structure

```
lib/
├── core/              # constants, theme, errors, diagnostic log
├── crypto/            # RSA + AES-GCM hybrid cipher, key store
├── signaling/         # QR pairing payloads, ICE candidate bundling
├── rtc/               # connection pool, supervisor, LAN reconnect, chunking
├── image_pipeline/    # image/video compression and senders
├── messaging/         # text sender, incoming message router
├── data/              # Hive models and repositories (peers, settings)
├── features/          # UI: pairing, peers, conversation, settings, diagnostics
├── services/          # Android foreground service
└── widgets/           # secure image/video viewers, peer tile
```

`IMPLEMENTATION_PLAN.md` contains the deeper design rationale: the trust model, platform differences, and the ephemerality guarantees.

## Wire-format compatibility

Handshake and wire-format changes require both devices to run a matching build and may force re-pairing. Notably, the reconnect authentication handshake is currently **v2** (DTLS channel binding); v2 peers refuse to authenticate with v1 peers, so upgrading one device forces a re-pair.

## Troubleshooting

- **Stuck on "Reconnecting…"?** Tap the ribbon. It opens the live connection log (offer broadcasts, ICE states, socket errors, authentication results) right on the device, including in release builds. Use the copy button to share the log when reporting an issue.
- **Peers never see each other after a restart?** Make sure both devices are on the same Wi-Fi network and that the network allows UDP broadcast between clients (some guest/public networks isolate clients).

## Contributing

Issues and pull requests are welcome. Please:

1. Run `flutter analyze` and `flutter test` before submitting.
2. Keep the security invariants intact: no media may touch disk, cleartext stays loopback-only, and incoming channel data is never trusted.
3. Flag any wire-format or handshake change clearly; these are breaking and require coordinated upgrades on both peers.

## License

This project is licensed under the [MIT License](LICENSE).
