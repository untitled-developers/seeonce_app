import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import '../../core/constants.dart';

class RtcManager {
  static final RtcManager instance = RtcManager._internal();
  RtcManager._internal();

  final Map<String, dynamic> _config = {
    'iceServers': [
      {'urls': AppConstants.stunServers}
    ],
    'sdpSemantics': 'unified-plan',
  };

  /// No STUN: gathering emits host candidates only and completes almost
  /// immediately instead of waiting out a STUN round-trip. Used for LAN
  /// reconnects, where the UDP-broadcast signalling already guarantees both
  /// peers share a network and srflx candidates add nothing but latency.
  final Map<String, dynamic> _lanOnlyConfig = {
    'iceServers': [],
    'sdpSemantics': 'unified-plan',
  };

  Future<webrtc.RTCPeerConnection> createPeerConnection(
      {bool lanOnly = false}) async {
    return await webrtc.createPeerConnection(
        lanOnly ? _lanOnlyConfig : _config, {});
  }

  Future<webrtc.RTCDataChannel> createDataChannel(webrtc.RTCPeerConnection pc) async {
    final dataChannelDict = webrtc.RTCDataChannelInit()
      ..ordered = true
      ..maxRetransmits = -1;
    return pc.createDataChannel(
        AppConstants.dataChannelLabel, dataChannelDict);
  }

  void attachListeners({
    required webrtc.RTCPeerConnection pc,
    required String peerId,
    required Function(webrtc.RTCDataChannel) onDataChannel,
    required Function(webrtc.RTCPeerConnectionState) onConnectionStateChange,
    required Function(webrtc.RTCIceCandidate?) onIceCandidate,
  }) {
    pc.onDataChannel = onDataChannel;
    pc.onConnectionState = onConnectionStateChange;
    pc.onIceCandidate = onIceCandidate;
  }

  Future<void> closePeerConnection(webrtc.RTCPeerConnection pc) async {
    await pc.close();
  }
}
