class AppConstants {
  static const String stunServer = 'stun:stun.l.google.com:19302';

  /// Fallback STUN servers: if the primary is unreachable (blocked port,
  /// regional outage) srflx candidates can still be gathered for pairing.
  static const List<String> stunServers = [
    stunServer,
    'stun:stun1.l.google.com:19302',
    'stun:stun2.l.google.com:19302',
  ];
  static const int dataChannelChunkSize = 16384; // 16 KB per chunk
  static const String dataChannelLabel = 'seeonce-data';
  static const String controlChannelLabel = 'seeonce-control';

  /// Hard upper bound on a single (encrypted) payload we will reassemble or
  /// send. Bounds memory use and rejects malicious/oversized chunk headers.
  /// The encrypted envelope is a little larger than the compressed image, so
  /// this sits comfortably above any realistic compressed photo.
  static const int maxPayloadBytes = 25 * 1024 * 1024; // 25 MB

  /// Derived cap on the number of chunks a header may declare. A peer claiming
  /// more than this is rejected before any buffer is allocated.
  static const int maxChunks = (maxPayloadBytes ~/ dataChannelChunkSize) + 2;

  /// Incomplete reassembly buffers older than this are swept to avoid a slow
  /// memory leak from peers that send a header but never finish.
  static const Duration chunkBufferTtl = Duration(seconds: 60);

  /// Upper bound on a single compressed image we will send. Kept well below
  /// [maxPayloadBytes] so the base64-encoded encrypted envelope (~1.33x the
  /// image plus crypto overhead) still fits inside the receiver's limit.
  static const int maxImageBytes = 12 * 1024 * 1024; // 12 MB

  // Message types
  static const String msgTypeImage = 'image';
  static const String msgTypeText = 'text';
  static const String msgTypeVideo = 'video';
  static const String msgTypeUnpair = 'unpair';
  static const String msgTypeAck = 'ack';

  /// Maximum length of a sent video. Capture is limited to this, and longer
  /// gallery videos are trimmed to it during compression.
  static const Duration maxVideoDuration = Duration(seconds: 10);

  /// Upper bound on a single compressed video, kept below [maxPayloadBytes] so
  /// the base64 encrypted envelope still fits the receiver's limit.
  static const int maxVideoBytes = 16 * 1024 * 1024; // 16 MB

  /// Text messages disappear from the chat this long after they were sent.
  /// Expiry is keyed off the sender's timestamp so both peers clear at the
  /// same wall-clock moment. Messages are held in memory only (never written
  /// to disk), so they also vanish if the app is closed.
  static const Duration messageTtl = Duration(minutes: 30);

  /// How often the conversation provider sweeps expired messages.
  static const Duration messageSweepInterval = Duration(seconds: 20);

  // Hive box names
  static const String peersBoxName = 'peers';
  static const String settingsBoxName = 'settings';
}
