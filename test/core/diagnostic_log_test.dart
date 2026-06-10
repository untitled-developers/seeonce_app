import 'package:flutter_test/flutter_test.dart';
import 'package:seeonce_app/core/diagnostic_log.dart';

void main() {
  group('DiagnosticLog', () {
    setUp(() => DiagnosticLog.instance.clear());

    test('stores entries oldest-first with tag and message', () {
      DiagnosticLog.instance.add('Reconnect', 'first');
      DiagnosticLog.instance.add('Pool', 'second');

      final entries = DiagnosticLog.instance.entries;
      expect(entries, hasLength(2));
      expect(entries[0].tag, 'Reconnect');
      expect(entries[0].message, 'first');
      expect(entries[1].tag, 'Pool');
      expect(entries[1].message, 'second');
    });

    test('caps the buffer at maxEntries, dropping the oldest', () {
      for (var i = 0; i < DiagnosticLog.maxEntries + 10; i++) {
        DiagnosticLog.instance.add('T', 'msg $i');
      }
      final entries = DiagnosticLog.instance.entries;
      expect(entries, hasLength(DiagnosticLog.maxEntries));
      expect(entries.first.message, 'msg 10');
      expect(entries.last.message,
          'msg ${DiagnosticLog.maxEntries + 9}');
    });

    test('notifies listeners on add and clear', () async {
      var events = 0;
      final sub = DiagnosticLog.instance.onChange.listen((_) => events++);

      DiagnosticLog.instance.add('T', 'a');
      DiagnosticLog.instance.clear();
      await Future<void>.delayed(Duration.zero);

      expect(events, 2);
      await sub.cancel();
    });

    test('export contains tag and message per line', () {
      DiagnosticLog.instance.add('Supervisor', 'hello');
      expect(DiagnosticLog.instance.export(), contains('[Supervisor] hello'));
    });
  });
}
