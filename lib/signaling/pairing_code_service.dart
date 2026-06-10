import 'dart:convert';
import 'dart:io';
import '../data/models/pairing_payload.dart';

class PairingCodeService {
  static final PairingCodeService instance = PairingCodeService._internal();
  PairingCodeService._internal();

  String encode(PairingPayload payload) {
    final jsonString = jsonEncode(payload.toJson());
    final bytes = utf8.encode(jsonString);
    final gzipped = gzip.encode(bytes);
    return base64UrlEncode(gzipped);
  }

  PairingPayload decode(String code) {
    try {
      final gzipped = base64Url.decode(code);
      final bytes = gzip.decode(gzipped);
      final jsonString = utf8.decode(bytes);
      final map = jsonDecode(jsonString) as Map<String, dynamic>;
      return PairingPayload.fromJson(map);
    } catch (e) {
      throw const FormatException("Invalid pairing code");
    }
  }
}
