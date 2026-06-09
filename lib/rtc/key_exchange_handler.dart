import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../crypto/key_store.dart';
import '../data/models/peer.dart';

/// Silently exchanges RSA public keys between two peers over an open
/// [RTCDataChannel] (which is already protected by DTLS at the transport layer).
///
/// Protocol (one round trip):
///   → Both sides send `{ "type": "key_exchange", "peerId", "displayName", "publicKey" }`
///   → Both sides listen for the partner's message
///   → On receipt, construct a [Peer] object with the partner's RSA public key
///
/// The user never sees or touches these messages.
class KeyExchangeHandler {
  static const String _msgType = 'key_exchange';

  final String ownPeerId;
  final String ownDisplayName;

  KeyExchangeHandler({
    required this.ownPeerId,
    required this.ownDisplayName,
  });

  /// Sends our RSA public key to the partner over [dc].
  /// Must be called only when [dc.state == RTCDataChannelOpen].
  Future<void> sendKey(RTCDataChannel dc) async {
    final ks = KeyStore.instance;
    final pubKey = await ks.getOwnPublicKey();
    final msg = jsonEncode({
      'type': _msgType,
      'peerId': ownPeerId,
      'displayName': ownDisplayName,
      'publicKey': ks.exportPublicKeyCompact(pubKey),
    });
    dc.send(RTCDataChannelMessage(msg));
  }

  /// Call with every incoming text message on the data channel.
  ///
  /// Returns a fully-populated [Peer] if the message is a valid key-exchange
  /// message, or `null` if it's any other message type (image chunks, etc.).
  Peer? onMessage(String text) {
    try {
      final map = jsonDecode(text) as Map<String, dynamic>;
      if (map['type'] != _msgType) return null;

      final ks = KeyStore.instance;
      final rsaKey = ks.importPublicKeyCompact(map['publicKey'] as String);
      final pem = ks.exportPublicKeyPem(rsaKey);

      return Peer(
        id: map['peerId'] as String,
        displayName: map['displayName'] as String,
        publicKeyPem: pem,
        pairedAt: DateTime.now(),
      );
    } catch (e, st) {
      if (kDebugMode) debugPrint('[KeyExchange] onMessage parse error: $e\n$st');
      return null;
    }
  }
}
