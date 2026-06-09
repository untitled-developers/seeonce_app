import 'dart:typed_data';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import '../data/repositories/settings_repository.dart';

class ImageCompressor {
  static Future<Uint8List?> compress({
    required String filePath,
    required CompressionSettings settings,
  }) async {
    final result = await FlutterImageCompress.compressWithFile(
      filePath,
      minWidth: settings.maxDimension,
      minHeight: settings.maxDimension,
      quality: settings.jpegQuality,
      format: CompressFormat.jpeg,
      keepExif: false, // strip EXIF for privacy
    );
    return result;
  }
}
