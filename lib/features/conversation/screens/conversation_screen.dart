import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCDataChannelMessage;
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../../core/constants.dart';
import '../../../core/errors.dart';
import '../../../data/models/image_message.dart';
import '../../../data/models/peer.dart';
import '../../../data/models/text_message.dart';
import '../../../data/models/video_message.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../../image_pipeline/image_sender.dart';
import '../../../image_pipeline/video_sender.dart';
import '../../../messaging/incoming_message_router.dart';
import '../../../messaging/message_sender.dart';
import '../../../rtc/local_reconnect_service.dart';
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
    with WidgetsBindingObserver, RouteAware {
  final _imagePicker = ImagePicker();
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  // Send-only channel handler; incoming messages are owned by the global
  // IncomingMessageRouter so they arrive whether or not this screen is open.
  RtcChannelHandler? _channelHandler;
  Peer? _peer;
  bool _isSending = false;
  bool _initialScrollDone = false;
  bool _leaving = false;
  StreamSubscription<void>? _connSub;
  StreamSubscription<void>? _activitySub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Expire stale messages on chat open (a reliable trigger beyond the timer).
    ref.read(conversationProvider.notifier).sweepExpired();
    // This chat is now on screen: suppress its notifications and clear any
    // already showing for this peer.
    IncomingMessageRouter.instance.setActiveChat(widget.peerId);
    _loadPeer();
    // Refresh online status when the connection comes up or drops.
    _connSub = PeerConnectionPool.instance.onConnectionChange.listen((_) {
      _loadPeer();
    });
    // Rebuild the header/banner when a reconnect attempt starts or ends.
    _activitySub =
        LocalReconnectService.instance.onReconnectActivity.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of<void>(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  // RouteAware: keep the router's "active chat" in sync with visibility so a
  // chat hidden behind another route (or the image/video viewer) still notifies.
  @override
  void didPush() => IncomingMessageRouter.instance.setActiveChat(widget.peerId);
  @override
  void didPopNext() =>
      IncomingMessageRouter.instance.setActiveChat(widget.peerId);
  @override
  void didPushNext() => IncomingMessageRouter.instance.setActiveChat(null);
  @override
  void didPop() => IncomingMessageRouter.instance.setActiveChat(null);

  @override
  void didChangeMetrics() {
    // Fires when the keyboard opens/closes (viewInsets change); keep the latest
    // message visible above the keyboard.
    _scrollToBottom();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounding means you're no longer looking at the chat, so release the
    // active marker (incoming messages should notify); re-claim it on resume.
    if (state == AppLifecycleState.resumed) {
      IncomingMessageRouter.instance.setActiveChat(widget.peerId);
    } else if (state == AppLifecycleState.paused &&
        IncomingMessageRouter.instance.activeChatPeerId == widget.peerId) {
      IncomingMessageRouter.instance.setActiveChat(null);
    }
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
    routeObserver.unsubscribe(this);
    if (IncomingMessageRouter.instance.activeChatPeerId == widget.peerId) {
      IncomingMessageRouter.instance.setActiveChat(null);
    }
    _scrollController.dispose();
    _connSub?.cancel();
    _activitySub?.cancel();
    _channelHandler?.dispose();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadPeer() async {
    final repo = ref.read(peerRepositoryProvider);
    final peer = await repo.getPeerById(widget.peerId);
    if (!mounted) return;
    setState(() => _peer = peer);
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

    // Leave the chat if the peer was removed remotely (unpaired by them) while
    // it is open. The router does the teardown; we just exit the dead screen.
    ref.listen(peersProvider, (prev, next) {
      next.whenData((peers) {
        if (_leaving || !mounted) return;
        if (!peers.any((p) => p.id == widget.peerId)) {
          _leaving = true;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                "Peer '${_peer?.displayName ?? 'peer'}' is no longer paired."),
          ));
          context.pop();
        }
      });
    });

    if (_peer == null) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }

    final isOnline = PeerConnectionPool.instance.isOnline(widget.peerId);
    final isReconnecting = !isOnline &&
        LocalReconnectService.instance.isReconnecting(widget.peerId);
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
                color: isOnline
                    ? Colors.green
                    : (isReconnecting ? Colors.orange : Colors.grey),
                size: 10),
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
              child: isReconnecting
                  ? Row(
                      children: const [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.orange),
                        ),
                        SizedBox(width: 10),
                        Text('Reconnecting…',
                            style: TextStyle(color: Colors.orange)),
                      ],
                    )
                  : Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Peer is offline.',
                            style: TextStyle(color: Colors.orange),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => LocalReconnectService.instance
                              .reconnectPeer(_peer!),
                          icon: const Icon(Icons.wifi_protected_setup,
                              size: 18, color: Colors.orange),
                          label: const Text('Reconnect',
                              style: TextStyle(color: Colors.orange)),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
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
                style: const TextStyle(
                    color: Color(0xFFF1F1F7),
                    fontFamilyFallback: ['NotoColorEmoji'])),
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
