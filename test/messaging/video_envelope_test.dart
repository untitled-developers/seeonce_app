import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:seeonce_app/crypto/hybrid_cipher.dart';
import 'package:seeonce_app/data/models/video_envelope.dart';

AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _testKeyPair() {
  final secureRandom = FortunaRandom();
  secureRandom.seed(
      KeyParameter(Uint8List.fromList(List.generate(32, (i) => i * 7 + 13))));
  final keyGen = RSAKeyGenerator()
    ..init(ParametersWithRandom(
      RSAKeyGeneratorParameters(BigInt.parse('65537'), 1024, 12),
      secureRandom,
    ));
  final pair = keyGen.generateKeyPair();
  return AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey>(
    pair.publicKey as RSAPublicKey,
    pair.privateKey as RSAPrivateKey,
  );
}

void main() {
  late RSAPublicKey publicKey;
  late RSAPrivateKey privateKey;

  setUpAll(() {
    final pair = _testKeyPair();
    publicKey = pair.publicKey;
    privateKey = pair.privateKey;
  });

  test('VideoEnvelope encrypt -> JSON -> decrypt round-trips bytes + metadata',
      () async {
    // Stand-in for compressed video bytes.
    final original =
        Uint8List.fromList(List.generate(4096, (i) => (i * 31) % 256));
    final encrypted = await HybridCipher.encrypt(publicKey, original);

    final envelope = VideoEnvelope(
      messageId: 'vid-1',
      senderId: 'peer-1',
      encryptedKey: base64Encode(encrypted.encryptedKey),
      iv: base64Encode(encrypted.iv),
      ciphertext: base64Encode(encrypted.ciphertext),
      durationMs: 9500,
      sentAt: DateTime.utc(2026, 1, 1).toIso8601String(),
    );

    final parsed = VideoEnvelope.fromJson(
        jsonDecode(jsonEncode(envelope.toJson())) as Map<String, dynamic>);
    expect(parsed.type, equals('video'));
    expect(parsed.durationMs, equals(9500));
    expect(parsed.mimeType, equals('video/mp4'));

    final decrypted = await HybridCipher.decrypt(
      privateKey,
      base64Decode(parsed.encryptedKey),
      base64Decode(parsed.iv),
      base64Decode(parsed.ciphertext),
    );
    expect(decrypted, equals(original));
  });
}
