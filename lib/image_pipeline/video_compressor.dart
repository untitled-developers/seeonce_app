import 'dart:io';
import 'dart:typed_data';
import 'package:video_compress/video_compress.dart';
import '../core/constants.dart';

class CompressedVideo {
  final Uint8List bytes;
  final int durationMs;
  final String path; // temp file produced by the compressor (sender-side)
  const CompressedVideo(this.bytes, this.durationMs, this.path);
}

/// Compresses + trims a picked/recorded video down to a small, view-once clip:
/// medium quality, trimmed to [AppConstants.maxVideoDuration]. Audio kept.
class VideoCompressor {
  /// Returns the compressed bytes (read into memory) plus metadata, or null if
  /// compression failed. Caller owns [CompressedVideo.path] and should delete it
  /// after use.
  static Future<CompressedVideo?> compress(String filePath) async {
    final trimSeconds = AppConstants.maxVideoDuration.inSeconds;

    // Only pass a trim window when the clip is actually longer than the cap.
    // Asking video_compress for a `duration` that exceeds the source length
    // makes it fail outright on Android ("failed to compress"), which broke
    // every sub-10s video. A null duration means "use the whole clip".
    int? trimDuration;
    try {
      final media = await VideoCompress.getMediaInfo(filePath);
      final totalMs = media.duration ?? 0;
      if (totalMs > trimSeconds * 1000) {
        trimDuration = trimSeconds;
      }
    } catch (_) {
      trimDuration = null; // probe failed — compress the whole clip
    }

    final info = await VideoCompress.compressVideo(
      filePath,
      quality: VideoQuality.MediumQuality,
      deleteOrigin: false,
      includeAudio: true,
      startTime: trimDuration != null ? 0 : null,
      duration: trimDuration, // hard cap to 10s only when the clip is longer
    );

    final path = info?.path;
    if (info == null || path == null) return null;

    final bytes = await File(path).readAsBytes();
    final durationMs = (info.duration ?? 0).round();
    return CompressedVideo(Uint8List.fromList(bytes), durationMs, path);
  }
}
