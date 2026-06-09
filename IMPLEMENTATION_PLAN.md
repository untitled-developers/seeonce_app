# SeeOnce — Implementation Plan
## P2P End-to-End Encrypted Image Sharing App (Flutter / WebRTC)

---

## Overview

**SeeOnce** is a Flutter mobile application that allows two users to exchange images directly, peer-to-peer, using WebRTC data channels. Images are encrypted end-to-end with RSA-4096 asymmetric keys (per-peer). Images may only be viewed once and are immediately discarded from memory. Screenshots are blocked while the app is active. Peers are paired via a short-lived numeric/alphanumeric pairing code. Once paired, the peer relationship (including the remote public key) is persisted locally so no future re-pairing is needed. Unpairing works bidirectionally over the existing WebRTC data channel. The app sends local push notifications when a new image is received.

### Target Platforms
- Android (primary, API 21+)
- iOS (secondary, iOS 13+)

### Non-Negotiables
1. **No central server** — No relay server, no media server, no TURN server is managed by the developer. The only "centralized" component is a free/open public STUN server (e.g., `stun.l.google.com:19302`) and an optional user-supplied TURN (documented but not provided).
2. **Signaling is peer-assisted** — Offer/answer/ICE candidates are exchanged by the user copying a text blob (QR code or manual code). No WebSocket signaling server is written.
3. **Asymmetric encryption** — Each peer generates an RSA-4096 key pair locally on first launch. The public key is shared during pairing. All image payloads are encrypted with the recipient's public key before transmission.
4. **View once** — Received image data lives only in RAM during display and is zeroed after the viewer is closed.
5. **Screenshot protection** — `FLAG_SECURE` on Android; `allowScreenshot = false` in iOS app-level settings.

---

## Tech Stack & Package Decisions

| Concern | Package | Notes |
|---|---|---|
| WebRTC | `flutter_webrtc ^1.4.1` | Already in `pubspec.yaml` as dev dep — **move to main deps** |
| Asymmetric Encryption | `pointycastle ^3.9.1` | Pure-Dart RSA-OAEP-SHA256, no native plugin needed |
| Symmetric Chunking Encryption | `cryptography ^2.7.0` | AES-GCM for large image payload (hybrid encryption — RSA wraps an AES key) |
| Local Persistence | `hive ^2.2.3` + `hive_flutter ^1.1.0` | Encrypted boxes for peer list + key store |
| Secure Storage (Key Vault) | `flutter_secure_storage ^9.2.2` | AES-256 encrypted Android Keystore / iOS Secure Enclave |
| Local Notifications | `flutter_local_notifications ^17.2.4` | Foreground + background notifications |
| Image Compression | `flutter_image_compress ^2.3.0` | JPEG quality + max dimension downscale, configurable |
| Image Picking | `image_picker ^1.1.2` | Gallery / camera pick |
| State Management | `riverpod ^2.6.1` + `hooks_riverpod ^2.6.1` | Provider-based reactive state |
| Navigation | `go_router ^14.6.3` | Declarative routing |
| QR Generation | `qr_flutter ^4.1.0` | Display pairing QR |
| QR Scanning | `mobile_scanner ^5.2.3` | Camera-based QR code reading |
| UUID | `uuid ^4.5.1` | Peer IDs + message IDs |
| Secure Bytes Wipe | `dart:typed_data` (built-in) | Zero-fill Uint8List after use |
| Screenshot Block | `no_screenshot ^0.1.3` | Wraps FLAG_SECURE + iOS API |
| JSON Serialization | `json_annotation ^4.9.0` + `json_serializable ^6.9.0` (dev) | DTO code-gen |
| Build Runner | `build_runner ^2.4.15` (dev) | Code generation |
| Settings UI | `settings_ui ^2.0.2` | Compression config screen |
| Intl | `intl ^0.20.2` | Date formatting in inbox |

> **Note on Hybrid Encryption**: RSA-4096 can only encrypt ~446 bytes. Images are much larger. The implementation uses **hybrid encryption**:
> 1. Generate a random AES-256-GCM session key.
> 2. Encrypt the image bytes with AES-GCM → `ciphertext`.
> 3. Encrypt the AES session key with the peer's RSA-4096 public key → `encryptedKey`.
> 4. Transmit `{encryptedKey, ciphertext, iv, nonce, senderId, messageId}` as a JSON envelope over the WebRTC data channel.

---

## Architecture Overview

```
lib/
├── main.dart                          # Entry point
├── app.dart                           # MaterialApp + GoRouter + ProviderScope
├── core/
│   ├── constants.dart                 # STUN/TURN URLs, chunk size, defaults
│   ├── errors.dart                    # Sealed error classes
│   └── extensions.dart               # Utility extensions
├── crypto/
│   ├── key_store.dart                 # RSA key generation, storage, retrieval
│   ├── rsa_cipher.dart                # RSA-OAEP encrypt/decrypt
│   └── hybrid_cipher.dart            # Hybrid RSA+AES-GCM encrypt/decrypt
├── data/
│   ├── models/
│   │   ├── peer.dart                  # Peer model + JSON
│   │   ├── image_message.dart         # Received-image transient model
│   │   └── pairing_payload.dart       # Pairing code data model
│   ├── repositories/
│   │   ├── peer_repository.dart       # CRUD for peers in Hive
│   │   └── settings_repository.dart   # Compression settings (Hive)
│   └── datasources/
│       └── hive_datasource.dart       # Hive box initialisation
├── signaling/
│   ├── signaling_service.dart         # Manual SDP offer/answer builder
│   ├── pairing_code_service.dart      # Encode/decode pairing blobs
│   └── ice_candidate_bundler.dart     # Collects ICE candidates post-trickle
├── rtc/
│   ├── rtc_manager.dart               # Manages RTCPeerConnection lifecycle
│   ├── rtc_channel_handler.dart       # Data channel send/receive, chunking
│   └── peer_connection_pool.dart      # Map<peerId, RTCPeerConnection>
├── image_pipeline/
│   ├── image_compressor.dart          # flutter_image_compress wrapper
│   └── image_sender.dart             # Compress → Encrypt → Chunk → Send
├── notifications/
│   └── notification_service.dart      # flutter_local_notifications setup + dispatch
├── features/
│   ├── pairing/
│   │   ├── screens/
│   │   │   ├── pairing_screen.dart    # Entry: show own code / scan peer code
│   │   │   ├── show_code_screen.dart  # Display QR + text blob
│   │   │   └── scan_code_screen.dart  # Camera QR scan + manual paste
│   │   └── providers/
│   │       └── pairing_provider.dart
│   ├── peers/
│   │   ├── screens/
│   │   │   └── peers_screen.dart      # Peers list (home screen)
│   │   └── providers/
│   │       └── peers_provider.dart
│   ├── conversation/
│   │   ├── screens/
│   │   │   ├── conversation_screen.dart  # Per-peer send/receive UI
│   │   │   └── image_viewer_screen.dart  # Full-screen view-once viewer
│   │   └── providers/
│   │       └── conversation_provider.dart
│   └── settings/
│       ├── screens/
│       │   └── settings_screen.dart   # Compression settings
│       └── providers/
│           └── settings_provider.dart
└── widgets/
    ├── peer_tile.dart
    ├── send_image_button.dart
    └── secure_image_widget.dart       # Renders image, zeros memory on dispose
```

---

## Data Models

### `Peer`
```dart
class Peer {
  final String id;            // UUID v4, generated locally at pairing
  final String displayName;   // Human-readable label (editable)
  final String publicKeyPem;  // Peer's RSA-4096 public key in PEM format
  final DateTime pairedAt;
  final bool isOnline;        // Transient, not persisted
}
```

### `PairingPayload` (shared as base64-encoded JSON)
```dart
class PairingPayload {
  final String peerId;        // Initiator's own UUID
  final String displayName;
  final String publicKeyPem;  // Initiator's RSA public key
  final String sdpOffer;      // WebRTC SDP offer (or empty for step 2)
  final List<String> iceCandidates; // JSON-encoded RTCIceCandidate objects
  final String step;          // "offer" | "answer"
}
```

### `ImageEnvelope` (sent over data channel, JSON-encoded)
```dart
class ImageEnvelope {
  final String messageId;     // UUID
  final String senderId;      // Sender's peer UUID
  final String encryptedKey;  // Base64 RSA-encrypted AES key
  final String iv;            // Base64 AES-GCM IV (12 bytes)
  final String ciphertext;    // Base64 AES-GCM encrypted image bytes
  final String mimeType;      // "image/jpeg"
  final int originalWidth;
  final int originalHeight;
  final DateTime sentAt;
  final String type;          // "image" | "unpair"
}
```

### `UnpairMessage` (control message over data channel)
```dart
class UnpairMessage {
  final String type;  // "unpair"
  final String peerId;
}
```

---

## Phase-by-Phase Implementation Plan

---

## Phase 1 — Project Setup & Dependencies

**Goal:** Establish a clean dependency baseline, configure platform permissions, and prepare all package infrastructure.

### 1.1 — Update `pubspec.yaml`

#### [MODIFY] [pubspec.yaml](file:///home/hmawla/Documents/GitHub/seeonce_app/pubspec.yaml)

Move `flutter_webrtc` from `dev_dependencies` to `dependencies`. Add all required packages:

```yaml
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8

  # WebRTC
  flutter_webrtc: ^1.4.1

  # Crypto
  pointycastle: ^3.9.1
  cryptography: ^2.7.0

  # Storage
  hive: ^2.2.3
  hive_flutter: ^1.1.0
  flutter_secure_storage: ^9.2.2

  # Notifications
  flutter_local_notifications: ^17.2.4

  # Image processing
  flutter_image_compress: ^2.3.0
  image_picker: ^1.1.2

  # State & navigation
  flutter_riverpod: ^2.6.1
  hooks_riverpod: ^2.6.1
  flutter_hooks: ^0.20.5
  go_router: ^14.6.3

  # QR
  qr_flutter: ^4.1.0
  mobile_scanner: ^5.2.3

  # Utils
  uuid: ^4.5.1
  intl: ^0.20.2
  json_annotation: ^4.9.0
  no_screenshot: ^0.1.3
  settings_ui: ^2.0.2

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
  build_runner: ^2.4.15
  json_serializable: ^6.9.0
  hive_generator: ^2.0.1
```

### 1.2 — Android Platform Configuration

#### [MODIFY] [AndroidManifest.xml](file:///home/hmawla/Documents/GitHub/seeonce_app/android/app/src/main/AndroidManifest.xml)

Add permissions:
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>
<uses-permission android:name="android.permission.VIBRATE"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>
```

Add `android:usesCleartextTraffic="false"` to `<application>` tag.

Add `FLAG_SECURE` via a custom Flutter activity — create `MainActivity.kt`:

#### [NEW] [MainActivity.kt](file:///home/hmawla/Documents/GitHub/seeonce_app/android/app/src/main/kotlin/co/kockatoos/seeonce_app/MainActivity.kt)

```kotlin
package co.kockatoos.seeonce_app

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Prevent screenshots and screen recording
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
    }
}
```

Update `AndroidManifest.xml` to reference `co.kockatoos.seeonce_app.MainActivity`.

Update `android/app/build.gradle.kts`: set `minSdk = 21`.

### 1.3 — iOS Platform Configuration

#### [MODIFY] [Info.plist](file:///home/hmawla/Documents/GitHub/seeonce_app/ios/Runner/Info.plist)

Add:
```xml
<key>NSCameraUsageDescription</key>
<string>SeeOnce uses the camera to scan peer QR codes.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>SeeOnce reads images from your photo library to send them.</string>
<key>UIApplicationDoesNotSupportMultitasking</key>
<false/>
```

#### [MODIFY] [AppDelegate.swift](file:///home/hmawla/Documents/GitHub/seeonce_app/ios/Runner/AppDelegate.swift)

Add screenshot protection:
```swift
import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
    override func applicationDidBecomeActive(_ application: UIApplication) {
        // Prevent screenshot via overlay (iOS does not have a direct API, but
        // UITextField trick is the standard approach)
        window?.makeSecure()
    }
}

extension UIWindow {
    func makeSecure() {
        let field = UITextField()
        field.isSecureTextEntry = true
        self.addSubview(field)
        field.centerYAnchor.constraint(equalTo: self.centerYAnchor).isActive = true
        field.centerXAnchor.constraint(equalTo: self.centerXAnchor).isActive = true
        self.layer.superlayer?.addSublayer(field.layer)
        field.layer.sublayers?.last?.addSublayer(self.layer)
    }
}
```

### 1.4 — Hive Initialization

#### [NEW] [hive_datasource.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/data/datasources/hive_datasource.dart)

- Open Hive boxes: `peers`, `settings`
- The encryption key for Hive box is stored in `flutter_secure_storage` under key `hive_aes_key`
- On first run: generate 32 random bytes, store in secure storage, open `HiveAesCipher`-encrypted boxes
- On subsequent runs: read key from secure storage

### 1.5 — Run code generation baseline

```bash
flutter pub get
flutter pub run build_runner build --delete-conflicting-outputs
```

**Validation Points:**
- [ ] `flutter pub get` completes without errors
- [ ] `build_runner build` completes without errors
- [ ] App compiles with `flutter build apk --debug`
- [ ] `MainActivity.kt` is recognized, app launches without crash
- [ ] Screenshot is blocked on Android (test manually)
- [ ] iOS app builds without errors

---

## Phase 2 — Data Layer (Crypto + Persistence)

**Goal:** Implement RSA key generation, hybrid encryption/decryption, and the full peer persistence layer.

### 2.1 — RSA Key Store

#### [NEW] [key_store.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/crypto/key_store.dart)

Responsibilities:
- On first launch, generate an **RSA-4096** key pair using `pointycastle`'s `RSAKeyGenerator`
- Store the **private key** as PEM in `flutter_secure_storage` under key `own_private_key_pem`
- Store the **public key** as PEM in `flutter_secure_storage` under key `own_public_key_pem`
- Provide `Future<RSAPublicKey> getOwnPublicKey()`
- Provide `Future<RSAPrivateKey> getOwnPrivateKey()`
- Provide `String exportPublicKeyPem(RSAPublicKey key)` (PKCS#1 PEM)
- Provide `RSAPublicKey importPublicKeyPem(String pem)` (parse peer's PEM)

Key generation parameters:
```dart
final keyGen = RSAKeyGenerator()
  ..init(ParametersWithRandom(
    RSAKeyGeneratorParameters(BigInt.parse('65537'), 4096, 64),
    secureRandom,
  ));
```

`secureRandom` must be seeded from `dart:math`'s `Random.secure()`.

### 2.2 — RSA Cipher

#### [NEW] [rsa_cipher.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/crypto/rsa_cipher.dart)

- Uses `OAEPEncoding` with `RSAEngine` and `SHA256Digest`
- `Uint8List encryptWithPublicKey(RSAPublicKey publicKey, Uint8List data)`
- `Uint8List decryptWithPrivateKey(RSAPrivateKey privateKey, Uint8List data)`

### 2.3 — Hybrid Cipher

#### [NEW] [hybrid_cipher.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/crypto/hybrid_cipher.dart)

```
Encrypt flow:
1. Generate random 32-byte AES key + 12-byte IV
2. Encrypt plaintext bytes with AES-256-GCM (using `cryptography` package: `AesGcm.with256bits()`)
3. RSA-OAEP encrypt the 32-byte AES key with the peer's public key
4. Return: HybridEncryptedPayload { encryptedKey (bytes), iv (bytes), ciphertext (bytes) }

Decrypt flow:
1. RSA-OAEP decrypt the encryptedKey with own private key → AES key (32 bytes)
2. AES-256-GCM decrypt ciphertext using recovered key + iv
3. Return plaintext bytes
4. Zero-fill all intermediate byte arrays
```

### 2.4 — Peer Model

#### [NEW] [peer.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/data/models/peer.dart)

```dart
@HiveType(typeId: 0)
class Peer extends HiveObject {
  @HiveField(0) final String id;
  @HiveField(1)       String displayName;
  @HiveField(2) final String publicKeyPem;
  @HiveField(3) final DateTime pairedAt;
  // NOT persisted:
  bool isOnline = false;
}
```

Add `PeerAdapter` via `hive_generator` (`@HiveType`, `@HiveField` annotations).

#### [NEW] [peer.g.dart] — auto-generated by `build_runner`

### 2.5 — Settings Model

#### [NEW] [settings_repository.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/data/repositories/settings_repository.dart)

Stores/retrieves:
```dart
class CompressionSettings {
  int maxDimension;   // default: 1080 (pixels, longest side)
  int jpegQuality;    // default: 80 (0–100)
}
```
Stored in Hive `settings` box under key `compression_settings`.

### 2.6 — Peer Repository

#### [NEW] [peer_repository.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/data/repositories/peer_repository.dart)

```dart
class PeerRepository {
  Future<List<Peer>> getAllPeers();
  Future<void> savePeer(Peer peer);
  Future<void> deletePeer(String peerId);
  Future<Peer?> getPeerById(String peerId);
  Stream<List<Peer>> watchPeers(); // Hive listenable box stream
}
```

**Validation Points:**
- [ ] Key pair is generated only once (subsequent launches reuse stored keys)
- [ ] PEM round-trip: exported PEM → imported RSAPublicKey → encrypt → decrypt succeeds
- [ ] Hybrid encrypt/decrypt round-trip on a 500 KB byte array succeeds
- [ ] Hive encrypted box opens successfully on fresh install
- [ ] Peer CRUD operations work (add, read, delete)
- [ ] CompressionSettings persists across hot restart

---

## Phase 3 — Signaling & Pairing (No Server)

**Goal:** Implement the manual out-of-band signaling protocol using a pairing code (QR or text blob).

### 3.1 — Pairing Protocol Design

Because there is no signaling server, the entire WebRTC handshake is conducted via a two-step out-of-band exchange:

```
┌──────────────────────────────────────────────────────────────────┐
│  Step 1 — Initiator (Alice)                                      │
│  - Creates RTCPeerConnection                                     │
│  - Creates DataChannel "seeonce-data"                            │
│  - Creates SDP Offer                                             │
│  - Waits for ICE gathering to complete (non-trickle mode)        │
│  - Bundles: { peerId, displayName, publicKeyPem, sdpOffer,       │
│              iceCandidates } → JSON → base64 → QR / text blob    │
│  - Displays QR / copy-able code to user                          │
└──────────────────────────────────────────────────────────────────┘
                        User shares QR out-of-band
┌──────────────────────────────────────────────────────────────────┐
│  Step 2 — Responder (Bob)                                        │
│  - Scans QR / pastes text blob                                   │
│  - Creates RTCPeerConnection                                     │
│  - Sets remote SDP offer                                         │
│  - Applies Alice's ICE candidates                                │
│  - Creates SDP Answer                                            │
│  - Waits for ICE gathering to complete                           │
│  - Bundles: { peerId, displayName, publicKeyPem, sdpAnswer,      │
│              iceCandidates }                                     │
│  - Saves Alice as a peer immediately                             │
│  - Displays response QR / text blob                              │
└──────────────────────────────────────────────────────────────────┘
                        User shares response back to Alice
┌──────────────────────────────────────────────────────────────────┐
│  Step 3 — Initiator (Alice) finalizes                            │
│  - Scans response QR / pastes response blob                      │
│  - Sets remote SDP answer                                        │
│  - Applies Bob's ICE candidates                                  │
│  - RTCPeerConnection reaches "connected" state                   │
│  - Saves Bob as a peer                                           │
└──────────────────────────────────────────────────────────────────┘
```

**ICE Gathering Strategy:** Use `iceTransportPolicy: "all"` with only STUN (`stun.l.google.com:19302`). Wait for `iceGatheringState == 'complete'` before generating the pairing blob (non-trickle). This ensures all ICE candidates are bundled into the single code.

### 3.2 — PairingPayload Model

#### [NEW] [pairing_payload.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/data/models/pairing_payload.dart)

```dart
@JsonSerializable()
class PairingPayload {
  final String step;          // "offer" | "answer"
  final String peerId;
  final String displayName;
  final String publicKeyPem;
  final String sdp;           // SDP offer or answer
  final List<String> iceCandidates; // JSON-encoded RTCIceCandidate maps
}
```

#### [NEW] [pairing_payload.g.dart] — auto-generated

### 3.3 — Pairing Code Service

#### [NEW] [pairing_code_service.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/signaling/pairing_code_service.dart)

```dart
class PairingCodeService {
  // Encode PairingPayload → compact JSON → gzip → base64url
  String encode(PairingPayload payload);
  
  // Decode base64url → gunzip → JSON → PairingPayload
  PairingPayload decode(String code);
}
```

Use `dart:convert` (`utf8`, `base64Url`) and `dart:io` (`GZipCodec`) to keep codes compact.

### 3.4 — ICE Candidate Bundler

#### [NEW] [ice_candidate_bundler.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/signaling/ice_candidate_bundler.dart)

```dart
class IceCandidateBundler {
  final List<RTCIceCandidate> _candidates = [];
  final Completer<List<RTCIceCandidate>> _completer;

  // Called from RTCPeerConnection.onIceCandidate
  void onCandidate(RTCIceCandidate? candidate) {
    if (candidate == null) {
      // null signals gathering complete
      _completer.complete(_candidates);
    } else {
      _candidates.add(candidate);
    }
  }

  Future<List<RTCIceCandidate>> get candidates => _completer.future;
}
```

### 3.5 — Signaling Service

#### [NEW] [signaling_service.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/signaling/signaling_service.dart)

```dart
class SignalingService {
  // Step 1: Create offer blob
  Future<String> createOfferCode({
    required String ownPeerId,
    required String displayName,
    required String publicKeyPem,
    required RTCPeerConnection pc,
    required RTCDataChannel dataChannel,
  });

  // Step 2: Process offer blob, create answer blob
  Future<({String answerCode, String remotePeerId, String remotePublicKeyPem})>
      processOfferAndCreateAnswer({
    required String offerCode,
    required String ownPeerId,
    required String displayName,
    required String publicKeyPem,
    required RTCPeerConnection pc,
  });

  // Step 3: Finalize connection with answer blob
  Future<({String remotePeerId, String remotePublicKeyPem})>
      finalizeWithAnswer({
    required String answerCode,
    required RTCPeerConnection pc,
  });
}
```

**Validation Points:**
- [ ] `PairingCodeService.encode/decode` round-trips a full payload without loss
- [ ] `IceCandidateBundler` correctly resolves the Future when `null` candidate arrives
- [ ] `createOfferCode` returns a non-empty base64url string
- [ ] `processOfferAndCreateAnswer` sets remote description, adds ICE candidates, creates answer
- [ ] Two emulator instances can complete the full 3-step pairing
- [ ] After pairing, `RTCPeerConnection.connectionState == 'connected'`

---

## Phase 4 — WebRTC Connection Manager & Image Transfer

**Goal:** Manage the lifecycle of peer connections, implement data channel messaging, chunking, reassembly, and the encrypt-send / receive-decrypt pipeline.

### 4.1 — Constants

#### [NEW] [constants.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/core/constants.dart)

```dart
class AppConstants {
  static const String stunServer = 'stun:stun.l.google.com:19302';
  static const int dataChannelChunkSize = 16384; // 16 KB per chunk
  static const String dataChannelLabel = 'seeonce-data';
  static const String controlChannelLabel = 'seeonce-control';

  // Message types
  static const String msgTypeImage = 'image';
  static const String msgTypeUnpair = 'unpair';
  static const String msgTypeAck = 'ack';

  // Hive box names
  static const String peersBoxName = 'peers';
  static const String settingsBoxName = 'settings';
}
```

### 4.2 — RTC Manager

#### [NEW] [rtc_manager.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/rtc/rtc_manager.dart)

```dart
class RtcManager {
  // Create a new RTCPeerConnection with STUN config
  Future<RTCPeerConnection> createPeerConnection();

  // Create the data channel (called by initiator only)
  Future<RTCDataChannel> createDataChannel(RTCPeerConnection pc);

  // Attach listeners (ondatachannel for responder)
  void attachListeners({
    required RTCPeerConnection pc,
    required String peerId,
    required Function(RTCDataChannel) onDataChannel,
    required Function(RTCPeerConnectionState) onConnectionStateChange,
    required Function(RTCIceCandidate?) onIceCandidate,
  });

  // Close and clean up
  Future<void> closePeerConnection(RTCPeerConnection pc);
}
```

RTCConfiguration:
```dart
final config = {
  'iceServers': [{'urls': AppConstants.stunServer}],
  'sdpSemantics': 'unified-plan',
};
```

### 4.3 — Peer Connection Pool

#### [NEW] [peer_connection_pool.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/rtc/peer_connection_pool.dart)

```dart
class PeerConnectionPool {
  final Map<String, RTCPeerConnection> _connections = {};
  final Map<String, RTCDataChannel> _channels = {};

  // Register a live connection for a peer
  void register(String peerId, RTCPeerConnection pc, RTCDataChannel dc);

  RTCPeerConnection? getConnection(String peerId);
  RTCDataChannel? getChannel(String peerId);
  bool isOnline(String peerId);

  // Remove and close
  Future<void> remove(String peerId);

  // Close all
  Future<void> closeAll();
}
```

Expose as a singleton Riverpod provider.

### 4.4 — Data Channel Handler (Chunking)

#### [NEW] [rtc_channel_handler.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/rtc/rtc_channel_handler.dart)

**Sending large binary messages:**

WebRTC data channels have a limited per-message buffer. Large images must be chunked:

```
Protocol (binary messages over data channel):
┌─────────────────────────────────────────────┐
│ HEADER (first message, JSON text):           │
│ { "messageId": "...", "totalChunks": N,      │
│   "mimeType": "image/jpeg",                  │
│   "type": "image", "senderId": "..." }        │
├─────────────────────────────────────────────┤
│ CHUNK 1 (binary): bytes 0..16383             │
│ CHUNK 2 (binary): bytes 16384..32767         │
│ ...                                          │
│ CHUNK N (binary): last bytes                 │
└─────────────────────────────────────────────┘
```

```dart
class RtcChannelHandler {
  // Send an already-encrypted ImageEnvelope payload over dc
  Future<void> sendEncryptedPayload({
    required RTCDataChannel dc,
    required Uint8List encryptedPayload, // full JSON envelope as bytes
    required String messageId,
    required String senderId,
  });

  // Called for each incoming message on dc.onMessage
  // Reassembles chunks, emits complete payloads via Stream
  Stream<Uint8List> get incomingPayloads;
  void onMessage(RTCDataChannelMessage message);
}
```

Reassembly map: `Map<String, _ChunkBuffer>` keyed by `messageId`. `_ChunkBuffer` holds received chunks and a `BytesBuilder`. When all N chunks are received, emit the assembled `Uint8List` to `incomingPayloads`.

### 4.5 — Image Message Model

#### [NEW] [image_message.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/data/models/image_message.dart)

```dart
/// Transient — never persisted to disk.
class ImageMessage {
  final String messageId;
  final String senderId;
  final Uint8List imageBytes;  // plaintext, in memory only
  final DateTime receivedAt;
  bool isViewed = false;
}
```

### 4.6 — Image Envelope Model

#### [NEW] [image_envelope.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/data/models/image_envelope.dart)

```dart
@JsonSerializable()
class ImageEnvelope {
  final String messageId;
  final String senderId;
  final String type;
  final String encryptedKey; // base64
  final String iv;           // base64
  final String ciphertext;   // base64
  final String mimeType;
  final int originalWidth;
  final int originalHeight;
  final String sentAt;       // ISO 8601
}
```

### 4.7 — Image Compressor

#### [NEW] [image_compressor.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/image_pipeline/image_compressor.dart)

```dart
class ImageCompressor {
  // Compress the picked image file
  Future<Uint8List> compress({
    required String filePath,
    required CompressionSettings settings,
  });
}
```

Implementation:
```dart
final result = await FlutterImageCompress.compressWithFile(
  filePath,
  minWidth: settings.maxDimension,
  minHeight: settings.maxDimension,
  quality: settings.jpegQuality,
  format: CompressFormat.jpeg,
  keepExif: false, // strip EXIF for privacy
);
```

### 4.8 — Image Sender

#### [NEW] [image_sender.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/image_pipeline/image_sender.dart)

```dart
class ImageSender {
  Future<void> sendImage({
    required String filePath,
    required Peer recipient,
    required RTCDataChannel dataChannel,
    required CompressionSettings compressionSettings,
    required RSAPublicKey recipientPublicKey,
    required String ownPeerId,
  });
}
```

Pipeline:
1. `ImageCompressor.compress(filePath, settings)` → `Uint8List rawBytes`
2. Decode JPEG to get `width` and `height` (using `decodeImageFromList` or `image` package)
3. `HybridCipher.encrypt(recipientPublicKey, rawBytes)` → `HybridEncryptedPayload`
4. Build `ImageEnvelope` JSON, encode to `Uint8List`
5. `RtcChannelHandler.sendEncryptedPayload(dc, payload, messageId, ownPeerId)`
6. Zero-fill `rawBytes` after sending

### 4.9 — Receive Pipeline

Inside `RtcChannelHandler.incomingPayloads.listen(...)` (wired up in `ConversationProvider`):

1. Parse JSON → `ImageEnvelope`
2. If `type == 'unpair'`: trigger unpair flow (Phase 4.10)
3. If `type == 'image'`:
    - `base64Decode(envelope.encryptedKey)` → `encryptedKeyBytes`
    - `base64Decode(envelope.iv)` → `ivBytes`
    - `base64Decode(envelope.ciphertext)` → `ciphertextBytes`
    - `HybridCipher.decrypt(ownPrivateKey, encryptedKeyBytes, ivBytes, ciphertextBytes)` → `rawImageBytes`
    - Create `ImageMessage` and push to `ConversationProvider.incomingImages` stream
    - Trigger local notification via `NotificationService`
    - Zero-fill `ciphertextBytes` after decryption (retain only `rawImageBytes` briefly)

### 4.10 — Unpair Flow

**Unpairing is bidirectional:**
1. User A taps "Unpair" in conversation screen.
2. App sends `UnpairMessage { type: "unpair", peerId: ownPeerId }` over data channel to Peer B.
3. App closes Peer B's RTCPeerConnection.
4. App deletes Peer B from `PeerRepository`.
5. When Peer B receives the `unpair` message:
    - Closes RTCPeerConnection.
    - Deletes Peer A from `PeerRepository`.
    - Navigates back to peers list.
    - Shows a snackbar: "Peer 'Alice' removed you."

**Validation Points:**
- [ ] A 2 MB image is chunked into ceil(2MB/16KB) = 128 chunks, all received and reassembled correctly
- [ ] Reassembled bytes match original (SHA-256 hash check in test)
- [ ] Hybrid encrypt → send → receive → decrypt produces identical plaintext
- [ ] Unpair message is received and both peers remove each other from their lists
- [ ] `PeerConnectionPool.isOnline` correctly reflects connection state

---

## Phase 5 — Image Pipeline Finalization & View-Once

**Goal:** Implement the view-once display screen with memory zeroing and ensure no image data is ever written to disk.

### 5.1 — Incoming Image State

#### [NEW] [conversation_provider.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/features/conversation/providers/conversation_provider.dart)

```dart
// StateNotifier or AsyncNotifier (Riverpod)
class ConversationNotifier extends StateNotifier<ConversationState> {
  // Per-peer: list of pending ImageMessages (in memory only)
  // When isViewed = true, bytes are zeroed and message is removed from list
  
  void onImageReceived(ImageMessage msg);
  void markAsViewed(String messageId); // zero bytes, remove
  void onUnpairReceived(String remotePeerId);
}
```

`ConversationState`:
```dart
class ConversationState {
  final Map<String, List<ImageMessage>> pendingByPeer; // peerId → messages
}
```

### 5.2 — Secure Image Widget

#### [NEW] [secure_image_widget.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/widgets/secure_image_widget.dart)

```dart
class SecureImageWidget extends HookWidget {
  final Uint8List imageBytes;
  final VoidCallback onViewed;

  @override
  Widget build(BuildContext context) {
    // Use Image.memory(imageBytes)
    // On dispose: zero-fill imageBytes, call onViewed
  }
}
```

Override `dispose()` to zero-fill: `imageBytes.fillRange(0, imageBytes.length, 0)`.

### 5.3 — Image Viewer Screen

#### [NEW] [image_viewer_screen.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/features/conversation/screens/image_viewer_screen.dart)

- Full-screen `InteractiveViewer` for pinch-to-zoom
- Displays `SecureImageWidget`
- Shows a prominent "View Once — closes when dismissed" banner
- **Auto-close:** image is dismissed (and bytes zeroed) when:
    1. User taps back / swipes back
    2. App goes to background (`AppLifecycleListener`)
- Back button shows a confirmation dialog: "This image will disappear. Continue?"
- Displays sender name and received-at timestamp
- No save/share button

### 5.4 — AppLifecycle Guard

In `app.dart` or a top-level `AppLifecycleObserver`:
- On `AppLifecycleState.paused` or `inactive`: if `ImageViewerScreen` is active, pop it (which triggers byte zeroing).

**Validation Points:**
- [ ] After closing `ImageViewerScreen`, the `Uint8List` is all zeros (verifiable in unit test)
- [ ] Image disappears from conversation screen after being viewed
- [ ] Backgrounding the app while viewing closes the viewer
- [ ] No image file is written to temp or cache directories at any point

---

## Phase 6 — Local Notifications

**Goal:** Show a local notification when a new image is received from a peer.

### 6.1 — Notification Service

#### [NEW] [notification_service.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/notifications/notification_service.dart)

```dart
class NotificationService {
  static const _channelId = 'seeonce_images';
  static const _channelName = 'Received Images';

  Future<void> initialize();

  Future<void> showImageReceivedNotification({
    required String senderName,
    required String messageId,
    required String peerId,
  });
  
  // Request notification permission (Android 13+ / iOS)
  Future<bool> requestPermission();
}
```

Android channel settings:
- `importance: Importance.high`
- `priority: Priority.high`
- `enableVibration: true`
- `playSound: true`
- No image attachment in notification (privacy: do not show the image)

Notification tap → navigate to conversation with the sender peer.

Handle notification tap via `onDidReceiveNotificationResponse`:
```dart
void onDidReceiveNotificationResponse(NotificationResponse response) {
  final peerId = response.payload; // peerId passed as payload
  // Navigate to conversation screen for peerId
}
```

### 6.2 — Background Notification (iOS)

For iOS, `flutter_local_notifications` + `DarwinInitializationSettings` with `requestAlertPermission`, `requestBadgePermission`, `requestSoundPermission`.

**Validation Points:**
- [ ] Notification appears when app is in foreground (visible as heads-up)
- [ ] Notification appears when app is in background (system tray notification)
- [ ] Tapping notification navigates to the correct conversation
- [ ] Notification does NOT contain the image (privacy)
- [ ] Notification text: "📷 New image from [PeerName]"

---

## Phase 7 — UI Implementation

**Goal:** Build all screens with a polished, dark-mode-first, premium UI.

### Design System

**Color Palette (Dark Mode Primary):**
```
Background:     #0A0A0F  (near black)
Surface:        #12121A  (dark card)
Surface Variant:#1C1C28
Accent:         #7B61FF  (purple-violet)
Accent Light:   #9B89FF
Success:        #22C55E  (green for online)
Danger:         #EF4444  (red for alerts)
Text Primary:   #F1F1F7
Text Secondary: #9090A0
```

**Typography:** Use Google Fonts `Inter` via `google_fonts` package (add `google_fonts: ^6.2.1` to pubspec).

**Visual Language:**
- Glassmorphism cards with `BackdropFilter` + `frostedGlass` effect
- Subtle gradient separators
- Animated pulse on online peer indicator
- Smooth page transitions via GoRouter custom transitions

### 7.1 — App Entry & Theme

#### [MODIFY] [main.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/main.dart)

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await HiveDatasource.init();
  await NotificationService.instance.initialize();
  await KeyStore.instance.ensureKeysExist();
  runApp(const ProviderScope(child: SeeOnceApp()));
}
```

#### [NEW] [app.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/app.dart)

- `MaterialApp.router` with `GoRouter`
- Dark `ThemeData` using the color palette above
- `NoScreenshot` widget wrapping the entire app

### 7.2 — Router

Routes:
```
/                     → PeersScreen (home)
/pairing              → PairingScreen
/pairing/show-code    → ShowCodeScreen
/pairing/scan-code    → ScanCodeScreen
/conversation/:peerId → ConversationScreen
/conversation/:peerId/view-image/:messageId → ImageViewerScreen
/settings             → SettingsScreen
```

### 7.3 — Peers Screen (Home)

#### [NEW] [peers_screen.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/features/peers/screens/peers_screen.dart)

- AppBar: "SeeOnce" title + gear icon (→ settings) + "+" FAB (→ pairing)
- Body: `ListView` of `PeerTile`
- Empty state: "No peers yet. Tap + to pair." with illustration

#### [NEW] [peer_tile.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/widgets/peer_tile.dart)

- Avatar with initials + animated online indicator (pulsing green dot)
- `displayName` + last-seen timestamp placeholder
- Badge count of pending (unviewed) images from this peer
- Swipe-to-unpair (with confirmation)
- Tap → `ConversationScreen`

### 7.4 — Pairing Screen

#### [NEW] [pairing_screen.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/features/pairing/screens/pairing_screen.dart)

Two tabs:
- **"Share My Code"** → `ShowCodeScreen`
- **"Enter Peer Code"** → `ScanCodeScreen`

#### [NEW] [show_code_screen.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/features/pairing/screens/show_code_screen.dart)

State machine:
1. **Step 1 (Offer):** Shows QR + text blob of the offer payload. "Share this with your peer."
2. After scanning peer's response: **Step 3 finalization.** Shows "Pairing complete! ✓"

UI elements:
- Large QR code (`QrImageView`)
- "Copy Code" button (copies base64 text)
- "Paste Response" text field + "Finalize" button
- Status indicator: "Generating...", "Share this code", "Waiting for response...", "Paired!"

#### [NEW] [scan_code_screen.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/features/pairing/screens/scan_code_screen.dart)

- `MobileScanner` camera view
- Manual paste text field below camera
- On scan/paste: process offer → show response code screen (Step 2 → show own QR answer)
- Success: "Pairing complete! ✓"

### 7.5 — Conversation Screen

#### [NEW] [conversation_screen.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/features/conversation/screens/conversation_screen.dart)

- AppBar: peer name + online indicator + kebab menu (→ Unpair)
- Body:
    - If peer is offline: banner "Peer is offline — images will be sent when they reconnect" (note: see reconnect strategy in Phase 7.8)
    - Scrollable area showing sent/received image thumbnails (blurred until tapped — "Tap to view once")
    - Each received image shows: sender name, time received, "TAP TO VIEW" overlay
    - Each sent image shows: "Sent" + timestamp + encryption lock icon
- Bottom bar:
    - `SendImageButton` (gallery picker + camera option)
    - Sending progress indicator

**"Tap to view"** → push `ImageViewerScreen` with the `ImageMessage`. On pop, the message is marked as viewed and bytes are zeroed.

### 7.6 — Settings Screen

#### [NEW] [settings_screen.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/features/settings/screens/settings_screen.dart)

Using `settings_ui`:
- **Image Compression** section:
    - `Max Dimension (px)`: slider 320–4096, default 1080
    - `JPEG Quality (%)`: slider 10–100, default 80
    - Preview: "Estimated size for a 12MP photo: ~XXX KB"
- **My Identity** section:
    - Own Peer ID (truncated, copy button)
    - "Regenerate Key Pair" (with warning dialog)
- **About** section: version, open source notice

### 7.7 — Connection Reconnection Strategy

Because WebRTC peer connections are stateful and transient (not persistent across app restarts), implement:

- `PeerConnectionPool` only holds **live** connections (from this session)
- On app launch, `PeersProvider` loads all saved peers from Hive
- Peers start as `isOnline = false`
- **Connection is established on-demand** when the user taps a peer's conversation
- `ConversationProvider.connectToPeer(peerId)` triggers: create RTCPeerConnection, wait for the user to exchange a "reconnect code" (same pairing flow but skipping the key exchange — just SDP + ICE)

> **Design Decision for Reconnection:** Since there is no persistent connection between sessions, the simplest UX is: when a user opens a conversation with an offline peer, they can generate a "reconnect code" (SDP offer without key exchange — keys are already saved) and share it out-of-band again. This is the unavoidable cost of a fully serverless design.
>
> **Alternative:** Implement a lightweight relay using existing platforms (e.g., MQTT on HiveMQ free tier, Firebase Realtime Database free tier) purely for signaling (no image data). This is optional and configurable. Document this option in the settings but do not require it for MVP.

### 7.8 — Send Image Button

#### [NEW] [send_image_button.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/widgets/send_image_button.dart)

- FAB or bottom bar button
- Tapping shows a `BottomSheet` with: "Choose from Gallery" / "Take Photo"
- Uses `ImagePicker`
- On image selected: calls `ImageSender.sendImage(...)`
- Shows `CircularProgressIndicator` with "Compressing...", "Encrypting...", "Sending..." states

**Validation Points:**
- [ ] All screens render without overflow errors on both 5" and 6.7" screens
- [ ] Peers list updates reactively when a peer is added (from pairing) or removed (from unpair)
- [ ] Online indicator turns green when `PeerConnectionPool.isOnline(peerId)` is true
- [ ] Unviewed image badge count updates when new image is received
- [ ] Compression settings slider updates persist across app restarts
- [ ] Sending UI shows correct progress states
- [ ] `ImageViewerScreen` shows the correct image and closes it after back-navigation

---

## Phase 8 — Providers / State Wiring

**Goal:** Wire all Riverpod providers together and ensure correct dependency injection across features.

### Provider Dependency Graph

```
hiveDataSourceProvider (FutureProvider)
    └── peerRepositoryProvider
    └── settingsRepositoryProvider

keyStoreProvider (FutureProvider)
    └── ownPublicKeyProvider
    └── ownPrivateKeyProvider

peerConnectionPoolProvider (Provider) ← singleton

peersProvider (StreamProvider) ← peerRepositoryProvider

pairingProvider (StateNotifierProvider)
    ← keyStoreProvider
    ← peerRepositoryProvider
    ← rtcManagerProvider
    ← peerConnectionPoolProvider

conversationProvider(peerId) (StateNotifierProvider.family)
    ← peerRepositoryProvider
    ← keyStoreProvider
    ← peerConnectionPoolProvider
    ← notificationServiceProvider
    ← settingsRepositoryProvider

settingsProvider (StateNotifierProvider)
    ← settingsRepositoryProvider
```

### Provider Files

#### [NEW] [peers_provider.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/features/peers/providers/peers_provider.dart)
#### [NEW] [pairing_provider.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/features/pairing/providers/pairing_provider.dart)
#### [NEW] [conversation_provider.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/features/conversation/providers/conversation_provider.dart)
#### [NEW] [settings_provider.dart](file:///home/hmawla/Documents/GitHub/seeonce_app/lib/features/settings/providers/settings_provider.dart)

**Validation Points:**
- [ ] `peersProvider` emits updated list when `peerRepository.savePeer` is called
- [ ] `conversationProvider` correctly uses `peerConnectionPool` to send data
- [ ] No circular dependencies between providers
- [ ] App launches without `ProviderNotFoundException`

---

## Phase 9 — Testing & Hardening

**Goal:** Write unit and integration tests, verify all security properties, and address edge cases.

### 9.1 — Unit Tests

#### [NEW] [test/crypto/hybrid_cipher_test.dart]

```dart
// Test: encrypt/decrypt round-trip preserves data
// Test: modified ciphertext fails decryption
// Test: modified encryptedKey fails decryption
// Test: zeroing Uint8List after decrypt
```

#### [NEW] [test/crypto/rsa_cipher_test.dart]

```dart
// Test: RSA-OAEP encrypt/decrypt round-trip
// Test: wrong key fails decrypt
```

#### [NEW] [test/signaling/pairing_code_service_test.dart]

```dart
// Test: encode/decode round-trip
// Test: tampered code throws FormatException
```

#### [NEW] [test/rtc/rtc_channel_handler_test.dart]

```dart
// Test: large byte array chunked and reassembled correctly
// Test: out-of-order chunks (if supported) or strict-order
```

#### [NEW] [test/data/peer_repository_test.dart]

```dart
// Test: save, read, delete peer
// Test: getPeerById returns null for unknown id
```

### 9.2 — Integration Tests

#### [NEW] [integration_test/pairing_flow_test.dart]

Use two `WidgetTester` instances (or two separate test processes on emulators) to:
1. Device A generates offer code
2. Device B processes offer, generates answer code
3. Device A processes answer code
4. Assert: both devices have each other in peer list
5. Assert: `RTCPeerConnection.connectionState == 'connected'`

#### [NEW] [integration_test/image_send_receive_test.dart]

1. Complete pairing
2. Device A picks a test image from assets
3. Device A sends image to Device B
4. Assert: Device B's conversation screen shows a pending image
5. Device B taps to view
6. Assert: image is displayed (non-empty Uint8List)
7. Device B dismisses
8. Assert: image bytes are zeroed (all zeros)

### 9.3 — Security Hardening Checklist

- [ ] **No plaintext image written to disk** — audit all `File.writeAsBytes` calls; none should exist for image data
- [ ] **Exif stripped** — `keepExif: false` in compression
- [ ] **AES key zeroed** after use in `HybridCipher.decrypt`
- [ ] **RSA private key** never leaves `flutter_secure_storage`; never serialized to JSON
- [ ] **Hive box encrypted** with AES-256 key stored in `flutter_secure_storage`
- [ ] **FLAG_SECURE** confirmed blocking screenshot on Android (manual test)
- [ ] **iOS screenshot mitigation** confirmed (UITextField.isSecureTextEntry trick)
- [ ] **No analytics, crash reporting, or network calls** beyond STUN and user-initiated WebRTC
- [ ] **No image data in notifications** (notification payload contains only peer name + messageId)
- [ ] **Memory** — `imageBytes` not kept in `ConversationState` after `markAsViewed` called
- [ ] **Log scrubbing** — no `print` statements containing image data or private keys in production mode

### 9.4 — Edge Cases

| Scenario | Handling |
|---|---|
| App closed mid-transfer | Partial chunks are discarded; `_ChunkBuffer` cleaned up on connection close |
| Peer sends malformed envelope | `try/catch` around JSON parsing + decryption; show error snackbar |
| Decryption fails (wrong key) | Show "Could not decrypt image" error, discard bytes |
| Large image > 10 MB | Pre-flight check: if compressed size > 8 MB, show "Image too large even after compression" |
| STUN unreachable (no internet) | Show "No connection — cannot reach peer" error on pairing |
| Peer uninstalled app | RTCPeerConnection closes → `isOnline = false`, no notification sent |
| Concurrent images from same peer | Each has unique `messageId`; reassembly map handles concurrently |
| App killed during image view | On next launch, `ConversationState` is empty (never persisted) |

---

## File Creation Checklist (Complete)

### Core
- [NEW] `lib/core/constants.dart`
- [NEW] `lib/core/errors.dart`
- [NEW] `lib/core/extensions.dart`

### Crypto
- [NEW] `lib/crypto/key_store.dart`
- [NEW] `lib/crypto/rsa_cipher.dart`
- [NEW] `lib/crypto/hybrid_cipher.dart`

### Data
- [NEW] `lib/data/datasources/hive_datasource.dart`
- [NEW] `lib/data/models/peer.dart`
- [NEW] `lib/data/models/peer.g.dart` *(generated)*
- [NEW] `lib/data/models/image_message.dart`
- [NEW] `lib/data/models/image_envelope.dart`
- [NEW] `lib/data/models/image_envelope.g.dart` *(generated)*
- [NEW] `lib/data/models/pairing_payload.dart`
- [NEW] `lib/data/models/pairing_payload.g.dart` *(generated)*
- [NEW] `lib/data/repositories/peer_repository.dart`
- [NEW] `lib/data/repositories/settings_repository.dart`

### Signaling
- [NEW] `lib/signaling/pairing_code_service.dart`
- [NEW] `lib/signaling/signaling_service.dart`
- [NEW] `lib/signaling/ice_candidate_bundler.dart`

### RTC
- [NEW] `lib/rtc/rtc_manager.dart`
- [NEW] `lib/rtc/rtc_channel_handler.dart`
- [NEW] `lib/rtc/peer_connection_pool.dart`

### Image Pipeline
- [NEW] `lib/image_pipeline/image_compressor.dart`
- [NEW] `lib/image_pipeline/image_sender.dart`

### Notifications
- [NEW] `lib/notifications/notification_service.dart`

### Features — Pairing
- [NEW] `lib/features/pairing/screens/pairing_screen.dart`
- [NEW] `lib/features/pairing/screens/show_code_screen.dart`
- [NEW] `lib/features/pairing/screens/scan_code_screen.dart`
- [NEW] `lib/features/pairing/providers/pairing_provider.dart`

### Features — Peers
- [NEW] `lib/features/peers/screens/peers_screen.dart`
- [NEW] `lib/features/peers/providers/peers_provider.dart`

### Features — Conversation
- [NEW] `lib/features/conversation/screens/conversation_screen.dart`
- [NEW] `lib/features/conversation/screens/image_viewer_screen.dart`
- [NEW] `lib/features/conversation/providers/conversation_provider.dart`

### Features — Settings
- [NEW] `lib/features/settings/screens/settings_screen.dart`
- [NEW] `lib/features/settings/providers/settings_provider.dart`

### Widgets
- [NEW] `lib/widgets/peer_tile.dart`
- [NEW] `lib/widgets/send_image_button.dart`
- [NEW] `lib/widgets/secure_image_widget.dart`

### App Shell
- [MODIFY] `lib/main.dart`
- [NEW] `lib/app.dart`

### Android
- [MODIFY] `android/app/src/main/AndroidManifest.xml`
- [NEW] `android/app/src/main/kotlin/co/kockatoos/seeonce_app/MainActivity.kt`
- [MODIFY] `android/app/build.gradle.kts`

### iOS
- [MODIFY] `ios/Runner/Info.plist`
- [MODIFY] `ios/Runner/AppDelegate.swift`

### Tests
- [NEW] `test/crypto/hybrid_cipher_test.dart`
- [NEW] `test/crypto/rsa_cipher_test.dart`
- [NEW] `test/signaling/pairing_code_service_test.dart`
- [NEW] `test/rtc/rtc_channel_handler_test.dart`
- [NEW] `test/data/peer_repository_test.dart`
- [NEW] `integration_test/pairing_flow_test.dart`
- [NEW] `integration_test/image_send_receive_test.dart`

---

## Implementation Order (for AI Agent)

Follow phases strictly in this order. Do not proceed to the next phase until all validation points of the current phase pass.

1. **Phase 1** — Setup, permissions, `FLAG_SECURE`, pubspec
2. **Phase 2** — Crypto layer + Hive data layer (pure Dart, no UI)
3. **Phase 3** — Signaling & pairing code service (pure Dart, no UI)
4. **Phase 4** — WebRTC manager + chunking + image send/receive pipeline
5. **Phase 5** — View-once logic + memory zeroing
6. **Phase 6** — Local notifications
7. **Phase 7** — All screens + widgets + design system
8. **Phase 8** — Riverpod providers wiring
9. **Phase 9** — Tests + security hardening

> At each phase boundary, run `flutter analyze` and fix all warnings before proceeding.

---

## Open Questions / Design Decisions

> [!IMPORTANT]
> **Reconnection UX**: The plan currently requires a second QR scan for reconnection after app restart (because there is no signaling server). Consider whether to integrate an optional, lightweight MQTT/WebSocket relay for ICE signaling (not for images). The relay would only exchange SDP blobs — no image data — keeping the privacy model intact. This would make reconnection seamless. **Recommend implementing the manual code path first, and adding optional relay in a post-MVP phase.**

> [!IMPORTANT]
> **`flutter_webrtc` is in `dev_dependencies`** in the current `pubspec.yaml`. This is incorrect — it must be in `dependencies`. Fix this in Phase 1.

> [!NOTE]
> **RSA-4096 key generation is slow** (~10-30 seconds on low-end devices). Run it on an `Isolate` in `KeyStore.ensureKeysExist()` and show a one-time loading screen on first launch.

> [!NOTE]
> **Data channel buffered amount**: If the peer's data channel buffer is full, `send()` may throw. Implement flow control: check `dc.bufferedAmount` before sending each chunk; if > 16 MB, wait with `Future.delayed`.

> [!NOTE]
> **TURN server**: Without TURN, peers behind symmetric NAT (common in cellular networks) cannot connect via STUN alone. Document in the settings screen that users can add a custom TURN server URL (e.g., from `metered.ca` free tier). The `PeerConnectionPool` reads the TURN config from `SettingsRepository` when creating connections.
