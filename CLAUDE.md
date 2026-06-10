# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

SeeOnce is a Flutter app for serverless, peer-to-peer, end-to-end-encrypted "see once" image, video, and text sharing over WebRTC data channels. There is no backend: peers pair in person via QR codes, then connect directly. All media is held in memory, never written to disk, and destroyed after a single view.

## Commands

Flutter 3.41.1 / Dart 3.11.0. `flutter` is on `PATH`:

```bash
flutter pub get                        # install deps
flutter run                            # run on a connected device/emulator
flutter analyze                        # static analysis (flutter_lints)
flutter test                           # full test suite
flutter test test/crypto/hybrid_cipher_test.dart   # a single test file
flutter test --name "substring"        # tests matching a name

# Code generation (Hive adapters + json_serializable; *.g.dart files)
flutter pub run build_runner build --delete-conflicting-outputs
```

After editing any model annotated with `@HiveType` or `@JsonSerializable` (e.g. `peer.dart`, `image_envelope.dart`), regenerate the `.g.dart` files with build_runner.

## Architecture

The codebase is layered. Data flows: **UI (features/) → Riverpod providers → RTC/crypto/pipeline services → WebRTC data channel**.

### Connection lifecycle
- **Pairing** (`features/pairing/`, `signaling/`): First contact is in-person QR exchange. `pairing_provider` drives the WebRTC offer/answer handshake; `signaling_service` + `pairing_code_service` encode SDP and bundled ICE candidates (`ice_candidate_bundler`) into the QR payload. Encryption keys are **not** in the QR code — they are swapped over the DTLS-secured data channel afterward (`key_exchange_handler`), which makes the swap authenticated out-of-band by the in-person scan.
- **Reconnect** (`rtc/local_reconnect_service.dart`): Paired peers re-find each other on the LAN, identified by the full SHA-256 of their public key, then prove private-key possession via a nonce challenge-response (RSASSA-PKCS1-v1_5/SHA-256) before being trusted as online. This prevents presence spoofing.
- **Supervision** (`rtc/connection_supervisor.dart`): A singleton that watches every paired peer and auto-reconnects dropped links with exponential backoff (5s→60s), resetting on health and sweeping immediately on app resume (`didChangeAppLifecycleState` in `app.dart`).
- **Pooling** (`rtc/peer_connection_pool.dart`): Singleton registry of live `RTCPeerConnection`/`RTCDataChannel` per peer, with a broadcast stream of connection changes that the peers UI listens to.

### Crypto (`crypto/`)
Hybrid scheme for all payloads (images, videos, text): a fresh **AES-256-GCM** key encrypts the data, and that key is wrapped with the recipient's **RSA-OAEP (SHA-256)** public key (`hybrid_cipher.dart`). RSA-4096 keypair is generated once on first launch in a background isolate (`key_store.dart` via `compute`) — this takes seconds to tens of seconds, which is why `app.dart` gates the UI behind a `_SetupScreen` until `_bootstrap` completes. Private key lives in `flutter_secure_storage`.

### Transport & chunking (`rtc/rtc_channel_handler.dart`)
Encrypted payloads are split into 16 KB chunks and reassembled on the far side. The reassembler is hardened against malicious peers: it bounds total payload size (`maxPayloadBytes`, 25 MB), caps declared chunk counts, rejects out-of-range/duplicate indices, and sweeps incomplete buffers after a TTL. Treat all incoming-channel data as attacker-influenced — never `assert` on it.

### Media pipelines (`image_pipeline/`, `messaging/`)
Senders compress → encrypt → chunk → send: `image_sender` (+ `image_compressor`), `video_sender` (+ `video_compressor`, capped at 10s, trimmed/downscaled), `message_sender` (text). Decoded/decrypted bytes are explicitly **zero-filled** after use (see `conversation_provider.markAsViewed`). Tunables live in `core/constants.dart` (`AppConstants`).

### State (`features/*/providers/`, Riverpod)
`conversation_provider` is the in-memory store for pending see-once images/videos and ephemeral text. Text messages are held in memory only and pruned after `messageTtl` (30 min) by a periodic sweep. Nothing media-related is persisted. Only `peer` metadata and `settings` are persisted, via Hive (`data/datasources/hive_datasource.dart`, `data/repositories/`).

### Models (`data/models/`)
`*_envelope` = the on-the-wire encrypted form; `*_message` = the in-app decrypted form. `peer.dart` and `image_envelope.dart` use Hive/json codegen (`.g.dart`).

## Security invariants (do not break these)

- **No media touches disk.** Images/videos/text live in memory and are zero-filled after a single view or on expiry. The view-once video player streams from an in-memory loopback HTTP server on `127.0.0.1` (`secure_video_widget.dart`) precisely to avoid a temp file — do not switch it to a file-backed source.
- **Cleartext is loopback-only.** Android `network_security_config.xml` permits cleartext for `127.0.0.1`/`localhost` only (for the loopback video server); iOS uses `NSAllowsLocalNetworking`. Don't widen this.
- **Screenshot protection is asymmetric.** Android enforces it (`FLAG_SECURE` in `MainActivity.kt` + the `no_screenshot` plugin). iOS *cannot* block screenshots (no public API) — it only auto-dismisses on backgrounding and evicts bytes. Do not advertise iOS screenshot prevention.
- **Background connectivity is Android-only.** A foreground service (`services/background_service.dart`, `flutter_foreground_task`) keeps the process alive, started once ≥1 peer is paired. iOS has no equivalent; connection lives only while foregrounded.

## Wire-format compatibility

Handshake/wire changes require both devices to run a matching build and may force re-pairing. Existing on-wire choices that are load-bearing: RSA-OAEP uses SHA-256 (not the SHA-1 default), reconnect key-hash IDs are the full 256-bit hash, and reconnect includes an `auth_challenge`/`auth_response` step. Changing any of these is a breaking protocol change.

The reconnect auth handshake is **v2** (`_authProtocolVersion` in `local_reconnect_service.dart`). v2 signs `nonce || channelBinding` rather than the bare nonce, where `channelBinding` is a SHA-256 over the two DTLS certificate fingerprints (sorted) pulled from the local/remote SDP. This binds the proof-of-key-possession to the specific DTLS connection, so a LAN relay/MITM — which must terminate DTLS with its own certificate on each leg — is detected (the fingerprints, and therefore the binding, won't match). v2 peers refuse to authenticate with v1 peers, so upgrading one side forces a re-pair. Bump the version on any further change to the signed material.

## Reference

`IMPLEMENTATION_PLAN.md` (repo root) and the "Security model and honest limitations" section of `README.md` contain deeper rationale for the trust model, platform differences, and ephemerality guarantees.
