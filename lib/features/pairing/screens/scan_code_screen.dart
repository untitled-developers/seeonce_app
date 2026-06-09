import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/pairing_provider.dart';

class ScanCodeScreen extends ConsumerStatefulWidget {
  const ScanCodeScreen({super.key});

  @override
  ConsumerState<ScanCodeScreen> createState() => _ScanCodeScreenState();
}

class _ScanCodeScreenState extends ConsumerState<ScanCodeScreen>
    with SingleTickerProviderStateMixin {
  bool _scanned = false;
  late final TabController _tabController;
  final _textController = TextEditingController();
  MobileScannerController? _scannerController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      // Pause/resume scanner when switching tabs to avoid resource waste
      if (!_tabController.indexIsChanging) return;
      if (_tabController.index == 0) {
        _scannerController?.start();
      } else {
        _scannerController?.stop();
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _textController.dispose();
    _scannerController?.dispose();
    super.dispose();
  }

  void _handleCode(String code) {
    if (_scanned) return;
    _scanned = true;
    final isScanningAnswer = GoRouterState.of(context).extra == true;
    if (isScanningAnswer) {
      ref.read(pairingProvider.notifier).processAnswer(code.trim());
    } else {
      ref.read(pairingProvider.notifier).processOffer(code.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isScanningAnswer = GoRouterState.of(context).extra == true;
    final state = ref.watch(pairingProvider);

    ref.listen(pairingProvider, (previous, next) {
      if (next.isPaired) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Successfully Paired!')),
        );
        context.go('/');
      } else if (next.error != null && previous?.error != next.error) {
        // Allow the user to retry
        setState(() => _scanned = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${next.error}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    });

    // ── Step 2 part B: Responder shows their answer code ────────────────
    if (state.ownAnswerCode != null) {
      return _AnswerCodeDisplay(answerCode: state.ownAnswerCode!);
    }

    final title = isScanningAnswer ? 'Scan Answer Code' : 'Scan Offer Code';
    final hint = isScanningAnswer
        ? 'Paste or type the answer code from your contact'
        : 'Paste or type the offer code from your contact';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.qr_code_scanner), text: 'Scan QR'),
            Tab(icon: Icon(Icons.keyboard), text: 'Enter Code'),
          ],
        ),
      ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tabController,
            children: [
              // ── Tab 1: Camera scanner ──────────────────────────────
              _buildScanner(isScanningAnswer),

              // ── Tab 2: Manual text entry ───────────────────────────
              _buildManualEntry(context, hint),
            ],
          ),

          // Loading overlay — shows contextual status (Connecting…, Exchanging keys…, etc.)
          if (state.isGenerating)
            Container(
              color: Colors.black54,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 16),
                    Text(
                      state.statusMessage ?? 'Processing code…',
                      style: const TextStyle(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                    if (state.statusMessage != null &&
                        state.statusMessage!.contains('key'))
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'This happens automatically — no action needed.',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildScanner(bool isScanningAnswer) {
    return MobileScanner(
      controller: (_scannerController ??= MobileScannerController()),
      onDetect: (capture) {
        if (_scanned) return;
        for (final barcode in capture.barcodes) {
          if (barcode.rawValue != null) {
            _handleCode(barcode.rawValue!);
            break;
          }
        }
      },
    );
  }

  Widget _buildManualEntry(BuildContext context, String hint) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          const Text(
            'Paste the code you received:',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _textController,
            maxLines: 6,
            decoration: InputDecoration(
              hintText: hint,
              border: const OutlineInputBorder(),
              filled: true,
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste),
                tooltip: 'Paste from clipboard',
                onPressed: () async {
                  final data = await Clipboard.getData('text/plain');
                  if (data?.text != null) {
                    _textController.text = data!.text!;
                  }
                },
              ),
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              final code = _textController.text.trim();
              if (code.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter a code first')),
                );
                return;
              }
              _handleCode(code);
            },
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Use This Code'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),
          const Text(
            'Tip: Copy the code from the other device, then tap the paste icon above.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Shown to the Responder (Step 2B): display the answer code so the
/// Initiator can scan or copy it.
class _AnswerCodeDisplay extends StatelessWidget {
  final String answerCode;
  const _AnswerCodeDisplay({required this.answerCode});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your Answer Code')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Step 2 of 3',
              style: TextStyle(color: Colors.grey, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            const Text(
              'Share this answer code back to the other device',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),

            // Text code + copy
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SelectableText(
                    answerCode,
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
                        await Clipboard.setData(
                            ClipboardData(text: answerCode));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Answer code copied!'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy Answer Code'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // QR code
            const Text(
              'Or have them scan this:',
              style: TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Center(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.all(12),
                child: QrImageView(
                  data: answerCode,
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: Colors.white,
                  errorCorrectionLevel: QrErrorCorrectLevel.L,
                  errorStateBuilder: (ctx, err) => const SizedBox(
                    width: 220,
                    height: 80,
                    child: Center(
                      child: Text(
                        'Code too large for QR.\nUse the text above.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Waiting for the other device to complete pairing…',
              style: TextStyle(color: Colors.grey, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
