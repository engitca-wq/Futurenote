import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futurenote/main.dart';
import 'package:futurenote/store.dart';

void main() {
  testWidgets('opens the library and a notebook', (tester) async {
    final dir = Directory.systemTemp.createTempSync('fn_widget');
    final store = NotebookStore(root: dir);
    await tester.runAsync(() => store.load());
    await tester.pumpWidget(FutureNoteApp(store: store, prepareReader: false));
    await tester.pumpAndSettle();
    expect(find.text('FUTURENOTE'), findsOneWidget);
    expect(find.text('دفتري الأول'), findsOneWidget);

    await tester.tap(find.text('دفتري الأول'));
    await tester.pumpAndSettle();
    expect(find.text('صفحة 1 من 1'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'صفحة'));
    await tester.pumpAndSettle();
    expect(find.text('صفحة 2 من 2'), findsOneWidget);

    // Keyboard tool: tap the page and type straight on it.
    await tester.tap(find.byTooltip('كتابة بالكيبورد'));
    await tester.pumpAndSettle();
    expect(find.text('دوس على الصفحة واكتب'), findsOneWidget);
    final page = find.byType(AspectRatio).last;
    await tester.tapAt(
      tester.getRect(page).topLeft +
          tester.getSize(page).bottomRight(Offset.zero).scale(0.3, 0.2),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'مرحبا');
    // Tapping elsewhere on the page places the text and opens a new field.
    await tester.tapAt(
      tester.getRect(page).topLeft +
          tester.getSize(page).bottomRight(Offset.zero).scale(0.3, 0.7),
    );
    await tester.pumpAndSettle();
    final book = store.notebooks.first;
    expect(book.pages.last.typed.map((t) => t.text), ['مرحبا']);

    // Shapes offer line styles.
    await tester.tap(find.byTooltip('أشكال'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('نجمة').last);
    await tester.pumpAndSettle();
    expect(find.text('متقطع'), findsOneWidget);
  });
}
