import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
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
    _connections[peerId] = pc;
    _channels[peerId] = dc;
    _changeController.add(null);
  }

  RTCPeerConnection? getConnection(String peerId) => _connections[peerId];
  RTCDataChannel? getChannel(String peerId) => _channels[peerId];
  
  bool isOnline(String peerId) {
    final pc = _connections[peerId];
    return pc != null && pc.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
  }

  Future<void> remove(String peerId) async {
    final pc = _connections.remove(peerId);
    final dc = _channels.remove(peerId);
    
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
