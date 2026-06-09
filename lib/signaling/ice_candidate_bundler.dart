import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Collects ICE candidates during gathering and completes when done.
///
/// Bundles **host** candidates (local network addresses, for same-Wi-Fi peers)
/// and **server-reflexive** (`srflx`) candidates discovered via STUN, which
/// carry the device's public address and allow two peers on *different*
/// networks to connect directly, provided neither is behind a symmetric /
/// carrier-grade NAT. Reliable cross-NAT/cellular connectivity additionally
/// needs a TURN relay, which is not configured here. Relay candidates are
/// included too, in case a TURN server is added later.
///
/// srflx candidates arrive only after a STUN round-trip, i.e. later than host
/// candidates, so gathering waits longer than a LAN-only gather would.
///
/// Completes on whichever comes first:
///   • the end-of-gathering signal (a `null` candidate),
///   • a short grace period after the first public (srflx/relay) candidate,
///   • the hard timeout, which covers STUN being unreachable (e.g. no
///     internet); we then fall back to host candidates only.
class IceCandidateBundler {
  final List<RTCIceCandidate> _candidates = [];
  final Completer<List<RTCIceCandidate>> _completer = Completer();

  Timer? _hardTimeout;
  Timer? _softTimeout;

  /// Backstop: complete with whatever we have by now. Long enough for a STUN
  /// round-trip, short enough not to stall pairing when STUN is unreachable.
  static const Duration _hardDeadline = Duration(seconds: 5);

  /// Once a publicly-routable candidate arrives we have what cross-network
  /// needs; wait briefly for extras (e.g. IPv4 + IPv6), then finish.
  static const Duration _softDeadline = Duration(milliseconds: 800);

  IceCandidateBundler() {
    _hardTimeout = Timer(_hardDeadline, _complete);
  }

  void onCandidate(RTCIceCandidate? candidate) {
    if (_completer.isCompleted) return;

    if (candidate == null) {
      // End-of-gathering signal.
      _complete();
      return;
    }

    final c = candidate.candidate ?? '';
    final isHost = c.contains('typ host');
    final isSrflx = c.contains('typ srflx');
    final isRelay = c.contains('typ relay');
    // Skip prflx / tcp duplicates and anything unrecognised.
    if (!isHost && !isSrflx && !isRelay) return;

    _candidates.add(candidate);

    // A public candidate is the valuable one for cross-network; give a short
    // grace window for additional candidates, then complete.
    if (isSrflx || isRelay) {
      _softTimeout ??= Timer(_softDeadline, _complete);
    }
  }

  void _complete() {
    _hardTimeout?.cancel();
    _softTimeout?.cancel();
    if (!_completer.isCompleted) {
      _completer.complete(List.unmodifiable(_candidates));
    }
  }

  Future<List<RTCIceCandidate>> get candidates => _completer.future;
}
