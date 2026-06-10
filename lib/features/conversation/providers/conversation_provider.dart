import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../peers/providers/peers_provider.dart';
import '../../../core/constants.dart';
import '../../../data/models/image_message.dart';
import '../../../data/models/text_message.dart';
import '../../../data/models/video_message.dart';
import '../../../rtc/peer_connection_pool.dart';

class ConversationState {
  /// See-once image messages awaiting view, per peer.
  final Map<String, List<ImageMessage>> pendingByPeer;

  /// See-once video messages awaiting view, per peer.
  final Map<String, List<VideoMessage>> pendingVideosByPeer;

  /// Text messages per peer. Held in memory only and pruned after
  /// [AppConstants.messageTtl].
  final Map<String, List<TextMessage>> messagesByPeer;

  ConversationState({
    required this.pendingByPeer,
    required this.pendingVideosByPeer,
    required this.messagesByPeer,
  });

  ConversationState copyWith({
    Map<String, List<ImageMessage>>? pendingByPeer,
    Map<String, List<VideoMessage>>? pendingVideosByPeer,
    Map<String, List<TextMessage>>? messagesByPeer,
  }) {
    return ConversationState(
      pendingByPeer: pendingByPeer ?? this.pendingByPeer,
      pendingVideosByPeer: pendingVideosByPeer ?? this.pendingVideosByPeer,
      messagesByPeer: messagesByPeer ?? this.messagesByPeer,
    );
  }
}

class ConversationNotifier extends StateNotifier<ConversationState> {
  final Ref ref;

  /// How long a text message survives, and how often we sweep. Injectable so
  /// tests can use short values.
  final Duration _ttl;
  Timer? _sweepTimer;

  ConversationNotifier(
    this.ref, {
    Duration ttl = AppConstants.messageTtl,
    Duration sweepInterval = AppConstants.messageSweepInterval,
  })  : _ttl = ttl,
        super(ConversationState(
            pendingByPeer: {}, pendingVideosByPeer: {}, messagesByPeer: {})) {
    _sweepTimer = Timer.periodic(sweepInterval, (_) => sweepExpired());
  }

  // ── Images (see-once) ──────────────────────────────────────────────────────

  void onImageReceived(String peerId, ImageMessage msg) {
    final current = Map<String, List<ImageMessage>>.from(state.pendingByPeer);
    final list = List<ImageMessage>.from(current[peerId] ?? []);
    list.add(msg);
    current[peerId] = list;
    state = state.copyWith(pendingByPeer: current);
  }

  void markAsViewed(String peerId, String messageId) {
    final current = Map<String, List<ImageMessage>>.from(state.pendingByPeer);
    final list = List<ImageMessage>.from(current[peerId] ?? []);

    final index = list.indexWhere((m) => m.messageId == messageId);
    if (index != -1) {
      final msg = list[index];
      msg.isViewed = true;
      msg.imageBytes.fillRange(0, msg.imageBytes.length, 0); // Zero fill
      list.removeAt(index);
    }

    current[peerId] = list;
    state = state.copyWith(pendingByPeer: current);
  }

  // ── Videos (see-once) ───────────────────────────────────────────────────────

  void onVideoReceived(String peerId, VideoMessage msg) {
    final current =
        Map<String, List<VideoMessage>>.from(state.pendingVideosByPeer);
    final list = List<VideoMessage>.from(current[peerId] ?? []);
    list.add(msg);
    current[peerId] = list;
    state = state.copyWith(pendingVideosByPeer: current);
  }

  void markVideoViewed(String peerId, String messageId) {
    final current =
        Map<String, List<VideoMessage>>.from(state.pendingVideosByPeer);
    final list = List<VideoMessage>.from(current[peerId] ?? []);

    final index = list.indexWhere((m) => m.messageId == messageId);
    if (index != -1) {
      final msg = list[index];
      msg.isViewed = true;
      msg.videoBytes.fillRange(0, msg.videoBytes.length, 0); // zero fill
      list.removeAt(index);
    }

    current[peerId] = list;
    state = state.copyWith(pendingVideosByPeer: current);
  }

  // ── Text messages ───────────────────────────────────────────────────────────

  void onTextReceived(String peerId, TextMessage msg) {
    _addText(peerId, msg);
  }

  void addOutgoingText(String peerId, TextMessage msg) {
    _addText(peerId, msg);
  }

  void _addText(String peerId, TextMessage msg) {
    // Prune any now-expired messages on every send/receive (a reliable trigger
    // independent of the background timer), then drop this one if it is already
    // past its TTL on arrival.
    sweepExpired();
    if (msg.isExpired(DateTime.now(), _ttl)) return;
    final current = Map<String, List<TextMessage>>.from(state.messagesByPeer);
    final list = List<TextMessage>.from(current[peerId] ?? []);
    if (list.any((m) => m.messageId == msg.messageId)) return; // de-dupe
    list.add(msg);
    list.sort((a, b) => a.localAt.compareTo(b.localAt));
    current[peerId] = list;
    state = state.copyWith(messagesByPeer: current);
  }

  /// Removes every text message older than the TTL across all peers. Triggered
  /// on chat open, on every send/receive, and by the background timer. [now]
  /// defaults to the current local time.
  void sweepExpired([DateTime? now]) {
    final cutoff = (now ?? DateTime.now());
    var changed = false;
    final current = Map<String, List<TextMessage>>.from(state.messagesByPeer);
    for (final entry in current.entries.toList()) {
      final kept =
          entry.value.where((m) => !m.isExpired(cutoff, _ttl)).toList();
      if (kept.length != entry.value.length) {
        changed = true;
        current[entry.key] = kept;
      }
    }
    if (changed) state = state.copyWith(messagesByPeer: current);
  }

  // ── Unpair / teardown ────────────────────────────────────────────────────────

  Future<void> onUnpairReceived(String remotePeerId) async {
    // 1. Close connection
    await PeerConnectionPool.instance.remove(remotePeerId);

    // 2. Delete peer from repository
    final peerRepo = ref.read(peerRepositoryProvider);
    await peerRepo.deletePeer(remotePeerId);

    // 3. Clear messages (images + videos + text), zero-filling decrypted media
    // bytes on the way out — dropping the references alone would leave the
    // plaintext in memory until the GC happens to reclaim it.
    final pending = Map<String, List<ImageMessage>>.from(state.pendingByPeer);
    for (final m in pending.remove(remotePeerId) ?? const <ImageMessage>[]) {
      m.imageBytes.fillRange(0, m.imageBytes.length, 0);
    }
    final videos =
        Map<String, List<VideoMessage>>.from(state.pendingVideosByPeer);
    for (final m in videos.remove(remotePeerId) ?? const <VideoMessage>[]) {
      m.videoBytes.fillRange(0, m.videoBytes.length, 0);
    }
    final texts = Map<String, List<TextMessage>>.from(state.messagesByPeer);
    texts.remove(remotePeerId);
    state = state.copyWith(
        pendingByPeer: pending,
        pendingVideosByPeer: videos,
        messagesByPeer: texts);
  }

  @override
  void dispose() {
    _sweepTimer?.cancel();
    super.dispose();
  }
}

final conversationProvider =
    StateNotifierProvider<ConversationNotifier, ConversationState>((ref) {
  return ConversationNotifier(ref);
});
