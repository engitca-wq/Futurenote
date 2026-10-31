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
  });
}
