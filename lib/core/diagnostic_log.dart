import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// One captured diagnostic event.
class DiagnosticLogEntry {
  final DateTime time;
  final String tag;
  final String message;
  const DiagnosticLogEntry(this.time, this.tag, this.message);
}

/// In-memory ring buffer of connection diagnostics, viewable in the UI (tap a
/// "Reconnecting…" ribbon) so reconnect problems can be debugged on production
/// devices where logcat is unavailable.
///
/// Memory only — never written to disk — and capped, in keeping with the app's
/// ephemerality rules. Entries can contain peer display names and key hashes;
/// they stay on the device's own screen and are only mirrored to the console
/// in debug builds (never production logcat).
class DiagnosticLog {
  static final DiagnosticLog instance = DiagnosticLog._();
  DiagnosticLog._();

  static const int maxEntries = 500;

  final ListQueue<DiagnosticLogEntry> _entries = ListQueue();
  final _changeController = StreamController<void>.broadcast();

  /// Fires whenever an entry is added or the log is cleared.
  Stream<void> get onChange => _changeController.stream;

  /// Oldest-first snapshot of the buffer.
  List<DiagnosticLogEntry> get entries => List.unmodifiable(_entries);

  void add(String tag, String message) {
    _entries.addLast(DiagnosticLogEntry(DateTime.now(), tag, message));
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    if (kDebugMode) debugPrint('[$tag] $message');
    _changeController.add(null);
  }

  void clear() {
    _entries.clear();
    _changeController.add(null);
  }

  /// Plain-text dump for the copy-to-clipboard action in the log screen.
  String export() => _entries
      .map((e) => '${e.time.toIso8601String()} [${e.tag}] ${e.message}')
      .join('\n');
}
