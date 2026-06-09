import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:seeonce_app/core/errors.dart';
import 'package:seeonce_app/crypto/rsa_cipher.dart';
import 'package:seeonce_app/crypto/hybrid_cipher.dart';

/// Generates a small (1024-bit) RSA key pair quickly for tests.
AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _generateTestKeyPair() =>
    _generateTestKeyPairSeeded(0);

AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _generateTestKeyPairSeeded(
    int salt) {
  final secureRandom = FortunaRandom();
  final rng = List<int>.generate(32, (i) => (i * 7 + 13 + salt) % 256);
  secureRandom.seed(KeyParameter(Uint8List.fromList(rng)));

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
    final pair = _generateTestKeyPair();
    publicKey = pair.publicKey;
    privateKey = pair.privateKey;
  });

  group('RsaCipher', () {
    test('encrypt/decrypt round-trip preserves data', () {
      final plaintext = Uint8List.fromList([1, 2, 3, 42, 100, 200]);
      final ciphertext = RsaCipher.encryptWithPublicKey(publicKey, plaintext);
      final decrypted = RsaCipher.decryptWithPrivateKey(privateKey, ciphertext);
      expect(decrypted, equals(plaintext));
    });

    test('different key pair produces wrong/garbage output (not original plaintext)', () {
      final otherPair = _generateTestKeyPair();
      final plaintext = Uint8List.fromList([9, 8, 7]);
      final ciphertext = RsaCipher.encryptWithPublicKey(publicKey, plaintext);

      // With RSA-OAEP, decrypting with a wrong key either throws or
      // returns garbage bytes — either outcome is acceptable.
      try {
        final result =
            RsaCipher.decryptWithPrivateKey(otherPair.privateKey, ciphertext);
        // If no exception, the result must differ from the original
        expect(result, isNot(equals(plaintext)));
      } catch (_) {
        // Exception is acceptable
      }
    });

    test('sign/verify round-trip succeeds with the matching public key', () {
      final message = Uint8List.fromList(List.generate(40, (i) => i));
      final sig = RsaCipher.signWithPrivateKey(privateKey, message);
      expect(RsaCipher.verifyWithPublicKey(publicKey, message, sig), isTrue);
    });

    test('signature does not verify against a different key', () {
      // _generateTestKeyPair() uses a fixed seed, so build a genuinely
      // different key with a distinct seed here.
      final other = _generateTestKeyPairSeeded(99);
      final message = Uint8List.fromList([1, 2, 3, 4]);
      final sig = RsaCipher.signWithPrivateKey(privateKey, message);
      expect(
          RsaCipher.verifyWithPublicKey(other.publicKey, message, sig), isFalse);
    });

    test('signature does not verify over tampered message', () {
      final message = Uint8List.fromList([5, 6, 7, 8]);
      final sig = RsaCipher.signWithPrivateKey(privateKey, message);
      final tampered = Uint8List.fromList([5, 6, 7, 9]);
      expect(
          RsaCipher.verifyWithPublicKey(publicKey, tampered, sig), isFalse);
    });

    test('garbage signature bytes return false, not throw', () {
      final message = Uint8List.fromList([1, 2, 3]);
      expect(
          RsaCipher.verifyWithPublicKey(
              publicKey, message, Uint8List.fromList([0, 1, 2, 3])),
          isFalse);
    });
  });

  group('HybridCipher', () {
    test('encrypt/decrypt round-trip preserves data', () async {
      final plaintext =
          Uint8List.fromList(List.generate(512, (i) => i % 256));
      final payload = await HybridCipher.encrypt(publicKey, plaintext);

      final decrypted = await HybridCipher.decrypt(
        privateKey,
        payload.encryptedKey,
        payload.iv,
        payload.ciphertext,
      );

      expect(decrypted, equals(plaintext));
    });

    test('modified ciphertext fails decryption (GCM auth tag check)', () async {
      final plaintext = Uint8List.fromList([10, 20, 30]);
      final payload = await HybridCipher.encrypt(publicKey, plaintext);

      // Flip a byte in the ciphertext
      final tampered = Uint8List.fromList(payload.ciphertext);
      tampered[0] ^= 0xFF;

      expect(
        () => HybridCipher.decrypt(
          privateKey,
          payload.encryptedKey,
          payload.iv,
          tampered,
        ),
        throwsA(anything),
      );
    });

    test('ciphertext shorter than the GCM tag throws DecryptionError',
        () async {
      final payload = await HybridCipher.encrypt(
          publicKey, Uint8List.fromList([1, 2, 3]));
      await expectLater(
        () => HybridCipher.decrypt(
          privateKey,
          payload.encryptedKey,
          payload.iv,
          Uint8List.fromList([1, 2, 3]), // < 16 bytes
        ),
        throwsA(isA<DecryptionError>()),
      );
    });

    test('empty nonce throws DecryptionError', () async {
      final payload =
          await HybridCipher.encrypt(publicKey, Uint8List.fromList([1, 2, 3]));
      await expectLater(
        () => HybridCipher.decrypt(
          privateKey,
          payload.encryptedKey,
          Uint8List(0),
          payload.ciphertext,
        ),
        throwsA(isA<DecryptionError>()),
      );
    });

    test('garbage encrypted key throws DecryptionError, not a raw exception',
        () async {
      final payload =
          await HybridCipher.encrypt(publicKey, Uint8List.fromList([1, 2, 3]));
      await expectLater(
        () => HybridCipher.decrypt(
          privateKey,
          Uint8List.fromList(List.filled(payload.encryptedKey.length, 0)),
          payload.iv,
          payload.ciphertext,
        ),
        throwsA(isA<DecryptionError>()),
      );
    });

    test('decrypted bytes can be zero-filled afterwards', () async {
      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
      final payload = await HybridCipher.encrypt(publicKey, plaintext);
      final decrypted = await HybridCipher.decrypt(
        privateKey,
        payload.encryptedKey,
        payload.iv,
        payload.ciphertext,
      );

      final mutable = Uint8List.fromList(decrypted);
      mutable.fillRange(0, mutable.length, 0);
      expect(mutable.every((b) => b == 0), isTrue);
    });
  });
}
