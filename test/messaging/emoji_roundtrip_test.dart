import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:pointycastle/export.dart';
import 'package:seeonce_app/crypto/hybrid_cipher.dart';
import 'package:seeonce_app/data/models/text_envelope.dart';
import 'package:seeonce_app/rtc/rtc_channel_handler.dart';

AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _genKeys() {
  final sr = FortunaRandom()
    ..seed(KeyParameter(
        Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 13) % 256))));
  final kg = RSAKeyGenerator()
    ..init(ParametersWithRandom(
      RSAKeyGeneratorParameters(BigInt.parse('65537'), 1024, 12),
      sr,
    ));
  final p = kg.generateKeyPair();
  return AsymmetricKeyPair(p.publicKey as RSAPublicKey, p.privateKey as RSAPrivateKey);
}

/// Captures every RTCDataChannelMessage sent and replays it into a receiver.
class _FakeDc implements RTCDataChannel {
  final List<RTCDataChannelMessage> sent = [];
  @override
  Future<void> send(RTCDataChannelMessage message) async => sent.add(message);
  @override
  int? get bufferedAmount => 0;
  @override
  RTCDataChannelState? get state => RTCDataChannelState.RTCDataChannelOpen;
  @override
  noSuchMethod(Invocation invocation) => null;
}

void main() {
  test('emoji + arabic survive the full send→wire→receive pipeline', () async {
    final keys = _genKeys();
    const text = 'Hello 😀🎉 مرحبا 👨‍👩‍👧‍👦 done';

    // ── Send side (mirrors MessageSender.sendText) ──
    final plaintext = Uint8List.fromList(utf8.encode(text));
    final enc = await HybridCipher.encrypt(keys.publicKey, plaintext);
    final envelope = TextEnvelope(
      messageId: 'msg-1',
      senderId: 'me',
      encryptedKey: base64Encode(enc.encryptedKey),
      iv: base64Encode(enc.iv),
      ciphertext: base64Encode(enc.ciphertext),
      sentAt: DateTime(2026).toUtc().toIso8601String(),
    );
    final envelopeBytes = Uint8List.fromList(utf8.encode(jsonEncode(envelope.toJson())));

    final dc = _FakeDc();
    final sender = RtcChannelHandler();
    await sender.sendEncryptedPayload(
      dc: dc,
      encryptedPayload: envelopeBytes,
      messageId: 'msg-1',
      senderId: 'me',
    );

    // ── Receive side (replay captured frames) ──
    final receiver = RtcChannelHandler();
    final got = <Uint8List>[];
    receiver.incomingPayloads.listen(got.add);
    for (final m in dc.sent) {
      receiver.onMessage(m);
    }
    await Future<void>.delayed(Duration.zero);

    expect(got, hasLength(1));
    final received = TextEnvelope.fromJson(
        jsonDecode(utf8.decode(got.single)) as Map<String, dynamic>);
    final decrypted = await HybridCipher.decrypt(
      keys.privateKey,
      base64Decode(received.encryptedKey),
      base64Decode(received.iv),
      base64Decode(received.ciphertext),
    );
    expect(utf8.decode(decrypted), equals(text));

    sender.dispose();
    receiver.dispose();
  });
}
