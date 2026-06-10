/// The minimal signalling payload exchanged between two devices during pairing.
///
/// Contains ONLY what WebRTC needs (SDP + ICE candidates) plus identity info.
/// Encryption keys are NOT included here — they are exchanged automatically
/// over the DTLS-secured WebRTC data channel after connection is established.
///
/// Short JSON keys keep the QR code payload as compact as possible:
///   s   → step           ("offer" | "answer")
///   id  → peerId
///   n   → displayName
///   sdp → sdp
///   ic  → iceCandidates
class PairingPayload {
  final String step;
  final String peerId;
  final String displayName;
  final String sdp;
  final List<String> iceCandidates;

  PairingPayload({
    required this.step,
    required this.peerId,
    required this.displayName,
    required this.sdp,
    required this.iceCandidates,
  });

  factory PairingPayload.fromJson(Map<String, dynamic> json) => PairingPayload(
        step: (json['s'] ?? json['step']) as String,
        peerId: (json['id'] ?? json['peerId']) as String,
        displayName: (json['n'] ?? json['displayName']) as String,
        sdp: json['sdp'] as String,
        iceCandidates: ((json['ic'] ?? json['iceCandidates']) as List?)
                ?.map((e) => e as String)
                .toList() ??
            [],
      );

  Map<String, dynamic> toJson() => {
        's': step,
        'id': peerId,
        'n': displayName,
        'sdp': sdp,
        'ic': iceCandidates,
      };
}
