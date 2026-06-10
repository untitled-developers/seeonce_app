import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:pointycastle/export.dart';
import '../core/errors.dart';
import 'rsa_cipher.dart';

class HybridEncryptedPayload {
  final Uint8List encryptedKey;
  final Uint8List iv;
  final Uint8List ciphertext;

  HybridEncryptedPayload({
    required this.encryptedKey,
    required this.iv,
    required this.ciphertext,
  });
}

class HybridCipher {
  static final crypto.AesGcm _aesGcm = crypto.AesGcm.with256bits();

  static Future<HybridEncryptedPayload> encrypt(
      RSAPublicKey peerPublicKey, Uint8List plaintext) async {
    // Generate AES key and IV
    final secretKey = await _aesGcm.newSecretKey();
    final nonce = _aesGcm.newNonce();
    
    // Encrypt the plaintext with AES-GCM
    final secretBox = await _aesGcm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
    );

    // Encrypt the AES key with RSA-OAEP
    final aesKeyBytes = await secretKey.extractBytes();
    final encryptedKey = RsaCipher.encryptWithPublicKey(
      peerPublicKey,
      Uint8List.fromList(aesKeyBytes),
    );

    return HybridEncryptedPayload(
      encryptedKey: encryptedKey,
      iv: Uint8List.fromList(secretBox.nonce),
      ciphertext: Uint8List.fromList(secretBox.cipherText + secretBox.mac.bytes),
    );
  }

  /// AES-256-GCM: 32-byte key, 16-byte auth tag.
  static const int _aesKeyLength = 32;
  static const int _gcmTagLength = 16;

  static Future<Uint8List> decrypt(
      RSAPrivateKey ownPrivateKey,
      Uint8List encryptedKey,
      Uint8List iv,
      Uint8List ciphertext) async {
    // Validate the envelope shape before touching the crypto primitives, so
    // malformed input fails as a typed DecryptionError instead of a raw
    // RangeError / low-level exception leaking out.
    if (ciphertext.length < _gcmTagLength) {
      throw const DecryptionError('Ciphertext too short to contain a GCM tag');
    }
    if (iv.isEmpty) {
      throw const DecryptionError('Missing AES-GCM nonce');
    }

    // Decrypt the AES key using RSA.
    Uint8List aesKeyBytes;
    try {
      aesKeyBytes = RsaCipher.decryptWithPrivateKey(ownPrivateKey, encryptedKey);
    } catch (e) {
      throw DecryptionError('RSA key unwrap failed: $e');
    }

    if (aesKeyBytes.length != _aesKeyLength) {
      aesKeyBytes.fillRange(0, aesKeyBytes.length, 0);
      throw DecryptionError(
          'Unwrapped AES key has unexpected length ${aesKeyBytes.length}');
    }

    final secretKey = crypto.SecretKey(aesKeyBytes);

    // Separate cipherText and MAC (last 16 bytes for AES-GCM).
    final macBytes = ciphertext.sublist(ciphertext.length - _gcmTagLength);
    final actualCiphertext =
        ciphertext.sublist(0, ciphertext.length - _gcmTagLength);

    final secretBox = crypto.SecretBox(
      actualCiphertext,
      nonce: iv,
      mac: crypto.Mac(macBytes),
    );

    try {
      // Decrypt the actual payload (throws on auth-tag mismatch / tampering).
      final plaintext = await _aesGcm.decrypt(
        secretBox,
        secretKey: secretKey,
      );
      return Uint8List.fromList(plaintext);
    } catch (e) {
      throw DecryptionError('AES-GCM decryption failed: $e');
    } finally {
      // Zero-fill intermediate key material on every path.
      aesKeyBytes.fillRange(0, aesKeyBytes.length, 0);
    }
  }
}
