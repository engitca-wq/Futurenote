import 'package:flutter_test/flutter_test.dart';

import 'dart:ui' show Rect;

import 'package:futurenote/ai.dart';
import 'package:futurenote/models.dart';
import 'package:futurenote/screens/assistant.dart';
import 'package:futurenote/screens/notebook_screen.dart';

void main() {
  test('request carries the notes, the task and the fallback', () {
    final r = buildRequest(AiTask.ask, 'محمد قال نبدأ', 'مين قال نبدأ؟');
    expect(r['model'], 'claude-opus-5-5');
    expect(r['fallbacks'], 'default');
    final content = (r['messages'] as List).single['content'] as String;
    expect(content, contains('<notes>\nمحمد قال نبدأ\n</notes>'));
    expect(content, contains('مين قال نبدأ؟'));
    expect((r['output_config'] as Map)['effort'], 'medium');
    expect(
      (buildRequest(AiTask.summary, 'x', null)['output_config']
          as Map)['effort'],
      'low',
    );
  });

  test('answer text is read from text blocks; refusals and empties fail', () {
    expect(
      parseAnswer({
        'stop_reason': 'end_turn',
        'content': [
          {'type': 'thinking', 'thinking': ''},
          {'type': 'text', 'text': ' ملخص '},
        ],
      }),
      'ملخص',
    );
    expect(
      () => parseAnswer({'stop_reason': 'refusal', 'content': []}),
      throwsA(isA<AiError>()),
    );
    expect(
      () => parseAnswer({'stop_reason': 'end_turn', 'content': []}),
      throwsA(isA<AiError>()),
    );
  });

  test('long answers wrap onto several page lines', () {
    final words = List.filled(30, 'كلمة').join(' ');
    final lines = wrapLine(words);
    expect(lines.length, greaterThan(1));
    expect(lines.every((l) => l.length <= 48), isTrue);
    expect(lines.join(' '), words);
  });

  test('notes gather page text, typed lines and transcripts', () async {
    final page = NotePage(
      id: 'p',
      template: PageTemplate.lined,
      text: 'سطر أول',
    )..typed = [const TypedLine(box: Rect.zero, text: 'ملخص قديم')];
    final notes = await gatherNotes(
      [page, NotePage(id: 'q', template: PageTemplate.lined, text: 'تاني')],
      recordings: [
        Recording(
          id: 'r',
          file: '',
          started: DateTime(2026),
          duration: Duration.zero,
          transcript: const [TranscriptPiece(Duration.zero, 'كلام اتقال')],
        ),
      ],
    );
    expect(notes, contains('صفحة 1:\nسطر أول\nملخص قديم'));
    expect(notes, contains('صفحة 2:\nتاني'));
    expect(notes, contains('كلام اتقال'));
  });
}
