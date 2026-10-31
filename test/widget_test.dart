import 'package:flutter_test/flutter_test.dart';
import 'package:futurenote/main.dart';

void main() {
  testWidgets('shows the writing page', (tester) async {
    await tester.pumpWidget(const FutureNoteApp());
    expect(find.text('FUTURENOTE'), findsOneWidget);
    expect(find.text('مختبر قراءة خط اليد'), findsOneWidget);
  });
}
