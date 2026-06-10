import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/diagnostic_log.dart';

/// Live view of the in-memory connection diagnostics buffer. Reached by
/// tapping a "Reconnecting…" ribbon, so reconnect failures can be inspected
/// directly on a production device.
class ConnectionLogsScreen extends StatefulWidget {
  const ConnectionLogsScreen({super.key});

  @override
  State<ConnectionLogsScreen> createState() => _ConnectionLogsScreenState();
}

class _ConnectionLogsScreenState extends State<ConnectionLogsScreen> {
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = DiagnosticLog.instance.onChange.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Color _tagColor(String tag) {
    switch (tag) {
      case 'Reconnect':
        return Colors.orange;
      case 'Supervisor':
        return const Color(0xFF9B89FF);
      case 'Pool':
        return Colors.lightGreen;
      default:
        return Colors.grey;
    }
  }

  String _time(DateTime t) {
    String p2(int v) => v.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '${p2(t.hour)}:${p2(t.minute)}:${p2(t.second)}.$ms';
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: DiagnosticLog.instance.export()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Logs copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Newest first, so the most recent event is visible without scrolling.
    final entries = DiagnosticLog.instance.entries.reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy all',
            onPressed: entries.isEmpty ? null : _copyAll,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: entries.isEmpty ? null : DiagnosticLog.instance.clear,
          ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(
              child: Text('No connection events yet.',
                  style: TextStyle(color: Colors.grey)))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final e = entries[index];
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _time(e.time),
                        style: const TextStyle(
                          color: Color(0xFF9090A0),
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        e.tag,
                        style: TextStyle(
                          color: _tagColor(e.tag),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          e.message,
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
