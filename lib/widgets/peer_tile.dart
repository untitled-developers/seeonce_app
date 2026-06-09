import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCDataChannelMessage;
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../core/constants.dart';
import '../core/theme.dart';
import '../data/models/peer.dart';
import '../features/conversation/providers/conversation_provider.dart';
import '../rtc/local_reconnect_service.dart';
import '../rtc/peer_connection_pool.dart';

class PeerTile extends ConsumerStatefulWidget {
  final Peer peer;

  const PeerTile({super.key, required this.peer});

  @override
  ConsumerState<PeerTile> createState() => _PeerTileState();
}

class _PeerTileState extends ConsumerState<PeerTile> {
  StreamSubscription<void>? _connSub;
  StreamSubscription<void>? _activitySub;
  bool _isOnline = false;
  bool _isReconnecting = false;

  @override
  void initState() {
    super.initState();
    _syncStatus();
    // Connection up/down events from the pool…
    _connSub = PeerConnectionPool.instance.onConnectionChange.listen((_) {
      _syncStatus();
    });
    // …and the reconnect service's in-flight attempt signal.
    _activitySub =
        LocalReconnectService.instance.onReconnectActivity.listen((_) {
      _syncStatus();
    });
  }

  /// Pull the latest online / reconnecting status and rebuild only on a change.
  void _syncStatus() {
    final online = PeerConnectionPool.instance.isOnline(widget.peer.id);
    final reconnecting =
        !online && LocalReconnectService.instance.isReconnecting(widget.peer.id);
    if (mounted && (online != _isOnline || reconnecting != _isReconnecting)) {
      setState(() {
        _isOnline = online;
        _isReconnecting = reconnecting;
      });
    }
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _activitySub?.cancel();
    super.dispose();
  }

  Future<void> _connect() async {
    // The reconnect-activity stream drives the spinner; just kick the attempt.
    await LocalReconnectService.instance.reconnectPeer(widget.peer);
  }

  Color get _statusColor => _isOnline
      ? AppColors.online
      : (_isReconnecting ? AppColors.reconnecting : AppColors.offline);

  @override
  Widget build(BuildContext context) {
    final conversationState = ref.watch(conversationProvider);
    final pendingCount = conversationState.pendingByPeer[widget.peer.id]
            ?.where((m) => !m.isViewed)
            .length ??
        0;

    Widget? trailing;
    if (_isOnline) {
      if (pendingCount > 0) {
        trailing = _badge(pendingCount);
      }
    } else {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pendingCount > 0) ...[_badge(pendingCount), const SizedBox(width: 8)],
          if (_isReconnecting)
            const Tooltip(
              message: 'Reconnecting…',
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.reconnecting),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.wifi_protected_setup),
              tooltip: 'Connect',
              onPressed: _connect,
            ),
        ],
      );
    }

    return Dismissible(
      key: Key(widget.peer.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (direction) async {
        return await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Unpair'),
            content: Text('Are you sure you want to unpair from ${widget.peer.displayName}?'),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Unpair', style: TextStyle(color: Colors.red))),
            ],
          ),
        );
      },
      onDismissed: (direction) async {
        // Tell the peer we unpaired (parity with the in-conversation unpair),
        // so they don't keep a dead pairing forever. Must happen before the
        // local teardown closes the channel.
        final dc = PeerConnectionPool.instance.getChannel(widget.peer.id);
        if (dc != null) {
          try {
            await dc.send(RTCDataChannelMessage(jsonEncode({
              'type': AppConstants.msgTypeUnpair,
              'peerId': widget.peer.id,
            })));
          } catch (_) {}
        }
        await ref
            .read(conversationProvider.notifier)
            .onUnpairReceived(widget.peer.id);
      },
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      child: ListTile(
        leading: Stack(
          children: [
            CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Text(
                widget.peer.displayName.isNotEmpty
                    ? widget.peer.displayName[0].toUpperCase()
                    : '?',
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: _statusColor,
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      width: 2),
                ),
              ),
            ),
          ],
        ),
        title: Text(widget.peer.displayName),
        subtitle: Text(
          _isOnline
              ? 'Connected'
              : (_isReconnecting
                  ? 'Reconnecting…'
                  : 'Offline · Paired ${DateFormat.yMMMd().format(widget.peer.pairedAt.toLocal())}'),
          style: TextStyle(
            color: _isReconnecting ? AppColors.reconnecting : null,
          ),
        ),
        trailing: trailing,
        onTap: () => context.push('/conversation/${widget.peer.id}'),
      ),
    );
  }

  Widget _badge(int count) => Container(
        padding: const EdgeInsets.all(6),
        decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
        child: Text(count.toString(),
            style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold)),
      );
}
