import '../../core/constants.dart';

/// The on-the-wire form of an encrypted text message. The plaintext is
/// hybrid-encrypted (RSA-OAEP wrapping an AES-256-GCM key); only the base64
/// ciphertext travels. Hand-written JSON (no codegen) to keep it simple.
class TextEnvelope {
  final String messageId;
  final String senderId;
  final String type;
  final String encryptedKey;
  final String iv;
  final String ciphertext;

  /// ISO-8601 UTC timestamp set by the sender; drives the 30-minute expiry.
  final String sentAt;

  TextEnvelope({
    required this.messageId,
    required this.senderId,
    required this.encryptedKey,
    required this.iv,
    required this.ciphertext,
    required this.sentAt,
    this.type = AppConstants.msgTypeText,
  });

  factory TextEnvelope.fromJson(Map<String, dynamic> json) => TextEnvelope(
        messageId: json['messageId'] as String,
        senderId: json['senderId'] as String,
        type: json['type'] as String? ?? AppConstants.msgTypeText,
        encryptedKey: json['encryptedKey'] as String,
        iv: json['iv'] as String,
        ciphertext: json['ciphertext'] as String,
        sentAt: json['sentAt'] as String,
      );

  Map<String, dynamic> toJson() => {
        'messageId': messageId,
        'senderId': senderId,
        'type': type,
        'encryptedKey': encryptedKey,
        'iv': iv,
        'ciphertext': ciphertext,
        'sentAt': sentAt,
      };
}
