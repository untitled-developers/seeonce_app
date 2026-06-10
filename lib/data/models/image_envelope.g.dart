// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'image_envelope.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ImageEnvelope _$ImageEnvelopeFromJson(Map<String, dynamic> json) =>
    ImageEnvelope(
      messageId: json['messageId'] as String,
      senderId: json['senderId'] as String,
      type: json['type'] as String,
      encryptedKey: json['encryptedKey'] as String,
      iv: json['iv'] as String,
      ciphertext: json['ciphertext'] as String,
      mimeType: json['mimeType'] as String,
      originalWidth: (json['originalWidth'] as num).toInt(),
      originalHeight: (json['originalHeight'] as num).toInt(),
      sentAt: json['sentAt'] as String,
    );

Map<String, dynamic> _$ImageEnvelopeToJson(ImageEnvelope instance) =>
    <String, dynamic>{
      'messageId': instance.messageId,
      'senderId': instance.senderId,
      'type': instance.type,
      'encryptedKey': instance.encryptedKey,
      'iv': instance.iv,
      'ciphertext': instance.ciphertext,
      'mimeType': instance.mimeType,
      'originalWidth': instance.originalWidth,
      'originalHeight': instance.originalHeight,
      'sentAt': instance.sentAt,
    };
