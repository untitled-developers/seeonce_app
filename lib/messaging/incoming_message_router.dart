import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCDataChannel;

import '../core/constants.dart';
import '../crypto/hybrid_cipher.dart';
import '../crypto/key_store.dart';
import '../data/models/image_envelope.dart';
import '../data/models/image_message.dart';
import '../data/models/text_envelope.dart';
import '../data/models/text_message.dart';
import '../data/models/video_envelope.dart';
import '../data/models/video_message.dart';
import '../data/repositories/settings_repository.dart';
import '../features/conversation/providers/conversation_provider.dart';
import '../features/peers/providers/peers_provider.dart';
import '../notifications/notification_service.dart';
import '../rtc/peer_connection_pool.dart';
import '../rtc/rtc_channel_handler.dart';

enum _Kind { text, image, video }

/// Lets screens tell the router when they become visible / hidden so it knows
/// which conversation is on screen (notifications are suppressed for it).
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

/// Single, app-wide receiver for incoming peer messages.
///
/// It owns `onMessage` for every registered data channel, decrypts/parses
/// payloads, feeds them into [conversationProvider], and raises notifications —
/// but only for peers whose chat is not currently on screen. This is what lets
/// messages arrive (and notify) regardless of which screen is open, instead of
/// only while one specific conversation is foregrounded.
class IncomingMessageRouter {
  static final IncomingMessageRouter instance = IncomingMessageRouter._();
  IncomingMessageRouter._();

  WidgetRef? _ref;

  // Per-peer handler + payload subscription, plus the dc instance we wired (so
  // a reconnect that swaps the channel triggers a clean re-wire).
  final Map<String, RtcChannelHandler> _handlers = {};
  final Map<String, StreamSubscription<Uint8List>> _subs = {};
  final Map<String, RTCDataChannel> _wired = {};

  /// peerId of the conversation currently on screen, if any. Notifications for
  /// this peer are suppressed (you're already looking at the chat).
  String? _activeChatPeerId;
  String? get activeChatPeerId => _activeChatPeerId;

  void start(WidgetRef ref) {
    _ref = ref;
    PeerConnectionPool.instance.onConnectionChange.listen((_) => _sync());
    _sync();
  }

  /// Marks (or clears) which peer's chat is on screen. Opening a chat also
  /// clears that peer's outstanding notifications.
  void setActiveChat(String? peerId) {
    _activeChatPeerId = peerId;
    if (peerId != null) {
      unawaited(NotificationService.instance.cancelForPeer(peerId));
    }
  }

  /// (Re)attach our handler to every live channel; drop handlers for channels
  /// that went away or were replaced by a reconnect.
  void _sync() {
    final pool = PeerConnectionPool.instance;

    // Drop handlers for peers whose channel is gone.
    for (final peerId in _wired.keys.toList()) {
      if (pool.getChannel(peerId) == null) _teardown(peerId);
    }

    // Attach / re-attach for current channels.
    for (final peerId in pool.peerIdsWithChannel) {
      final dc = pool.getChannel(peerId);
      if (dc == null) continue;
      if (identical(_wired[peerId], dc)) continue; // already wired to this dc
      _teardown(peerId); // replace a stale handler if the dc was swapped
      final handler = RtcChannelHandler();
      _handlers[peerId] = handler;
      _wired[peerId] = dc;
      dc.onMessage = handler.onMessage;
      _subs[peerId] =
          handler.incomingPayloads.listen((p) => _handlePayload(peerId, p));
    }
  }

  void _teardown(String peerId) {
    _subs.remove(peerId)?.cancel();
    _handlers.remove(peerId)?.dispose();
    _wired.remove(peerId);
  }

  Future<void> _handlePayload(String peerId, Uint8List payload) async {
    final WidgetRef? ref = _ref;
    if (ref == null) return;
    try {
      final jsonMap = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      final type = jsonMap['type'];
      final convo = ref.read(conversationProvider.notifier);

      if (type == AppConstants.msgTypeUnpair) {
        // Tear down by the channel's local peer id (how we key this peer in the
        // pool/repo), not the remote-supplied id which need not match ours.
        await convo.onUnpairReceived(peerId);
        return;
      }

      if (type == AppConstants.msgTypeText) {
        final env = TextEnvelope.fromJson(jsonMap);
        final priv = await KeyStore.instance.getOwnPrivateKey();
        final decrypted = await HybridCipher.decrypt(
          priv,
          base64Decode(env.encryptedKey),
          base64Decode(env.iv),
          base64Decode(env.ciphertext),
        );
        convo.onTextReceived(
          peerId,
          TextMessage(
            messageId: env.messageId,
            senderId: env.senderId,
            text: utf8.decode(decrypted),
            // Stamp our own receive time so ordering is consistent across
            // devices regardless of clock skew.
            localAt: DateTime.now(),
            isMine: false,
          ),
        );
        await _notify(ref, peerId, env.messageId, _Kind.text);
        return;
      }

      if (type == AppConstants.msgTypeVideo) {
        final env = VideoEnvelope.fromJson(jsonMap);
        final priv = await KeyStore.instance.getOwnPrivateKey();
        final ct = base64Decode(env.ciphertext);
        final decrypted = await HybridCipher.decrypt(
          priv, base64Decode(env.encryptedKey), base64Decode(env.iv), ct);
        ct.fillRange(0, ct.length, 0);
        convo.onVideoReceived(
          peerId,
          VideoMessage(
            messageId: env.messageId,
            senderId: env.senderId,
            videoBytes: Uint8List.fromList(decrypted),
            receivedAt: DateTime.now(),
            durationMs: env.durationMs,
          ),
        );
        await _notify(ref, peerId, env.messageId, _Kind.video);
        return;
      }

      if (type != AppConstants.msgTypeImage) return;
      final env = ImageEnvelope.fromJson(jsonMap);
      final ct = base64Decode(env.ciphertext);
      final priv = await KeyStore.instance.getOwnPrivateKey();
      final decrypted = await HybridCipher.decrypt(
        priv, base64Decode(env.encryptedKey), base64Decode(env.iv), ct);
      ct.fillRange(0, ct.length, 0); // zero-fill ciphertext once decrypted
      convo.onImageReceived(
        peerId,
        ImageMessage(
          messageId: env.messageId,
          senderId: env.senderId,
          imageBytes: Uint8List.fromList(decrypted),
          receivedAt: DateTime.now(),
        ),
      );
      await _notify(ref, peerId, env.messageId, _Kind.image);
    } catch (e) {
      if (kDebugMode) debugPrint('[MessageRouter] payload error: $e');
    }
  }

  Future<void> _notify(
      WidgetRef ref, String peerId, String messageId, _Kind kind) async {
    // Suppress while the user is already looking at this peer's chat.
    if (_activeChatPeerId == peerId) return;
    final settings = await SettingsRepository().getSettings();
    if (!settings.notificationsEnabled) return;
    final name =
        (await ref.read(peerRepositoryProvider).getPeerById(peerId))
                ?.displayName ??
            'Someone';
    final svc = NotificationService.instance;
    switch (kind) {
      case _Kind.text:
        await svc.showTextReceivedNotification(
            senderName: name, messageId: messageId, peerId: peerId);
        break;
      case _Kind.image:
        await svc.showImageReceivedNotification(
            senderName: name, messageId: messageId, peerId: peerId);
        break;
      case _Kind.video:
        await svc.showVideoReceivedNotification(
            senderName: name, messageId: messageId, peerId: peerId);
        break;
    }
  }
}
