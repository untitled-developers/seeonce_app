import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../data/models/video_message.dart';
import '../../../widgets/secure_video_widget.dart';
import '../providers/conversation_provider.dart';

class VideoViewerScreen extends ConsumerStatefulWidget {
  final String peerId;
  final VideoMessage message;

  const VideoViewerScreen({
    super.key,
    required this.peerId,
    required this.message,
  });

  @override
  ConsumerState<VideoViewerScreen> createState() => _VideoViewerScreenState();
}

class _VideoViewerScreenState extends ConsumerState<VideoViewerScreen>
    with WidgetsBindingObserver {
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // Backgrounding consumes the view, same as images.
      _markViewedAndPop();
    }
  }

  void _markViewedAndPop() {
    if (_dismissed || !mounted) return;
    _dismissed = true;
    ref
        .read(conversationProvider.notifier)
        .markVideoViewed(widget.peerId, widget.message.messageId);
    context.pop();
  }

  Future<void> _confirmClose() async {
    final shouldClose = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Close video?'),
            content: const Text('This video will disappear forever. Continue?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Close')),
            ],
          ),
        ) ??
        false;
    if (shouldClose) _markViewedAndPop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _confirmClose();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: _confirmClose,
          ),
          title: const Text('View Once', style: TextStyle(color: Colors.white)),
        ),
        body: SafeArea(
          child: Center(
            child: SecureVideoWidget(
              videoBytes: widget.message.videoBytes,
              // Auto-dismiss when playback finishes.
              onCompleted: _markViewedAndPop,
            ),
          ),
        ),
      ),
    );
  }
}
