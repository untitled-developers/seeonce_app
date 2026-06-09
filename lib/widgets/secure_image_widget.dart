import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

class SecureImageWidget extends HookWidget {
  final Uint8List imageBytes;

  const SecureImageWidget({
    super.key,
    required this.imageBytes,
  });

  @override
  Widget build(BuildContext context) {
    // Own the provider so we can evict its decoded bitmap on the way out.
    final provider = useMemoized(() => MemoryImage(imageBytes), [imageBytes]);

    useEffect(() {
      return () {
        // 1. Evict the decoded frame from Flutter's image cache. Zero-filling
        //    the encoded bytes alone is not enough: Image.memory decodes into
        //    imageCache, and that bitmap would survive "view once" otherwise.
        provider.evict();
        // 2. Zero-fill the encoded bytes so they don't linger in memory.
        imageBytes.fillRange(0, imageBytes.length, 0);
      };
    }, [provider]);

    return Image(
      image: provider,
      fit: BoxFit.contain,
      gaplessPlayback: false,
    );
  }
}
