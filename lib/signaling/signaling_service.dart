import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../data/models/pairing_payload.dart';
import 'pairing_code_service.dart';

/// Converts WebRTC signalling data to/from compact pairing codes.
///
/// Note: encryption keys are NOT part of the pairing code. They are exchanged
/// automatically over the DTLS-secured data channel after WebRTC connects.
class SignalingService {
  static final SignalingService instance = SignalingService._internal();
  SignalingService._internal();

  /// Encodes the SDP offer and gathered ICE candidates into a pairing code.
  /// The caller is responsible for having already called [pc.createOffer] and
  /// [pc.setLocalDescription] — this method does NOT call them again.
  String createOfferCode({
    required String ownPeerId,
    required String displayName,
    required String sdp,
    required List<RTCIceCandidate> bundledCandidates,
  }) {
    return PairingCodeService.instance.encode(PairingPayload(
      step: 'offer',
      peerId: ownPeerId,
      displayName: displayName,
      sdp: sdp,
      iceCandidates: bundledCandidates
          .map((c) => jsonEncode(c.toMap()))
          .toList(),
    ));
  }

  /// Encodes the SDP answer and gathered ICE candidates into a pairing code.
  String createAnswerCode({
    required String ownPeerId,
    required String displayName,
    required String sdp,
    required List<RTCIceCandidate> bundledCandidates,
  }) {
    return PairingCodeService.instance.encode(PairingPayload(
      step: 'answer',
      peerId: ownPeerId,
      displayName: displayName,
      sdp: sdp,
      iceCandidates: bundledCandidates
          .map((c) => jsonEncode(c.toMap()))
          .toList(),
    ));
  }

  /// Decodes any pairing code string into a [PairingPayload].
  PairingPayload decode(String code) => PairingCodeService.instance.decode(code);
}
