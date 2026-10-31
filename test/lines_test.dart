import 'package:flutter_test/flutter_test.dart';
import 'package:futurenote/models.dart';
import 'package:futurenote/recognition.dart';

InkStroke stroke(List<List<double>> pts) => InkStroke(
  tool: InkTool.pen,
  color: 0,
  width: 3,
  points: [for (final p in pts) InkPoint(p[0], p[1], 0)],
);

void main() {
  test('tall word crossing a ruled line stays one line, dots join it', () {
    final word = stroke([
      [300, 60],
      [250, 170],
      [200, 120],
    ]); // spans two ruled lines
    final dot = stroke([
      [240, 190],
      [243, 192],
    ]); // dot under the word
    final next = stroke([
      [300, 320],
      [200, 360],
    ]); // a second line further down
    final lines = groupIntoLines([word, dot, next], (s) => s.bounds);
    expect(lines.length, 2);
    expect(lines[0], containsAll([word, dot]));
    expect(lines[1], [next]);
  });

  test('latinShare tells English lines from Arabic ones', () {
    expect(latinShare('agmohaane aido'), 1);
    expect(latinShare('محمد قال'), 0);
    expect(latinShare('10 دقائق'), 0);
  });
}
