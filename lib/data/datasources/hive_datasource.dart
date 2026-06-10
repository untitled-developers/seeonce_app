import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../core/constants.dart';
import '../models/peer.dart';

class HiveDatasource {
  static const _secureStorage = FlutterSecureStorage();
  static const _encryptionKeyAlias = 'hive_aes_key';

  static Future<void> init() async {
    await Hive.initFlutter();

    // Register adapters
    Hive.registerAdapter(PeerAdapter());

    // Setup encryption key
    final encryptionKey = await _getOrCreateEncryptionKey();

    // Open boxes
    await Hive.openBox<Peer>(
      AppConstants.peersBoxName,
      encryptionCipher: HiveAesCipher(encryptionKey),
    );

    await Hive.openBox(
      AppConstants.settingsBoxName,
      encryptionCipher: HiveAesCipher(encryptionKey),
    );
  }

  static Future<Uint8List> _getOrCreateEncryptionKey() async {
    String? storedKey = await _secureStorage.read(key: _encryptionKeyAlias);
    if (storedKey == null) {
      final key = Hive.generateSecureKey();
      await _secureStorage.write(
        key: _encryptionKeyAlias,
        value: base64UrlEncode(key),
      );
      return Uint8List.fromList(key);
    }
    return Uint8List.fromList(base64Url.decode(storedKey));
  }
}
