import 'package:flutter_test/flutter_test.dart';
import 'package:futurenote/main.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart' as mlkit;

StrokeData stroke(List<List<double>> pts) {
  final s = StrokeData(3);
  for (final p in pts) {
    s.points.add(mlkit.StrokePoint(x: p[0], y: p[1], t: 0));
  }
  return s;
}

void main() {
  test('tall word crossing a ruled line stays one line, dots join it', () {
    final word = stroke([[300, 60], [250, 170], [200, 120]]); // spans two ruled lines
    final dot = stroke([[240, 190], [243, 192]]); // dot under the word
    final next = stroke([[300, 320], [200, 360]]); // a second line further down
    final lines = groupIntoLines([word, dot, next]);
    expect(lines.length, 2);
    expect(lines[0], containsAll([word, dot]));
    expect(lines[1], [next]);
  });
}
