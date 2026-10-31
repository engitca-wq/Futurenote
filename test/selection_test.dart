import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:futurenote/export.dart';
import 'package:futurenote/ink_canvas.dart';
import 'package:futurenote/models.dart';

InkStroke line(double x, double y) => InkStroke(
  tool: InkTool.pen,
  color: 0,
  width: 2,
  points: [InkPoint(x, y, 0), InkPoint(x + 40, y, 1)],
);

List<Offset> square(double l, double t, double r, double b) => [
  Offset(l, t),
  Offset(r, t),
  Offset(r, b),
  Offset(l, b),
];

void main() {
  test(
    'lasso picks what is inside, then moves, scales, copies and deletes',
    () {
      final inside = line(100, 100);
      final outside = line(600, 600);
      final note = const TypedLine(
        box: Rect.fromLTWH(100, 150, 200, 50),
        text: 'مهمة',
        todo: true,
      );
      final page = NotePage(
        id: 'p',
        template: PageTemplate.blank,
        strokes: [inside, outside],
        typed: [note],
      );
      final sel = Selection();

      expect(sel.select(page, square(50, 50, 400, 250)), isTrue);
      expect(sel.box!.top, lessThan(101));

      sel.transform(const Offset(10, 20));
      expect(page.strokes.first.points.first.x, 110);
      expect(page.strokes.first.points.first.y, 120);
      expect(page.strokes.last, same(outside));
      expect(page.typed.single.box.top, 170);
      expect(page.typed.single.todo, isTrue);

      final w = sel.box!.width;
      sel.transform(Offset.zero, k: 2);
      expect(sel.box!.width, closeTo(w * 2, 0.01));

      sel.copy();
      final before = sel.delete()!;
      expect(before.strokes.length, 2);
      expect(page.strokes, [outside]);
      expect(page.typed, isEmpty);
      expect(sel.active, isFalse);

      sel.paste(page, Selection.clipboard!, const Offset(30, 30));
      expect(page.strokes.length, 2);
      expect(page.typed.length, 1);
      expect(sel.active, isTrue);
    },
  );

  test('an empty lasso selects nothing', () {
    final page = NotePage(
      id: 'p',
      template: PageTemplate.blank,
      strokes: [line(600, 600)],
    );
    expect(Selection().select(page, square(0, 0, 100, 100)), isFalse);
  });

  test('shapes become pen strokes along their outline', () {
    final rect = shapePoints(
      ShapeKind.rect,
      const Offset(0, 0),
      const Offset(100, 50),
      0,
    );
    expect(rect.first.x, 0);
    expect(rect.any((p) => p.x == 100 && p.y == 50), isTrue);
    final circle = shapePoints(
      ShapeKind.ellipse,
      const Offset(0, 0),
      const Offset(100, 100),
      0,
    );
    for (final p in circle) {
      expect(
        (Offset(p.x, p.y) - const Offset(50, 50)).distance,
        closeTo(50, 0.01),
      );
    }
    expect(
      shapePoints(ShapeKind.arrow, Offset.zero, const Offset(200, 0), 0).length,
      greaterThan(
        shapePoints(
          ShapeKind.line,
          Offset.zero,
          const Offset(200, 0),
          0,
        ).length,
      ),
    );
  });

  test('pictures and tasks survive saving', () {
    final page = NotePage(
      id: 'p',
      template: PageTemplate.lined,
      typed: [
        const TypedLine(
          box: Rect.fromLTWH(60, 60, 880, 50),
          text: 'اشتري ورق',
          todo: true,
          done: true,
        ),
      ],
      images: [
        const PageImage(file: 'a.jpg', box: Rect.fromLTWH(150, 160, 700, 400)),
      ],
    );
    final copy = NotePage.fromJson(page.toJson());
    expect(copy.typed.single.done, isTrue);
    expect(copy.images.single.file, 'a.jpg');
    expect(copy.images.single.box.width, 700);
  });

  test('a page renders to a PNG of the page proportions', () async {
    final page = NotePage(
      id: 'p',
      template: PageTemplate.lined,
      strokes: [line(100, 100)],
      typed: [const TypedLine(box: Rect.fromLTWH(60, 60, 880, 50), text: 'نص')],
    );
    final png = await renderPagePng(page, width: 500);
    expect(png.sublist(1, 4), [0x50, 0x4E, 0x47]); // "PNG"
    final codec = await instantiateImageCodec(png);
    final img = (await codec.getNextFrame()).image;
    expect(img.width, 500);
    expect(img.height, closeTo(500 * kPageHeight / kPageWidth, 1));
  });
}
