import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/pairing_provider.dart';

class ShowCodeScreen extends ConsumerWidget {
  const ShowCodeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(pairingProvider);

    ref.listen(pairingProvider, (previous, next) {
      if (next.isPaired) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Successfully Paired!')),
        );
        context.go('/');
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Your Offer Code')),
      body: state.isGenerating
          ? _buildLoading(state.statusMessage)
          : state.ownOfferCode != null
              ? _buildCode(context, ref, state.ownOfferCode!)
              : _buildError(context, ref, state.error),
    );
  }

  Widget _buildLoading([String? message]) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            message ?? 'Generating code…',
            style: const TextStyle(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context, WidgetRef ref, String? error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              error ?? 'Failed to generate code',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                // reset() clears the state; generateOffer() immediately sets
                // isGenerating=true, so the spinner shows without a flash.
                ref.read(pairingProvider.notifier).reset();
                ref.read(pairingProvider.notifier).generateOffer();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCode(BuildContext context, WidgetRef ref, String code) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Step 1 of 3',
            style: TextStyle(color: Colors.grey, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          const Text(
            'Share this code with your contact',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // ── Text Code Box ──────────────────────────────────────────────
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                SelectableText(
                  code,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    letterSpacing: 0.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: code));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Code copied to clipboard!'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy Code'),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // ── QR Code (best-effort; may fail for very large codes) ───────
          const Text(
            'Or scan this QR code:',
            style: TextStyle(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          _QrOrFallback(code: code),

          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 16),

          // ── Next step ─────────────────────────────────────────────────
          const Text(
            'After your contact shares their answer code back to you, tap below:',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () =>
                context.pushReplacement('/pairing/scan-code', extra: true),
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Enter / Scan their answer'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders a QR code for the pairing [code].
/// The errorStateBuilder handles any edge cases where data is still too large.
class _QrOrFallback extends StatelessWidget {
  final String code;
  const _QrOrFallback({required this.code});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(12),
        child: QrImageView(
          data: code,
          version: QrVersions.auto,
          size: 240,
          backgroundColor: Colors.white,
          errorCorrectionLevel: QrErrorCorrectLevel.L,
          errorStateBuilder: (ctx, err) => _qrTooLarge(context),
        ),
      ),
    );
  }

  Widget _qrTooLarge(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Column(
        children: [
          Icon(Icons.qr_code, size: 48, color: Colors.grey),
          SizedBox(height: 8),
          Text(
            'Code too large for QR — use the text code above.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
