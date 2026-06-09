import '../../core/constants.dart';

/// On-the-wire form of an encrypted view-once video. Like [TextEnvelope] /
/// ImageEnvelope, the payload is hybrid-encrypted (RSA-OAEP wrapping an
/// AES-256-GCM key); only the base64 ciphertext travels.
class VideoEnvelope {
  final String messageId;
  final String senderId;
  final String type;
  final String encryptedKey;
  final String iv;
  final String ciphertext;
  final String mimeType;
  final int durationMs;
  final String sentAt;

  VideoEnvelope({
    required this.messageId,
    required this.senderId,
    required this.encryptedKey,
    required this.iv,
    required this.ciphertext,
    required this.durationMs,
    required this.sentAt,
    this.mimeType = 'video/mp4',
    this.type = AppConstants.msgTypeVideo,
  });

  factory VideoEnvelope.fromJson(Map<String, dynamic> json) => VideoEnvelope(
        messageId: json['messageId'] as String,
        senderId: json['senderId'] as String,
        type: json['type'] as String? ?? AppConstants.msgTypeVideo,
        encryptedKey: json['encryptedKey'] as String,
        iv: json['iv'] as String,
        ciphertext: json['ciphertext'] as String,
        mimeType: json['mimeType'] as String? ?? 'video/mp4',
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        sentAt: json['sentAt'] as String,
      );

  Map<String, dynamic> toJson() => {
        'messageId': messageId,
        'senderId': senderId,
        'type': type,
        'encryptedKey': encryptedKey,
        'iv': iv,
        'ciphertext': ciphertext,
        'mimeType': mimeType,
        'durationMs': durationMs,
        'sentAt': sentAt,
      };
}
