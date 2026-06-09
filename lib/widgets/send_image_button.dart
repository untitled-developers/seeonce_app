import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// A bottom-sheet button that lets the user pick an image from gallery or camera.
/// Calls [onImageSelected] with the picked file path.
class SendImageButton extends StatelessWidget {
  final bool enabled;
  final bool isSending;
  final Future<void> Function(String filePath, ImageSource source)
      onImageSelected;

  const SendImageButton({
    super.key,
    required this.enabled,
    required this.isSending,
    required this.onImageSelected,
  });

  Future<void> _showPicker(BuildContext context) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from Gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take Photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
        ),
      ),
    );

    if (source == null) return;

    final picker = ImagePicker();
    final xFile = await picker.pickImage(source: source);
    if (xFile == null) return;

    await onImageSelected(xFile.path, source);
  }

  @override
  Widget build(BuildContext context) {
    return isSending
        ? const SizedBox(
            width: 48,
            height: 48,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        : FloatingActionButton(
            onPressed: enabled ? () => _showPicker(context) : null,
            tooltip: 'Send image',
            child: const Icon(Icons.add_photo_alternate),
          );
  }
}
