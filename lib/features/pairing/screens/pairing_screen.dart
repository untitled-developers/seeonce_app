import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/pairing_provider.dart';

class PairingScreen extends ConsumerWidget {
  const PairingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair a Device'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.devices, size: 72, color: Color(0xFF7B61FF)),
              const SizedBox(height: 8),
              const Text(
                'Connect with a contact',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'You\'ll exchange short codes to securely pair devices.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 40),

              // ── Option A: I start (generate offer) ─────────────────
              const _SectionLabel(text: 'I want to initiate pairing'),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: () async {
                  ref.read(pairingProvider.notifier).reset();
                  // Start generating in background, then navigate
                  ref.read(pairingProvider.notifier).generateOffer();
                  context.push('/pairing/show-code');
                },
                icon: const Icon(Icons.qr_code),
                label: const Text('Generate My Code'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),

              const SizedBox(height: 28),
              const Row(children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text('OR', style: TextStyle(color: Colors.grey)),
                ),
                Expanded(child: Divider()),
              ]),
              const SizedBox(height: 28),

              // ── Option B: They started (I scan/enter their offer) ──
              const _SectionLabel(text: 'They sent me a code'),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () {
                  ref.read(pairingProvider.notifier).reset();
                  context.push('/pairing/scan-code');
                },
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan / Enter Their Code'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.primary,
        letterSpacing: 0.8,
      ),
      textAlign: TextAlign.center,
    );
  }
}
