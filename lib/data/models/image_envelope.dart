import 'package:json_annotation/json_annotation.dart';

part 'image_envelope.g.dart';

@JsonSerializable()
class ImageEnvelope {
  final String messageId;
  final String senderId;
  final String type;
  final String encryptedKey;
  final String iv;
  final String ciphertext;
  final String mimeType;
  final int originalWidth;
  final int originalHeight;
  final String sentAt;

  ImageEnvelope({
    required this.messageId,
    required this.senderId,
    required this.type,
    required this.encryptedKey,
    required this.iv,
    required this.ciphertext,
    required this.mimeType,
    required this.originalWidth,
    required this.originalHeight,
    required this.sentAt,
  });

  factory ImageEnvelope.fromJson(Map<String, dynamic> json) => _$ImageEnvelopeFromJson(json);
  Map<String, dynamic> toJson() => _$ImageEnvelopeToJson(this);
}
