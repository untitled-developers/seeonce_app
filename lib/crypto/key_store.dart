import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

/// Result of an isolate key-generation run: both keys already serialised to
/// their stored string form (serialisation is cheap and keeps the value sent
/// back over the isolate port to plain strings).
class _GeneratedKeyPair {
  final String publicPem;
  final String privatePem;
  const _GeneratedKeyPair(this.publicPem, this.privatePem);
}

/// Top-level entry point for [compute]. RSA-4096 generation is CPU-bound and
/// takes seconds to tens of seconds on real devices, so it must never run on
/// the UI isolate. Runs entirely off-thread and returns serialised strings,
/// which are safe to ship back across the isolate boundary.
_GeneratedKeyPair _generateKeyPairIsolate(int bitLength) {
  final secureRandom = FortunaRandom();
  final random = Random.secure();
  final seeds = List<int>.generate(32, (_) => random.nextInt(256));
  secureRandom.seed(KeyParameter(Uint8List.fromList(seeds)));

  final keyGen = RSAKeyGenerator()
    ..init(ParametersWithRandom(
      RSAKeyGeneratorParameters(BigInt.parse('65537'), bitLength, 64),
      secureRandom,
    ));

  final pair = keyGen.generateKeyPair();
  final pubKey = pair.publicKey as RSAPublicKey;
  final privKey = pair.privateKey as RSAPrivateKey;

  return _GeneratedKeyPair(
    KeyStore.serialisePublicKeyPem(pubKey),
    KeyStore.serialisePrivateKey(privKey),
  );
}

class KeyStore {
  static const _secureStorage = FlutterSecureStorage();
  static const _ownPrivateKeyAlias = 'own_private_key_pem';
  static const _ownPublicKeyAlias = 'own_public_key_pem';

  /// RSA modulus size. Exposed so tests can use a smaller (faster) key.
  static const int rsaKeyBits = 4096;

  static final KeyStore instance = KeyStore._internal();
  KeyStore._internal();

  RSAPublicKey? _publicKeyCache;
  RSAPrivateKey? _privateKeyCache;

  Future<void> ensureKeysExist() async {
    final hasPriv = await _secureStorage.containsKey(key: _ownPrivateKeyAlias);
    final hasPub = await _secureStorage.containsKey(key: _ownPublicKeyAlias);
    if (!hasPriv || !hasPub) await _generateAndStoreKeys();
  }

  Future<RSAPublicKey> getOwnPublicKey() async {
    if (_publicKeyCache != null) return _publicKeyCache!;
    final pem = await _secureStorage.read(key: _ownPublicKeyAlias);
    if (pem == null) throw Exception('Public key not found');
    _publicKeyCache = importPublicKeyPem(pem);
    return _publicKeyCache!;
  }

  Future<RSAPrivateKey> getOwnPrivateKey() async {
    if (_privateKeyCache != null) return _privateKeyCache!;
    final pem = await _secureStorage.read(key: _ownPrivateKeyAlias);
    if (pem == null) throw Exception('Private key not found');
    _privateKeyCache = _importPrivateKeyPem(pem);
    return _privateKeyCache!;
  }

  Future<void> _generateAndStoreKeys() async {
    // Generate off the UI isolate so first launch never freezes / ANRs.
    final generated = await compute(_generateKeyPairIsolate, rsaKeyBits);

    await _secureStorage.write(
        key: _ownPublicKeyAlias, value: generated.publicPem);
    await _secureStorage.write(
        key: _ownPrivateKeyAlias, value: generated.privatePem);

    // Drop caches so the keys are re-parsed lazily on first use.
    _publicKeyCache = null;
    _privateKeyCache = null;
  }

  // ── Persistent storage (PEM wrapper) ─────────────────────────────────────

  /// Full PEM export for storing in secure storage.
  String exportPublicKeyPem(RSAPublicKey key) => serialisePublicKeyPem(key);

  /// Static so the isolate entry point can call it without a KeyStore instance.
  static String serialisePublicKeyPem(RSAPublicKey key) {
    final body = _keyToCompact(key);
    return '-----BEGIN PUBLIC KEY-----\n$body\n-----END PUBLIC KEY-----';
  }

  /// Import from PEM string (as stored in secure storage).
  RSAPublicKey importPublicKeyPem(String pem) {
    final compact = pem
        .replaceAll('-----BEGIN PUBLIC KEY-----', '')
        .replaceAll('-----END PUBLIC KEY-----', '')
        .replaceAll('\n', '')
        .trim();
    return _keyFromCompact(compact);
  }

  // ── Pairing payload format (compact, no PEM headers) ─────────────────────

  /// Compact base64url export for embedding in QR / pairing codes.
  /// A 4096-bit RSA key encodes to ~683 chars here vs ~1234 chars (decimal).
  String exportPublicKeyCompact(RSAPublicKey key) => _keyToCompact(key);

  /// Import from compact base64url string (no PEM headers needed).
  RSAPublicKey importPublicKeyCompact(String compact) =>
      _keyFromCompact(compact);

  // ── Private serialisation helpers ─────────────────────────────────────────

  /// Encodes the modulus and exponent as big-endian byte arrays, then
  /// JSON-encodes and base64url-encodes the whole thing.
  static String _keyToCompact(RSAPublicKey key) {
    final map = {
      'n': base64Url.encode(_bigIntToBytes(key.modulus!)),
      'e': base64Url.encode(_bigIntToBytes(key.exponent!)),
    };
    return base64Url.encode(utf8.encode(jsonEncode(map)));
  }

  RSAPublicKey _keyFromCompact(String compact) {
    final json =
        jsonDecode(utf8.decode(base64Url.decode(_pad(compact)))) as Map;
    return RSAPublicKey(
      _bytesToBigInt(base64Url.decode(_pad(json['n'] as String))),
      _bytesToBigInt(base64Url.decode(_pad(json['e'] as String))),
    );
  }

  static Uint8List _bigIntToBytes(BigInt n) {
    assert(n >= BigInt.zero);
    if (n == BigInt.zero) return Uint8List(1);
    final hex = n.toRadixString(16);
    final padded = hex.length.isOdd ? '0$hex' : hex;
    return Uint8List.fromList([
      for (var i = 0; i < padded.length; i += 2)
        int.parse(padded.substring(i, i + 2), radix: 16),
    ]);
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  /// Re-adds base64 padding stripped by base64Url.
  static String _pad(String s) {
    final rem = s.length % 4;
    return rem == 0 ? s : '$s${'=' * (4 - rem)}';
  }

  /// Static so the isolate entry point can serialise without an instance.
  static String serialisePrivateKey(RSAPrivateKey key) {
    final map = {
      'n': key.modulus!.toString(),
      'e': key.publicExponent!.toString(),
      'd': key.privateExponent!.toString(),
      'p': key.p!.toString(),
      'q': key.q!.toString(),
    };
    return base64Encode(utf8.encode(jsonEncode(map)));
  }

  RSAPrivateKey _importPrivateKeyPem(String pem) {
    final map =
        jsonDecode(utf8.decode(base64Decode(pem))) as Map<String, dynamic>;
    // RSAPrivateKey derives publicExponent from p, q and the stored exponent so
    // callers that read key.publicExponent get a non-null value.
    return RSAPrivateKey(
      BigInt.parse(map['n'] as String),
      BigInt.parse(map['d'] as String),
      BigInt.parse(map['p'] as String),
      BigInt.parse(map['q'] as String),
    );
  }
}
