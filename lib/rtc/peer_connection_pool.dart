import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../core/diagnostic_log.dart';
import 'rtc_manager.dart';

class PeerConnectionPool {
  static final PeerConnectionPool instance = PeerConnectionPool._internal();
  PeerConnectionPool._internal();

  final Map<String, RTCPeerConnection> _connections = {};
  final Map<String, RTCDataChannel> _channels = {};

  final _changeController = StreamController<void>.broadcast();

  /// Fires whenever any peer's connection state changes (connect or disconnect).
  Stream<void> get onConnectionChange => _changeController.stream;

  void register(String peerId, RTCPeerConnection pc, RTCDataChannel dc) {
    // Re-pairing or a LAN reconnect can hand us a fresh connection for a peer we
    // already track. Tear the old one down first so we don't leak it or leave a
    // stale half-open pc that the UI keeps treating as live (which previously
    // forced a data wipe before re-pairing would take).
    final oldPc = _connections[peerId];
    final oldDc = _channels[peerId];
    if (oldPc != null && !identical(oldPc, pc)) {
      final staleDc = (oldDc != null && !identical(oldDc, dc)) ? oldDc : null;
      unawaited(_closeQuietly(staleDc, oldPc));
    }

    _connections[peerId] = pc;
    _channels[peerId] = dc;
    DiagnosticLog.instance.add('Pool', 'Registered connection for $peerId');

    // The missing piece: watch the live link so a drop actually updates the pool
    // and notifies listeners (peer list, open conversation, supervisor). Without
    // this the pool kept reporting a dead peer as connected until app restart,
    // and the supervisor's reconnect attempts left the dead pc registered.
    pc.onConnectionState = (state) {
      final stillCurrent = identical(_connections[peerId], pc);
      DiagnosticLog.instance.add('Pool',
          'Connection state for $peerId → ${state.name}'
          '${stillCurrent ? '' : ' (stale pc)'}');
      if (stillCurrent &&
          (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
              state == RTCPeerConnectionState.RTCPeerConnectionStateClosed)) {
        _connections.remove(peerId);
        _channels.remove(peerId);
        DiagnosticLog.instance
            .add('Pool', 'Dropped dead connection for $peerId');
        unawaited(_closeQuietly(dc, pc));
      }
      // Notify on every transition (incl. transient `disconnected`) so isOnline
      // re-reads reflect reality immediately; a recovery flips it back.
      _changeController.add(null);
    };

    _changeController.add(null);
  }

  Future<void> _closeQuietly(RTCDataChannel? dc, RTCPeerConnection? pc) async {
    if (dc != null) {
      try {
        await dc.close();
      } catch (_) {}
    }
    if (pc != null) {
      try {
        await RtcManager.instance.closePeerConnection(pc);
      } catch (_) {}
    }
  }

  RTCPeerConnection? getConnection(String peerId) => _connections[peerId];
  RTCDataChannel? getChannel(String peerId) => _channels[peerId];

  /// Peer ids that currently have a registered data channel. The global message
  /// router uses this to (re)attach its handler whenever channels change.
  Iterable<String> get peerIdsWithChannel => _channels.keys.toList();
  
  bool isOnline(String peerId) {
    final pc = _connections[peerId];
    return pc != null && pc.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
  }

  Future<void> remove(String peerId) async {
    final pc = _connections.remove(peerId);
    final dc = _channels.remove(peerId);
    if (pc != null || dc != null) {
      DiagnosticLog.instance.add('Pool', 'Removed connection for $peerId');
    }
    
    if (dc != null) {
      await dc.close();
    }
    if (pc != null) {
      await RtcManager.instance.closePeerConnection(pc);
    }
    _changeController.add(null);
  }

  Future<void> closeAll() async {
    for (final peerId in _connections.keys.toList()) {
      await remove(peerId);
    }
  }
}
