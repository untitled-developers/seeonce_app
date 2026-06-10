import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:seeonce_app/data/models/peer.dart';
import 'package:seeonce_app/rtc/connection_supervisor.dart';

Peer _peer(String id) => Peer(
      id: id,
      displayName: 'Peer $id',
      publicKeyPem: 'pem-$id',
      pairedAt: DateTime(2024, 1, 1),
    );

void main() {
  group('ConnectionSupervisor.backoffFor', () {
    test('is monotonic and capped at 60s', () {
      expect(ConnectionSupervisor.backoffFor(1), const Duration(seconds: 5));
      expect(ConnectionSupervisor.backoffFor(2), const Duration(seconds: 10));
      expect(ConnectionSupervisor.backoffFor(3), const Duration(seconds: 20));
      expect(ConnectionSupervisor.backoffFor(4), const Duration(seconds: 40));
      expect(ConnectionSupervisor.backoffFor(5), const Duration(seconds: 60));
      expect(ConnectionSupervisor.backoffFor(9), const Duration(seconds: 60));
    });
  });

  group('ConnectionSupervisor.superviseOnce', () {
    test('reconnects offline peers and skips online ones', () async {
      final calls = <String>[];
      final online = {'a'};
      final sup = ConnectionSupervisor.forTest(
        isOnline: (id) => online.contains(id),
        reconnect: (p) async => calls.add(p.id),
        loadPeers: () async => [_peer('a'), _peer('b'), _peer('c')],
      );

      await sup.superviseOnce(DateTime(2026, 1, 1, 0, 0, 0));
      expect(calls, equals(['b', 'c']));
    });

    test('respects the backoff window before retrying', () async {
      final calls = <String>[];
      final sup = ConnectionSupervisor.forTest(
        isOnline: (_) => false,
        reconnect: (p) async => calls.add(p.id),
        loadPeers: () async => [_peer('b')],
      );

      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      await sup.superviseOnce(t0); // attempt 1 -> reconnect, next at +5s
      await sup.superviseOnce(t0.add(const Duration(seconds: 3))); // within window
      expect(calls, equals(['b']), reason: 'should not retry inside backoff');

      await sup.superviseOnce(t0.add(const Duration(seconds: 6))); // window passed
      expect(calls, equals(['b', 'b']));
      expect(sup.backoffAttempts('b'), equals(2));
    });

    test('overlapping sweeps do not double-fire reconnects', () async {
      final calls = <String>[];
      final gate = Completer<void>();
      final sup = ConnectionSupervisor.forTest(
        isOnline: (_) => false,
        reconnect: (p) async {
          calls.add(p.id);
          await gate.future; // hold the first sweep open
        },
        loadPeers: () async => [_peer('b')],
      );

      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      final first = sup.superviseOnce(t0);
      // A pool event / timer tick arriving mid-sweep must be a no-op, even
      // with a timestamp past the backoff window.
      final second = sup.superviseOnce(t0.add(const Duration(seconds: 30)));
      await second;
      expect(calls, equals(['b']), reason: 'second sweep should be skipped');

      gate.complete();
      await first;
      expect(calls, equals(['b']));
    });

    test('resets backoff once a peer is healthy again', () async {
      var bOnline = false;
      final sup = ConnectionSupervisor.forTest(
        isOnline: (id) => id == 'b' ? bOnline : false,
        reconnect: (_) async {},
        loadPeers: () async => [_peer('b')],
      );

      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      await sup.superviseOnce(t0);
      expect(sup.backoffAttempts('b'), equals(1));

      bOnline = true;
      await sup.superviseOnce(t0.add(const Duration(seconds: 30)));
      expect(sup.backoffAttempts('b'), equals(0));
    });
  });
}
