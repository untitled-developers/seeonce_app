import 'dart:async';
import 'package:flutter/foundation.dart';
import '../data/models/peer.dart';
import '../data/repositories/peer_repository.dart';
import 'local_reconnect_service.dart';
import 'peer_connection_pool.dart';

class _Backoff {
  final int attempt;
  final DateTime nextAttempt;
  const _Backoff(this.attempt, this.nextAttempt);
}

/// Keeps connections to all paired peers healthy: on each tick it reconnects
/// any peer that is currently offline, with per-peer exponential backoff so a
/// genuinely unreachable peer is not hammered.
///
/// Per-packet keepalive on a *live* connection is handled by WebRTC itself
/// (ICE consent freshness, RFC 7675, ~every 5s), which flips a vanished peer's
/// connection state to disconnected/failed within seconds. This supervisor is
/// the layer that notices that and re-establishes the link. On Android it keeps
/// running in the background via the foreground service; on iOS it runs while
/// the app is foregrounded and sweeps again on resume.
class ConnectionSupervisor {
  static final ConnectionSupervisor instance = ConnectionSupervisor._(
    isOnline: (id) => PeerConnectionPool.instance.isOnline(id),
    reconnect: (p) => LocalReconnectService.instance.reconnectPeer(p),
  );

  ConnectionSupervisor._({
    required bool Function(String) isOnline,
    required Future<void> Function(Peer) reconnect,
    Duration tickInterval = const Duration(seconds: 10),
  })  : _isOnline = isOnline,
        _reconnect = reconnect,
        _tickInterval = tickInterval;

  /// Test seam: build a supervisor with fully injected dependencies so the
  /// reconnect logic can be exercised without WebRTC or Hive.
  @visibleForTesting
  factory ConnectionSupervisor.forTest({
    required bool Function(String) isOnline,
    required Future<void> Function(Peer) reconnect,
    required Future<List<Peer>> Function() loadPeers,
  }) {
    final s = ConnectionSupervisor._(isOnline: isOnline, reconnect: reconnect);
    s._loadPeersOverride = loadPeers;
    return s;
  }

  final bool Function(String) _isOnline;
  final Future<void> Function(Peer) _reconnect;
  final Duration _tickInterval;

  PeerRepository? _repo;
  Future<List<Peer>> Function()? _loadPeersOverride;
  Timer? _timer;
  final Map<String, _Backoff> _backoff = {};
  bool _running = false;

  void start({required PeerRepository peerRepository}) {
    if (_running) return;
    _running = true;
    _repo = peerRepository;
    _timer = Timer.periodic(_tickInterval, (_) => superviseOnce(DateTime.now()));
    superviseOnce(DateTime.now()); // kick immediately
  }

  /// Force an immediate reconnect sweep (e.g. on app resume), clearing backoff
  /// so offline peers are retried at once instead of waiting out their window.
  void resumeNow() {
    _backoff.clear();
    if (_running) superviseOnce(DateTime.now());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    _backoff.clear();
  }

  /// One supervision pass. Reconnects every offline peer whose backoff window
  /// has elapsed; resets backoff for peers that are healthy. Public for tests.
  @visibleForTesting
  Future<void> superviseOnce(DateTime now) async {
    final peers = await (_loadPeersOverride?.call() ??
        _repo?.getAllPeers() ??
        Future.value(<Peer>[]));
    for (final p in peers) {
      if (_isOnline(p.id)) {
        _backoff.remove(p.id); // healthy — reset
        continue;
      }
      final b = _backoff[p.id];
      if (b != null && now.isBefore(b.nextAttempt)) continue; // within backoff
      final attempt = (b?.attempt ?? 0) + 1;
      _backoff[p.id] = _Backoff(attempt, now.add(backoffFor(attempt)));
      try {
        await _reconnect(p);
      } catch (e) {
        if (kDebugMode) debugPrint('[Supervisor] reconnect ${p.id} failed: $e');
      }
    }
  }

  /// Exponential backoff: 5s, 10s, 20s, 40s, capped at 60s.
  static Duration backoffFor(int attempt) {
    final base = 5 * (1 << (attempt - 1).clamp(0, 5));
    return Duration(seconds: base.clamp(5, 60));
  }

  @visibleForTesting
  int backoffAttempts(String peerId) => _backoff[peerId]?.attempt ?? 0;
}
