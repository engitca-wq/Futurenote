import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;

enum ReaderState { preparing, downloading, ready, failed }

/// Reads handwriting on the device with Google ML Kit Digital Ink.
///
/// Arabic is the main model. A line whose Arabic reading comes out mostly in
/// Latin letters is read again with the English model, so mixed notes work
/// without switching language by hand.
class HandwritingReader {
  HandwritingReader._();
  static final instance = HandwritingReader._();

  static const primary = 'ar';
  static const secondary = 'en';

  final state = ValueNotifier(ReaderState.preparing);
  final _models = mlkit.DigitalInkRecognizerModelManager();
  final Map<String, mlkit.DigitalInkRecognizer> _recognizers = {};
  Future<void>? _preparing;

  bool get ready => state.value == ReaderState.ready;

  Future<void> prepare() => _preparing ??= _prepare();

  Future<void> retry() {
    _preparing = null;
    return prepare();
  }

  Future<void> _prepare() async {
    state.value = ReaderState.preparing;
    try {
      if (!await _ensure(primary)) {
        state.value = ReaderState.failed;
        return;
      }
      state.value = ReaderState.ready;
      // English is a bonus for mixed lines; Arabic works without it.
      await _ensure(secondary);
    } catch (e) {
      debugPrint('Handwriting models failed: $e');
      if (!_recognizers.containsKey(primary)) state.value = ReaderState.failed;
    }
  }

  Future<bool> _ensure(String code) async {
    if (!await _models.isModelDownloaded(code)) {
      if (code == primary) state.value = ReaderState.downloading;
      if (!await _models.downloadModel(code, isWifiRequired: false)) {
        return false;
      }
    }
    _recognizers[code] = mlkit.DigitalInkRecognizer(languageCode: code);
    return true;
  }

  /// Reads one written line. Returns up to [max] readings, best first.
  Future<List<String>> readLine(
    List<List<mlkit.StrokePoint>> strokes, {
    required Size area,
    String preContext = '',
    int max = 5,
  }) async {
    final ar = _recognizers[primary];
    if (ar == null) return const [];
    final ink = mlkit.Ink()
      ..strokes = [for (final s in strokes) mlkit.Stroke()..points = s];
    final context = mlkit.DigitalInkRecognitionContext(
      preContext: preContext,
      writingArea: mlkit.WritingArea(width: area.width, height: area.height),
    );
    final arTexts = _clean(await ar.recognize(ink, context: context));
    final en = _recognizers[secondary];
    if (en != null && (arTexts.isEmpty || latinShare(arTexts.first) > 0.5)) {
      final enTexts = _clean(await en.recognize(ink, context: context));
      return {...enTexts, ...arTexts}.take(max).toList();
    }
    return arTexts.take(max).toList();
  }

  static List<String> _clean(List<mlkit.RecognitionCandidate> c) =>
      [for (final x in c) x.text.trim()].where((t) => t.isNotEmpty).toList();
}

/// Share of letters in [text] that are Latin rather than Arabic.
double latinShare(String text) {
  var latin = 0, arabic = 0;
  for (final r in text.runes) {
    if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
      latin++;
    } else if (r >= 0x0600 && r <= 0x06FF) {
      arabic++;
    }
  }
  final total = latin + arabic;
  return total == 0 ? 0 : latin / total;
}

/// Splits strokes into written lines by how they overlap vertically, so
/// large handwriting that crosses ruled lines stays on one line and Arabic
/// dots and marks join the word they belong to. Lines come back top to
/// bottom, strokes in the order they were written.
List<List<T>> groupIntoLines<T>(
  List<T> strokes,
  Rect Function(T) boundsOf, {
  double dotSize = 18,
}) {
  final lines = <({List<T> strokes, Rect box})>[];
  for (final s in strokes) {
    final b = boundsOf(s);
    if (!b.isFinite) continue;
    final small = b.height < dotSize && b.width < dotSize;
    var best = -1;
    var bestScore = 0.0;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i].box;
      double score;
      if (small) {
        // A dot or hamza sits just above or below its letters.
        final reach = l.inflate(l.height * 0.6);
        score = reach.contains(b.center)
            ? 1 / (1 + (b.center.dy - l.center.dy).abs())
            : 0;
      } else {
        final overlap = math.min(b.bottom, l.bottom) - math.max(b.top, l.top);
        score = overlap / math.max(1, math.min(b.height, l.height));
        if (score < 0.35) score = 0;
      }
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    if (best == -1) {
      lines.add((strokes: [s], box: b));
    } else {
      final l = lines[best];
      lines[best] = (strokes: [...l.strokes, s], box: l.box.expandToInclude(b));
    }
  }
  lines.sort((a, b) => a.box.top.compareTo(b.box.top));
  return [for (final l in lines) l.strokes];
}
