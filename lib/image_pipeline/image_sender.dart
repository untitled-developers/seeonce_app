import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import '../core/constants.dart';
import '../core/errors.dart';
import '../crypto/key_store.dart';
import '../crypto/hybrid_cipher.dart';
import '../data/models/image_envelope.dart';
import '../data/models/peer.dart';
import '../data/repositories/settings_repository.dart';
import '../rtc/rtc_channel_handler.dart';
import 'image_compressor.dart';

class ImageSender {
  static final ImageSender instance = ImageSender._internal();
  ImageSender._internal();
  final _uuid = const Uuid();

  Future<void> sendImage({
    required String filePath,
    required Peer recipient,
    required RTCDataChannel dataChannel,
    required CompressionSettings compressionSettings,
    required String ownPeerId,
    required RtcChannelHandler channelHandler,
  }) async {
    // 1. Compress
    final compressedBytes = await ImageCompressor.compress(
      filePath: filePath,
      settings: compressionSettings,
    );

    if (compressedBytes == null) {
      throw Exception("Failed to compress image");
    }

    // flutter_image_compress returns an unmodifiable view; copy to mutable buffer
    // so we can zero-fill it after use.
    final mutableCompressed = Uint8List.fromList(compressedBytes);

    // Reject anything that would exceed the receiver's payload limit, surfacing
    // it as a typed, user-presentable error.
    if (mutableCompressed.length > AppConstants.maxImageBytes) {
      mutableCompressed.fillRange(0, mutableCompressed.length, 0);
      throw ImageTooLargeError(
          'Compressed image is ${mutableCompressed.length} bytes, over the '
          '${AppConstants.maxImageBytes}-byte limit');
    }

    // Decode the real dimensions instead of assuming a square at maxDimension.
    final codec = await ui.instantiateImageCodec(mutableCompressed);
    final frame = await codec.getNextFrame();
    final width = frame.image.width;
    final height = frame.image.height;
    frame.image.dispose();
    codec.dispose();

    // 2. Encrypt
    final recipientPublicKey = KeyStore.instance.importPublicKeyPem(recipient.publicKeyPem); // KeyStore imported locally
    final encryptedPayload = await HybridCipher.encrypt(recipientPublicKey, mutableCompressed);

    // 3. Envelope
    final messageId = _uuid.v4();
    final envelope = ImageEnvelope(
      messageId: messageId,
      senderId: ownPeerId,
      type: AppConstants.msgTypeImage,
      encryptedKey: base64Encode(encryptedPayload.encryptedKey),
      iv: base64Encode(encryptedPayload.iv),
      ciphertext: base64Encode(encryptedPayload.ciphertext),
      mimeType: "image/jpeg",
      originalWidth: width,
      originalHeight: height,
      sentAt: DateTime.now().toUtc().toIso8601String(),
    );

    final envelopeJson = jsonEncode(envelope.toJson());
    final envelopeBytes = utf8.encode(envelopeJson);

    // 4. Send Chunks
    await channelHandler.sendEncryptedPayload(
      dc: dataChannel,
      encryptedPayload: Uint8List.fromList(envelopeBytes),
      messageId: messageId,
      senderId: ownPeerId,
    );

    // 5. Zero-fill
    mutableCompressed.fillRange(0, mutableCompressed.length, 0);
  }
}


