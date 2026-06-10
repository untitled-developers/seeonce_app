import 'dart:typed_data';
import 'package:pointycastle/export.dart';

class RsaCipher {
  // RSA-OAEP with SHA-256 (and SHA-256 MGF1). The bare OAEPEncoding(engine)
  // factory defaults to SHA-1, which is below current best practice; both
  // peers must use the same digest, so this is a wire-format choice.
  static Uint8List encryptWithPublicKey(RSAPublicKey publicKey, Uint8List data) {
    final encryptor = OAEPEncoding.withSHA256(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(publicKey));
    return _processInBlocks(encryptor, data);
  }

  static Uint8List decryptWithPrivateKey(RSAPrivateKey privateKey, Uint8List data) {
    final decryptor = OAEPEncoding.withSHA256(RSAEngine())
      ..init(false, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    return _processInBlocks(decryptor, data);
  }

  // SHA-256 digest identifier (DER OID) for RSASSA-PKCS1-v1_5 signatures.
  static const String _sha256DigestId = '0609608648016503040201';

  /// Signs [message] with [privateKey] (RSASSA-PKCS1-v1_5 / SHA-256). Used to
  /// prove possession of a peer's private key during LAN reconnect.
  static Uint8List signWithPrivateKey(
      RSAPrivateKey privateKey, Uint8List message) {
    final signer = RSASigner(SHA256Digest(), _sha256DigestId)
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    return signer.generateSignature(message).bytes;
  }

  /// Verifies [signature] over [message] against [publicKey]. Returns false on
  /// any malformed input rather than throwing.
  static bool verifyWithPublicKey(
      RSAPublicKey publicKey, Uint8List message, Uint8List signature) {
    final signer = RSASigner(SHA256Digest(), _sha256DigestId)
      ..init(false, PublicKeyParameter<RSAPublicKey>(publicKey));
    try {
      return signer.verifySignature(message, RSASignature(signature));
    } catch (_) {
      return false;
    }
  }

  static Uint8List _processInBlocks(AsymmetricBlockCipher engine, Uint8List input) {
    final outBytes = BytesBuilder();
    int offset = 0;
    while (offset < input.length) {
      final chunkSize = (input.length - offset > engine.inputBlockSize)
          ? engine.inputBlockSize
          : input.length - offset;
      final chunk = input.sublist(offset, offset + chunkSize);
      outBytes.add(engine.process(chunk));
      offset += chunkSize;
    }
    return outBytes.toBytes();
  }
}
