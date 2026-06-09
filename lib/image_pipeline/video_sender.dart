import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import '../core/constants.dart';
import '../core/errors.dart';
import '../crypto/hybrid_cipher.dart';
import '../crypto/key_store.dart';
import '../data/models/peer.dart';
import '../data/models/video_envelope.dart';
import '../rtc/rtc_channel_handler.dart';
import 'video_compressor.dart';

/// Compresses, trims (10s), encrypts and sends a view-once video over the data
/// channel, mirroring [ImageSender].
class VideoSender {
  static final VideoSender instance = VideoSender._internal();
  VideoSender._internal();

  final _uuid = const Uuid();

  Future<void> sendVideo({
    required String filePath,
    required Peer recipient,
    required RTCDataChannel dataChannel,
    required String ownPeerId,
    required RtcChannelHandler channelHandler,
  }) async {
    // 1. Compress + trim.
    final compressed = await VideoCompressor.compress(filePath);
    if (compressed == null) {
      throw const CryptoError('Failed to compress video');
    }

    final mutableBytes = Uint8List.fromList(compressed.bytes);
    try {
      if (mutableBytes.length > AppConstants.maxVideoBytes) {
        throw ImageTooLargeError(
            'Compressed video is ${mutableBytes.length} bytes, over the '
            '${AppConstants.maxVideoBytes}-byte limit');
      }

      // 2. Encrypt.
      final recipientPublicKey =
          KeyStore.instance.importPublicKeyPem(recipient.publicKeyPem);
      final encrypted =
          await HybridCipher.encrypt(recipientPublicKey, mutableBytes);

      // 3. Envelope.
      final messageId = _uuid.v4();
      final envelope = VideoEnvelope(
        messageId: messageId,
        senderId: ownPeerId,
        encryptedKey: base64Encode(encrypted.encryptedKey),
        iv: base64Encode(encrypted.iv),
        ciphertext: base64Encode(encrypted.ciphertext),
        durationMs: compressed.durationMs,
        sentAt: DateTime.now().toUtc().toIso8601String(),
      );

      // 4. Send chunks.
      final envelopeBytes = utf8.encode(jsonEncode(envelope.toJson()));
      await channelHandler.sendEncryptedPayload(
        dc: dataChannel,
        encryptedPayload: Uint8List.fromList(envelopeBytes),
        messageId: messageId,
        senderId: ownPeerId,
      );
    } finally {
      // 5. Zero-fill the plaintext copy and remove the compressor's temp file.
      mutableBytes.fillRange(0, mutableBytes.length, 0);
      try {
        final f = File(compressed.path);
        if (await f.exists()) await f.delete();
      } catch (e) {
        if (kDebugMode) debugPrint('[VideoSender] temp cleanup failed: $e');
      }
    }
  }
}
