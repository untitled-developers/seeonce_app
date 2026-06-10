import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:seeonce_app/signaling/ice_candidate_bundler.dart';

RTCIceCandidate _cand(String typ) => RTCIceCandidate(
      'candidate:1 1 UDP 100 192.168.0.1 5000 typ $typ',
      '0',
      0,
    );

void main() {
  group('IceCandidateBundler', () {
    test('bundles host and srflx, drops unrecognised types, completes on null',
        () async {
      final b = IceCandidateBundler();
      b.onCandidate(_cand('host'));
      b.onCandidate(_cand('srflx')); // public address for cross-network
      b.onCandidate(_cand('prflx')); // should be ignored
      b.onCandidate(null); // end-of-gathering

      final result = await b.candidates;
      final types = result
          .map((c) => RegExp(r'typ (\w+)').firstMatch(c.candidate ?? '')?.group(1))
          .toList();
      expect(types, containsAll(['host', 'srflx']));
      expect(types, isNot(contains('prflx')));
      expect(result.length, equals(2));
    });

    test('still completes with host-only when no public candidate arrives',
        () async {
      final b = IceCandidateBundler();
      b.onCandidate(_cand('host'));
      b.onCandidate(null);
      final result = await b.candidates;
      expect(result.length, equals(1));
    });
  });
}
