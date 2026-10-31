import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:futurenote/models.dart';
import 'package:futurenote/screens/library_screen.dart';
import 'package:futurenote/store.dart';

void main() {
  test('notebooks survive a reload with their ink and text', () async {
    final dir = Directory.systemTemp.createTempSync('fn_store');
    final store = NotebookStore(root: dir);
    await store.load();
    expect(store.notebooks.single.title, 'دفتري الأول');

    final book = store.create('اجتماع', template: PageTemplate.grid);
    book.pages.first.strokes = [
      InkStroke(
        tool: InkTool.pen,
        color: 0xFF000000,
        width: 3,
        points: const [InkPoint(10, 20, 1000, 0.4), InkPoint(30, 40, 1016)],
      ),
    ];
    book.pages.first.text = 'محمد قال نبدأ';
    book.pages.first.typed = [
      const TypedLine(
        box: Rect.fromLTWH(60, 200, 880, 50),
        text: 'محمد قال نبدأ',
      ),
    ];
    book.recordings.add(
      Recording(
        id: 'r1',
        file: 'r1.m4a',
        started: DateTime(2026, 10, 31, 9),
        duration: const Duration(minutes: 3),
        transcript: const [TranscriptPiece(Duration(seconds: 5), 'صباح الخير')],
      ),
    );
    store.changed(book);
    await store.flush();

    final again = NotebookStore(root: dir);
    await again.load();
    final copy = again.byId(book.id)!;
    expect(copy.title, 'اجتماع');
    expect(copy.pages.first.template, PageTemplate.grid);
    final s = copy.pages.first.strokes.single;
    expect(s.points.length, 2);
    final typed = copy.pages.first.typed.single;
    expect(typed.text, 'محمد قال نبدأ');
    expect(typed.box.top, 200);
    expect(typed.rtl, isTrue);
    expect(s.points.first.x, 10);
    expect(s.points.first.pressure, closeTo(0.4, 0.001));
    expect(copy.recordings.single.transcript.single.text, 'صباح الخير');
    expect(notebookMatches(copy, 'نبدأ'), isTrue);
    expect(notebookMatches(copy, 'الخير'), isTrue);
    expect(notebookMatches(copy, 'غير موجود'), isFalse);

    await again.delete(copy);
    expect(again.byId(book.id), isNull);
  });

  test('a stroke is hit near its line, not far away', () {
    final s = InkStroke(
      tool: InkTool.pen,
      color: 0,
      width: 2,
      points: const [InkPoint(0, 0, 0), InkPoint(100, 0, 1)],
    );
    expect(s.hits(const Offset(50, 4), 5), isTrue);
    expect(s.hits(const Offset(50, 40), 5), isFalse);
  });
}
