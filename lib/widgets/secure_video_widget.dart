import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Plays a view-once video entirely from memory: a loopback HTTP server on
/// 127.0.0.1 streams the decrypted bytes to [video_player] so the clip never
/// touches disk (matching the image's see-once guarantee). On dispose the
/// server is closed, the controller released and the bytes zero-filled.
class SecureVideoWidget extends StatefulWidget {
  final Uint8List videoBytes;

  const SecureVideoWidget({
    super.key,
    required this.videoBytes,
  });

  @override
  State<SecureVideoWidget> createState() => _SecureVideoWidgetState();
}

class _SecureVideoWidgetState extends State<SecureVideoWidget> {
  HttpServer? _server;
  VideoPlayerController? _controller;
  String? _error;

  /// Unguessable per-view URL path. Loopback is reachable by every app on the
  /// device, so without this any local process could port-scan 127.0.0.1 and
  /// download the decrypted video while the viewer is open.
  late final String _token = base64UrlEncode(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)));

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    try {
      // Bind to loopback on a random free port; only this device can reach it.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      server.listen(_handleRequest);

      final url = 'http://${server.address.address}:${server.port}/$_token.mp4';
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      _controller = controller;
      await controller.initialize();
      // Loop continuously: a view-once video keeps replaying until the viewer
      // closes it manually (or backgrounds the app), rather than auto-dismissing
      // the instant it reaches the end.
      await controller.setLooping(true);
      await controller.play();
      if (mounted) setState(() {});
    } catch (e) {
      if (kDebugMode) debugPrint('[SecureVideo] setup failed: $e');
      if (mounted) setState(() => _error = 'Could not play this video.');
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final bytes = widget.videoBytes;
    final total = bytes.length;
    final res = request.response;
    if (request.uri.path != '/$_token.mp4') {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    try {
      res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      res.headers.contentType = ContentType('video', 'mp4');

      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null && range.startsWith('bytes=') && total > 0) {
        final spec = range.substring(6).split('-');
        var start = int.tryParse(spec[0]) ?? 0;
        var end = (spec.length > 1 && spec[1].isNotEmpty)
            ? (int.tryParse(spec[1]) ?? total - 1)
            : total - 1;
        if (start < 0) start = 0;
        if (end >= total) end = total - 1;
        if (start > end) start = end;
        final chunk = bytes.sublist(start, end + 1);
        res.statusCode = HttpStatus.partialContent;
        res.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
        res.headers.contentLength = chunk.length;
        res.add(chunk);
      } else {
        res.statusCode = HttpStatus.ok;
        res.headers.contentLength = total;
        res.add(bytes);
      }
    } catch (_) {
      res.statusCode = HttpStatus.internalServerError;
    } finally {
      await res.close();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _server?.close(force: true);
    // Zero-fill the decrypted video so it doesn't linger in memory.
    widget.videoBytes.fillRange(0, widget.videoBytes.length, 0);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: Colors.white70)),
      );
    }
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return AspectRatio(
      aspectRatio: c.value.aspectRatio <= 0 ? 16 / 9 : c.value.aspectRatio,
      child: VideoPlayer(c),
    );
  }
}
