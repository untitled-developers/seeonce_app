import 'dart:typed_data';

/// A decrypted view-once video held in memory only. Mirrors ImageMessage:
/// removed (and zero-filled) after a single view.
class VideoMessage {
  final String messageId;
  final String senderId;
  final Uint8List videoBytes;
  final DateTime receivedAt;
  final int durationMs;
  bool isViewed;

  VideoMessage({
    required this.messageId,
    required this.senderId,
    required this.videoBytes,
    required this.receivedAt,
    this.durationMs = 0,
    this.isViewed = false,
  });
}
