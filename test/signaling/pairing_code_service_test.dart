import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:seeonce_app/signaling/pairing_code_service.dart';
import 'package:seeonce_app/data/models/pairing_payload.dart';

void main() {
  group('PairingCodeService', () {
    final service = PairingCodeService.instance;

    PairingPayload buildPayload() => PairingPayload(
          step: 'offer',
          peerId: 'test-peer-id-1234',
          displayName: 'Alice',
          sdp: 'v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n',
          iceCandidates: [
            jsonEncode({
              'candidate':
                  'a=candidate:1 1 UDP 100 192.168.0.1 5000 typ host',
              'sdpMid': '0',
              'sdpMLineIndex': 0,
            }),
          ],
        );

    test('encode/decode round-trip preserves all fields', () {
      final payload = buildPayload();
      final code = service.encode(payload);
      expect(code, isNotEmpty);

      final decoded = service.decode(code);
      expect(decoded.step, equals(payload.step));
      expect(decoded.peerId, equals(payload.peerId));
      expect(decoded.displayName, equals(payload.displayName));
      expect(decoded.sdp, equals(payload.sdp));
      expect(decoded.iceCandidates.length, equals(1));
    });

    test('encoded string is base64url (no + or /)', () {
      final code = service.encode(buildPayload());
      expect(code.contains('+'), isFalse);
      expect(code.contains('/'), isFalse);
    });

    test('encoded code length fits within QR capacity', () {
      final code = service.encode(buildPayload());
      // QR Version 40 Level L max is 2953 bytes.
      // Even a real SDP + ICE candidates should fit well within this.
      expect(code.length, lessThan(2953));
    });

    test('payload with host + srflx candidates still fits within QR capacity',
        () {
      final payload = PairingPayload(
        step: 'offer',
        peerId: 'test-peer-id-1234',
        displayName: 'Alice',
        sdp: 'v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n'
            'a=fingerprint:sha-256 ${'AB:' * 31}AB\r\n',
        iceCandidates: [
          jsonEncode({
            'candidate': 'candidate:1 1 UDP 2122260223 192.168.0.1 50001 typ host',
            'sdpMid': '0',
            'sdpMLineIndex': 0,
          }),
          jsonEncode({
            'candidate':
                'candidate:2 1 UDP 1686052607 203.0.113.7 50002 typ srflx raddr 192.168.0.1 rport 50001',
            'sdpMid': '0',
            'sdpMLineIndex': 0,
          }),
        ],
      );
      final code = service.encode(payload);
      expect(code.length, lessThan(2953));
    });

    test('tampered code throws FormatException or StateError', () {
      final code = service.encode(buildPayload());
      final tampered = code.replaceRange(10, 15, 'XXXXX');
      expect(() => service.decode(tampered), throwsA(anything));
    });
  });
}
