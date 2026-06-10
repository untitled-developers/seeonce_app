import 'dart:typed_data';

class ImageMessage {
  final String messageId;
  final String senderId;
  final Uint8List imageBytes;
  final DateTime receivedAt;
  bool isViewed;

  ImageMessage({
    required this.messageId,
    required this.senderId,
    required this.imageBytes,
    required this.receivedAt,
    this.isViewed = false,
  });
}
