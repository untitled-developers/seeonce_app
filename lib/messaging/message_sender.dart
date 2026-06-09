import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import '../crypto/hybrid_cipher.dart';
import '../crypto/key_store.dart';
import '../data/models/peer.dart';
import '../data/models/text_envelope.dart';
import '../data/models/text_message.dart';
import '../rtc/rtc_channel_handler.dart';

/// Sends end-to-end encrypted text messages over the WebRTC data channel,
/// reusing the same hybrid scheme and chunked transport as images.
class MessageSender {
  static final MessageSender instance = MessageSender._internal();
  MessageSender._internal();

  final _uuid = const Uuid();

  /// Encrypts [text] for [recipient] and sends it. Returns the local
  /// [TextMessage] (marked `isMine`) so the UI can display it immediately.
  Future<TextMessage> sendText({
    required String text,
    required Peer recipient,
    required RTCDataChannel dataChannel,
    required String ownPeerId,
    required RtcChannelHandler channelHandler,
  }) async {
    final messageId = _uuid.v4();
    final now = DateTime.now();

    final plaintext = Uint8List.fromList(utf8.encode(text));
    final recipientPublicKey =
        KeyStore.instance.importPublicKeyPem(recipient.publicKeyPem);
    final encrypted = await HybridCipher.encrypt(recipientPublicKey, plaintext);
    plaintext.fillRange(0, plaintext.length, 0);

    final envelope = TextEnvelope(
      messageId: messageId,
      senderId: ownPeerId,
      encryptedKey: base64Encode(encrypted.encryptedKey),
      iv: base64Encode(encrypted.iv),
      ciphertext: base64Encode(encrypted.ciphertext),
      // Sender wall-clock, kept for metadata only; ordering/expiry use the
      // receiver's local clock (clock skew makes the sender's time unreliable).
      sentAt: now.toUtc().toIso8601String(),
    );

    final envelopeBytes = utf8.encode(jsonEncode(envelope.toJson()));
    await channelHandler.sendEncryptedPayload(
      dc: dataChannel,
      encryptedPayload: Uint8List.fromList(envelopeBytes),
      messageId: messageId,
      senderId: ownPeerId,
    );

    return TextMessage(
      messageId: messageId,
      senderId: ownPeerId,
      text: text,
      localAt: now,
      isMine: true,
    );
  }
}
