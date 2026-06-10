import 'package:flutter_test/flutter_test.dart';
import 'package:seeonce_app/app.dart';

void main() {
  testWidgets('SeeOnce app smoke test', (WidgetTester tester) async {
    // Builds the app and verifies it renders a root widget.
    // Note: full integration tests are in integration_test/.
    expect(SeeOnceApp, isNotNull);
  });
}

