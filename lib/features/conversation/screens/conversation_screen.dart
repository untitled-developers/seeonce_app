import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCDataChannelMessage;
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../../core/constants.dart';
import '../../../core/errors.dart';
import '../../../crypto/hybrid_cipher.dart';
import '../../../crypto/key_store.dart';
import '../../../data/models/image_envelope.dart';
import '../../../data/models/image_message.dart';
import '../../../data/models/peer.dart';
import '../../../data/models/text_envelope.dart';
import '../../../data/models/text_message.dart';
import '../../../data/models/video_envelope.dart';
import '../../../data/models/video_message.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../../image_pipeline/image_sender.dart';
import '../../../image_pipeline/video_sender.dart';
import '../../../messaging/message_sender.dart';
import '../../../notifications/notification_service.dart';
import '../../../rtc/peer_connection_pool.dart';
import '../../../rtc/rtc_channel_handler.dart';
import '../../peers/providers/peers_provider.dart';
import '../providers/conversation_provider.dart';

class ConversationScreen extends ConsumerStatefulWidget {
  final String peerId;
  const ConversationScreen({super.key, required this.peerId});

  @override
  ConsumerState<ConversationScreen> createState() =>
      _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen>
    with WidgetsBindingObserver {
  final _imagePicker = ImagePicker();
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  RtcChannelHandler? _channelHandler;
  Peer? _peer;
  bool _isSending = false;
  bool _initialScrollDone = false;
  StreamSubscription<void>? _connSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Expire stale messages on chat open (a reliable trigger beyond the timer).
    ref.read(conversationProvider.notifier).sweepExpired();
    _loadPeerAndSetupChannel();
    // Re-attach message handler if peer reconnects while this screen is open
    _connSub = PeerConnectionPool.instance.onConnectionChange.listen((_) {
      _loadPeerAndSetupChannel();
    });
  }

  @override
  void didChangeMetrics() {
    // Fires when the keyboard opens/closes (viewInsets change); keep the latest
    // message visible above the keyboard.
    _scrollToBottom();
  }

  /// Scrolls to the newest message after the next frame (so the list has its
  /// final extent, e.g. after the keyboard resized it). [animate] is false for
  /// the initial positioning so the chat simply opens at the bottom.
  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (animate) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _connSub?.cancel();
    _channelHandler?.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadPeerAndSetupChannel() async {
    final repo = ref.read(peerRepositoryProvider);
    final peer = await repo.getPeerById(widget.peerId);
    if (!mounted) return;
    setState(() => _peer = peer);
    if (_peer == null) return;

    final dc = PeerConnectionPool.instance.getChannel(widget.peerId);
    if (dc == null) return;

    _channelHandler = RtcChannelHandler();
    dc.onMessage = _channelHandler!.onMessage;
    _channelHandler!.incomingPayloads.listen(_handleIncomingPayload);
  }

  Future<void> _handleIncomingPayload(Uint8List payload) async {
    try {
      final jsonString = utf8.decode(payload);
      final jsonMap = jsonDecode(jsonString) as Map<String, dynamic>;

      // Handle unpair control message
      if (jsonMap['type'] == AppConstants.msgTypeUnpair) {
        final remotePeerId =
            (jsonMap['peerId'] as String?) ?? widget.peerId;
        if (mounted) {
          ref
              .read(conversationProvider.notifier)
              .onUnpairReceived(remotePeerId);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                "Peer '${_peer?.displayName ?? remotePeerId}' removed you."),
          ));
          context.pop();
        }
        return;
      }

      // Encrypted text message
      if (jsonMap['type'] == AppConstants.msgTypeText) {
        final envelope = TextEnvelope.fromJson(jsonMap);
        final privateKey = await KeyStore.instance.getOwnPrivateKey();
        final decrypted = await HybridCipher.decrypt(
          privateKey,
          base64Decode(envelope.encryptedKey),
          base64Decode(envelope.iv),
          base64Decode(envelope.ciphertext),
        );
        final text = utf8.decode(decrypted);
        if (mounted) {
          ref.read(conversationProvider.notifier).onTextReceived(
                widget.peerId,
                TextMessage(
                  messageId: envelope.messageId,
                  senderId: envelope.senderId,
                  text: text,
                  // Stamp our own receive time so ordering is consistent across
                  // devices regardless of clock skew.
                  localAt: DateTime.now(),
                  isMine: false,
                ),
              );

          final settings = await SettingsRepository().getSettings();
          if (settings.notificationsEnabled) {
            await NotificationService.instance.showTextReceivedNotification(
              senderName: _peer?.displayName ?? 'Someone',
              messageId: envelope.messageId,
              peerId: widget.peerId,
            );
          }
        }
        return;
      }

      // Encrypted view-once video
      if (jsonMap['type'] == AppConstants.msgTypeVideo) {
        final venv = VideoEnvelope.fromJson(jsonMap);
        final privateKey = await KeyStore.instance.getOwnPrivateKey();
        final ct = base64Decode(venv.ciphertext);
        final decrypted = await HybridCipher.decrypt(
          privateKey,
          base64Decode(venv.encryptedKey),
          base64Decode(venv.iv),
          ct,
        );
        ct.fillRange(0, ct.length, 0);
        if (mounted) {
          ref.read(conversationProvider.notifier).onVideoReceived(
                widget.peerId,
                VideoMessage(
                  messageId: venv.messageId,
                  senderId: venv.senderId,
                  videoBytes: Uint8List.fromList(decrypted),
                  receivedAt: DateTime.now(),
                  durationMs: venv.durationMs,
                ),
              );
          final settings = await SettingsRepository().getSettings();
          if (settings.notificationsEnabled) {
            await NotificationService.instance.showVideoReceivedNotification(
              senderName: _peer?.displayName ?? 'Someone',
              messageId: venv.messageId,
              peerId: widget.peerId,
            );
          }
        }
        return;
      }

      if (jsonMap['type'] != AppConstants.msgTypeImage) return;

      final envelope = ImageEnvelope.fromJson(jsonMap);

      final encryptedKeyBytes = base64Decode(envelope.encryptedKey);
      final ivBytes = base64Decode(envelope.iv);
      final ciphertextBytes = base64Decode(envelope.ciphertext);

      final privateKey = await KeyStore.instance.getOwnPrivateKey();
      final decryptedBytes = await HybridCipher.decrypt(
        privateKey,
        encryptedKeyBytes,
        ivBytes,
        ciphertextBytes,
      );

      // Zero-fill ciphertext bytes once decrypted
      ciphertextBytes.fillRange(0, ciphertextBytes.length, 0);

      final msg = ImageMessage(
        messageId: envelope.messageId,
        senderId: envelope.senderId,
        imageBytes: Uint8List.fromList(decryptedBytes),
        receivedAt: DateTime.now(),
      );

      if (mounted) {
        ref
            .read(conversationProvider.notifier)
            .onImageReceived(widget.peerId, msg);

        // Show notification (respects user setting)
        final settings = await SettingsRepository().getSettings();
        if (settings.notificationsEnabled) {
          await NotificationService.instance.showImageReceivedNotification(
            senderName: _peer?.displayName ?? 'Someone',
            messageId: msg.messageId,
            peerId: widget.peerId,
          );
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to process incoming payload: $e');
    }
  }

  Future<void> _pickAndSendImage(ImageSource source) async {
    if (_peer == null) return;
    final dc = PeerConnectionPool.instance.getChannel(widget.peerId);
    if (dc == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Not connected to peer.')));
      }
      return;
    }

    final xfile = await _imagePicker.pickImage(source: source);
    if (xfile == null) return;

    setState(() => _isSending = true);
    try {
      final settingsRepo = SettingsRepository();
      final appSettings = await settingsRepo.getSettings();

      _channelHandler ??= RtcChannelHandler();

      await ImageSender.instance.sendImage(
        filePath: xfile.path,
        recipient: _peer!,
        dataChannel: dc,
        compressionSettings: appSettings.compression,
        ownPeerId: const Uuid().v4(),
        channelHandler: _channelHandler!,
      );

      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Image sent!')));
      }
    } catch (e, stack) {
      if (kDebugMode) debugPrint('Failed to send image: $e\n$stack');
      if (mounted) {
        final reason = e is SeeOnceError ? e.message : 'Please try again.';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to send: $reason')));
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// Bottom sheet keeping the input row uncluttered: one "+" opens all the
  /// media options instead of a row of icons.
  void _showAttachMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take photo'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickAndSendImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo),
              title: const Text('Photo from gallery'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickAndSendImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('Record video (max 10s)'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickAndSendVideo(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.video_library),
              title: const Text('Video from gallery'),
              subtitle: const Text('Trimmed to 10 seconds'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickAndSendVideo(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndSendVideo(ImageSource source) async {
    if (_peer == null) return;
    final dc = PeerConnectionPool.instance.getChannel(widget.peerId);
    if (dc == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Not connected to peer.')));
      }
      return;
    }

    final xfile = await _imagePicker.pickVideo(
      source: source,
      maxDuration: AppConstants.maxVideoDuration,
    );
    if (xfile == null) return;

    setState(() => _isSending = true);
    try {
      _channelHandler ??= RtcChannelHandler();
      await VideoSender.instance.sendVideo(
        filePath: xfile.path,
        recipient: _peer!,
        dataChannel: dc,
        ownPeerId: const Uuid().v4(),
        channelHandler: _channelHandler!,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Video sent!')));
      }
    } catch (e, stack) {
      if (kDebugMode) debugPrint('Failed to send video: $e\n$stack');
      if (mounted) {
        final reason = e is SeeOnceError ? e.message : 'Please try again.';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to send: $reason')));
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _peer == null) return;
    final dc = PeerConnectionPool.instance.getChannel(widget.peerId);
    if (dc == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Not connected to peer.')));
      }
      return;
    }

    _channelHandler ??= RtcChannelHandler();
    _textController.clear();
    try {
      final msg = await MessageSender.instance.sendText(
        text: text,
        recipient: _peer!,
        dataChannel: dc,
        ownPeerId: const Uuid().v4(),
        channelHandler: _channelHandler!,
      );
      if (mounted) {
        ref
            .read(conversationProvider.notifier)
            .addOutgoingText(widget.peerId, msg);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to send message: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to send message.')));
      }
    }
  }

  Future<void> _unpair() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unpair'),
        content: Text(
            'Are you sure you want to unpair from ${_peer?.displayName}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Unpair',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    // Send unpair control message over the data channel
    final dc = PeerConnectionPool.instance.getChannel(widget.peerId);
    if (dc != null) {
      try {
        final msg = jsonEncode(
            {'type': AppConstants.msgTypeUnpair, 'peerId': widget.peerId});
        await dc.send(RTCDataChannelMessage(msg));
      } catch (_) {}
    }

    await PeerConnectionPool.instance.remove(widget.peerId);
    if (!mounted) return;
    final repo = ref.read(peerRepositoryProvider);
    await repo.deletePeer(widget.peerId);

    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    // Auto-scroll to the newest message whenever this peer's message count grows.
    ref.listen<ConversationState>(conversationProvider, (prev, next) {
      int count(ConversationState? s) =>
          (s?.messagesByPeer[widget.peerId]?.length ?? 0) +
          (s?.pendingByPeer[widget.peerId]?.length ?? 0) +
          (s?.pendingVideosByPeer[widget.peerId]?.length ?? 0);
      if (count(next) > count(prev)) _scrollToBottom();
    });

    if (_peer == null) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }

    final isOnline = PeerConnectionPool.instance.isOnline(widget.peerId);
    final convo = ref.watch(conversationProvider);
    final pendingMessages = convo.pendingByPeer[widget.peerId] ?? [];
    final pendingVideos = convo.pendingVideosByPeer[widget.peerId] ?? [];
    final textMessages = convo.messagesByPeer[widget.peerId] ?? [];
    final timeline =
        _buildTimeline(pendingMessages, pendingVideos, textMessages);

    // First time the list has content, jump straight to the bottom so the chat
    // opens at the newest message instead of the top.
    if (!_initialScrollDone && timeline.isNotEmpty) {
      _initialScrollDone = true;
      _scrollToBottom(animate: false);
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(_peer!.displayName),
            const SizedBox(width: 8),
            Icon(Icons.circle,
                color: isOnline ? Colors.green : Colors.grey, size: 10),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'unpair') _unpair();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'unpair', child: Text('Unpair')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (!isOnline)
            Container(
              width: double.infinity,
              color: Colors.orange.withAlpha(40),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: const Text(
                'Peer is offline — connect first to send messages.',
                style: TextStyle(color: Colors.orange),
              ),
            ),
          Container(
            width: double.infinity,
            color: const Color(0xFF7B61FF).withAlpha(25),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: const Text(
              'Messages are encrypted and disappear 30 minutes after they are sent.',
              style: TextStyle(color: Color(0xFF9B89FF), fontSize: 12),
            ),
          ),
          Expanded(
            child: timeline.isEmpty
                ? const Center(
                    child: Text('No messages yet.',
                        style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(8),
                    itemCount: timeline.length,
                    itemBuilder: (context, index) => timeline[index],
                  ),
          ),
          if (_isSending) const LinearProgressIndicator(),
          SafeArea(
            top: false,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              color: Theme.of(context).colorScheme.surface,
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Attach',
                    onPressed:
                        isOnline && !_isSending ? _showAttachMenu : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      enabled: isOnline,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: isOnline ? (_) => _sendText() : null,
                      decoration: const InputDecoration(
                        hintText: 'Message',
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Send',
                    onPressed: isOnline ? _sendText : null,
                    icon: const Icon(Icons.send, color: Color(0xFF7B61FF)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds a single time-ordered list of image tiles (see-once) and text
  /// bubbles. Oldest first, so the newest message sits at the bottom.
  List<Widget> _buildTimeline(List<ImageMessage> images,
      List<VideoMessage> videos, List<TextMessage> texts) {
    final entries = <(DateTime, Widget)>[];

    for (final msg in images) {
      if (msg.isViewed) continue;
      entries.add((msg.receivedAt, _imageTile(msg)));
    }
    for (final msg in videos) {
      if (msg.isViewed) continue;
      entries.add((msg.receivedAt, _videoTile(msg)));
    }
    for (final msg in texts) {
      entries.add((msg.localAt, _textBubble(msg)));
    }

    entries.sort((a, b) => a.$1.compareTo(b.$1));
    return entries.map((e) => e.$2).toList();
  }

  Widget _videoTile(VideoMessage msg) {
    final secs = (msg.durationMs / 1000).round();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.play_circle_fill, color: Color(0xFF7B61FF)),
        title: const Text('Tap to view video'),
        subtitle: Text(secs > 0 ? 'Video · ${secs}s · view once' : 'View once'),
        onTap: () {
          context.push(
            '/conversation/${widget.peerId}/view-video/${msg.messageId}',
            extra: msg,
          );
        },
      ),
    );
  }

  Widget _imageTile(ImageMessage msg) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.image, color: Color(0xFF7B61FF)),
        title: const Text('Tap to view image'),
        subtitle: Text(
          'Received ${msg.receivedAt.toLocal().toString().split('.')[0]}',
        ),
        onTap: () {
          context.push(
            '/conversation/${widget.peerId}/view-image/${msg.messageId}',
            extra: msg,
          );
        },
      ),
    );
  }

  Widget _textBubble(TextMessage msg) {
    final local = msg.localAt.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return Align(
      alignment: msg.isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: msg.isMine
              ? const Color(0xFF7B61FF)
              : const Color(0xFF12121A),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(msg.text,
                style: const TextStyle(color: Color(0xFFF1F1F7))),
            const SizedBox(height: 2),
            Text('$hh:$mm',
                style: const TextStyle(
                    color: Color(0xFF9090A0), fontSize: 10)),
          ],
        ),
      ),
    );
  }
}
