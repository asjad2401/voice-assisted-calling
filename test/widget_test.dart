import 'package:flutter_test/flutter_test.dart';
import 'package:blind_call_assistant/main.dart';

void main() {
  testWidgets('BlindCallAssistantApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const BlindCallAssistantApp());
    expect(find.byType(BlindCallAssistantApp), findsOneWidget);
  });
}
