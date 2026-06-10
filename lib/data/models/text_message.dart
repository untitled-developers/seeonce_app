/// A decrypted text message held in memory only. Disappears from the chat once
/// it is older than [AppConstants.messageTtl] (see [isExpired]).
class TextMessage {
  final String messageId;
  final String senderId;
  final String text;

  /// Local-clock timestamp: when this device created the message (outgoing) or
  /// received it (incoming). Used for ordering, display and expiry.
  ///
  /// We deliberately do NOT order/expire by the sender's timestamp: the two
  /// devices' clocks can differ by seconds, which interleaves messages out of
  /// order. Keying off a single device's own clock keeps the chat consistent.
  final DateTime localAt;

  /// True for messages this device sent (shown right-aligned), false for
  /// messages received from the peer.
  final bool isMine;

  TextMessage({
    required this.messageId,
    required this.senderId,
    required this.text,
    required this.localAt,
    required this.isMine,
  });

  /// Whether the message has lived past [ttl] relative to [now], measured from
  /// when it entered this device's chat.
  bool isExpired(DateTime now, Duration ttl) => now.isAfter(localAt.add(ttl));
}
