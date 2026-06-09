import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../data/models/image_message.dart';
import '../../../widgets/secure_image_widget.dart';
import '../providers/conversation_provider.dart';

class ImageViewerScreen extends ConsumerStatefulWidget {
  final String peerId;
  final ImageMessage message;

  const ImageViewerScreen({
    super.key,
    required this.peerId,
    required this.message,
  });

  @override
  ConsumerState<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends ConsumerState<ImageViewerScreen> with WidgetsBindingObserver {
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
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      if (mounted) {
        // Auto-dismiss when app is backgrounded — mark viewed so the tile is removed.
        ref
            .read(conversationProvider.notifier)
            .markAsViewed(widget.peerId, widget.message.messageId);
        context.pop();
      }
    }
  }

  Future<bool> _onWillPop() async {
    return await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Close Image?"),
        content: const Text("This image will disappear forever. Continue?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text("Close"),
          ),
        ],
      ),
    ) ?? false;
  }

  Future<void> _dismissImage() async {
    final shouldClose = await _onWillPop();
    if (shouldClose && mounted) {
      // Mark viewed (removes message from state) before popping so the
      // conversation screen rebuilds without the tile immediately.
      ref
          .read(conversationProvider.notifier)
          .markAsViewed(widget.peerId, widget.message.messageId);
      // ignore: use_build_context_synchronously
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _dismissImage();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: _dismissImage,
          ),
          title: const Text("View Once", style: TextStyle(color: Colors.white)),
        ),
        body: SafeArea(
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  child: SecureImageWidget(
                    imageBytes: widget.message.imageBytes,
                  ),
                ),
              ),
              Positioned(
                bottom: 20,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      "Closes when dismissed",
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
