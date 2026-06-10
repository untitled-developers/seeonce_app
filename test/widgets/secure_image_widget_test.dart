import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seeonce_app/widgets/secure_image_widget.dart';

// A valid 1x1 PNG so the image actually decodes into the cache.
final _png = Uint8List.fromList(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC'));

void main() {
  testWidgets('decoded image is evicted from the image cache on dispose',
      (tester) async {
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();

    final bytes = Uint8List.fromList(_png);

    // Image decoding is genuinely async, so the pump that triggers it must run
    // inside runAsync for the codec to complete.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: SecureImageWidget(imageBytes: bytes)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(imageCache.currentSize, greaterThan(0),
        reason: 'image should be cached after first display');

    // Remove the widget — its useEffect cleanup evicts the provider.
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(imageCache.currentSize, equals(0),
        reason: 'decoded image must be evicted after "view once"');
  });
}
