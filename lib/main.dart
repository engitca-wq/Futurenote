import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;

void main() {
  // Show any build error on screen instead of a blank page, so a tester can report it.
  ErrorWidget.builder = (details) => Material(
    color: const Color(0xFFFBEBEB),
    child: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Text(
          'حدث خطأ، صوّر الشاشة وابعتها:\n\n${details.exceptionAsString()}',
          textDirection: TextDirection.rtl,
          style: const TextStyle(color: Color(0xFF8A1C1C)),
        ),
      ),
    ),
  );
  runApp(const FutureNoteApp());
}

const _ink = Color(0xFF1D1F22);
const _accent = Color(0xFF2F5D50);
const _paper = Color(0xFFFBFAF6);
const _rule = Color(0xFFE4E1D8);

/// Height of one ruled line on the page. Each stroke belongs to the line its
/// centre falls on, and each line is recognised on its own.
const double kLineHeight = 76;
const double kTopMargin = 24;

class FutureNoteApp extends StatelessWidget {
  const FutureNoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _accent,
      surface: const Color(0xFFF3F2EE),
    );
    return MaterialApp(
      title: 'FUTURENOTE',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: scheme.surface,
      ),
      home: const InkLabPage(),
    );
  }
}

class StrokeData {
  StrokeData(this.width);
  final double width;
  final List<mlkit.StrokePoint> points = [];

  Rect get bounds {
    var l = double.infinity,
        t = double.infinity,
        r = -double.infinity,
        b = -double.infinity;
    for (final p in points) {
      l = math.min(l, p.x);
      t = math.min(t, p.y);
      r = math.max(r, p.x);
      b = math.max(b, p.y);
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  int get line =>
      ((bounds.center.dy - kTopMargin) / kLineHeight).floor().clamp(0, 999);
}

/// Splits strokes into written lines by how they overlap vertically, so
/// large handwriting that crosses the ruled lines stays on one line and
/// Arabic dots and marks join the word they belong to.
List<List<StrokeData>> groupIntoLines(List<StrokeData> strokes) {
  final lines = <({List<StrokeData> strokes, Rect box})>[];
  for (final s in strokes.where((s) => s.points.isNotEmpty)) {
    final b = s.bounds;
    final small = b.height < 18 && b.width < 18;
    var best = -1;
    var bestScore = 0.0;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i].box;
      final overlap = math.min(b.bottom, l.bottom) - math.max(b.top, l.top);
      double score;
      if (small) {
        // A dot or hamza sits just above or below its letters.
        final reach = l.inflate(l.height * 0.6);
        score = reach.contains(b.center)
            ? 1 / (1 + (b.center.dy - l.center.dy).abs())
            : 0;
      } else {
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

class LineResult {
  LineResult(this.line, this.candidates, {required this.ruled}) : chosen = 0;
  final int line;

  /// The ruled line the text sits on, used to mark it on the page.
  final int ruled;
  final List<String> candidates;
  int chosen;
  String get text => candidates.isEmpty ? '' : candidates[chosen];
}

enum ModelState { checking, missing, downloading, ready, failed }

class Language {
  const Language(this.code, this.label);
  final String code;
  final String label;
}

const languages = [Language('ar', 'العربية'), Language('en', 'English')];

class InkLabPage extends StatefulWidget {
  const InkLabPage({super.key});

  @override
  State<InkLabPage> createState() => _InkLabPageState();
}

class _InkLabPageState extends State<InkLabPage> {
  final _models = mlkit.DigitalInkRecognizerModelManager();
  mlkit.DigitalInkRecognizer? _recognizer;
  Language _lang = languages.first;
  ModelState _modelState = ModelState.checking;

  final List<StrokeData> _strokes = [];
  final List<List<StrokeData>> _undo = [];
  StrokeData? _current;
  double _penWidth = 3.2;
  bool _penOnly = false;
  bool _sawStylus = false;
  bool _auto = true;

  Size _canvasSize = Size.zero;
  Timer? _idle;
  bool _busy = false;
  List<LineResult> _results = [];
  Duration? _lastTime;

  @override
  void initState() {
    super.initState();
    _prepareModel();
  }

  @override
  void dispose() {
    _idle?.cancel();
    _recognizer?.close();
    super.dispose();
  }

  Future<void> _prepareModel() async {
    setState(() => _modelState = ModelState.checking);
    try {
      final ok = await _models.isModelDownloaded(_lang.code);
      if (ok) {
        _useRecognizer();
      } else {
        setState(() => _modelState = ModelState.missing);
        await _download();
      }
    } catch (_) {
      setState(() => _modelState = ModelState.failed);
    }
  }

  Future<void> _download() async {
    setState(() => _modelState = ModelState.downloading);
    try {
      final ok = await _models.downloadModel(_lang.code, isWifiRequired: false);
      if (ok) {
        _useRecognizer();
      } else {
        setState(() => _modelState = ModelState.failed);
      }
    } catch (_) {
      setState(() => _modelState = ModelState.failed);
    }
  }

  void _useRecognizer() {
    _recognizer?.close();
    _recognizer = mlkit.DigitalInkRecognizer(languageCode: _lang.code);
    setState(() => _modelState = ModelState.ready);
    if (_strokes.isNotEmpty) _recognize();
  }

  void _switchLanguage(Language l) {
    if (l.code == _lang.code) return;
    setState(() {
      _lang = l;
      _results = [];
    });
    _prepareModel();
  }

  // ---------- pen input ----------

  bool _accepts(PointerEvent e) {
    if (e.kind == PointerDeviceKind.stylus ||
        e.kind == PointerDeviceKind.invertedStylus) {
      _sawStylus = true;
      return true;
    }
    return !(_penOnly && e.kind == PointerDeviceKind.touch);
  }

  double _widthFor(PointerEvent e) {
    final hasPressure =
        e.kind == PointerDeviceKind.stylus && e.pressureMax > e.pressureMin;
    if (!hasPressure) return _penWidth;
    final p = ((e.pressure - e.pressureMin) / (e.pressureMax - e.pressureMin))
        .clamp(0.0, 1.0);
    return _penWidth * (0.6 + p * 0.9);
  }

  void _down(PointerDownEvent e) {
    if (!_accepts(e)) return;
    _idle?.cancel();
    final s = StrokeData(_widthFor(e));
    s.points.add(_point(e));
    setState(() {
      _undo.add(List.of(_strokes));
      _strokes.add(s);
      _current = s;
    });
  }

  void _move(PointerMoveEvent e) {
    final s = _current;
    if (s == null) return;
    final p = _point(e);
    final last = s.points.last;
    if ((p.x - last.x).abs() + (p.y - last.y).abs() < 0.8) return;
    setState(() => s.points.add(p));
  }

  void _up(PointerEvent e) {
    if (_current == null) return;
    _current = null;
    if (_auto) {
      _idle?.cancel();
      _idle = Timer(const Duration(milliseconds: 900), _recognize);
    }
  }

  mlkit.StrokePoint _point(PointerEvent e) => mlkit.StrokePoint(
    x: e.localPosition.dx,
    y: e.localPosition.dy,
    t: DateTime.now().millisecondsSinceEpoch,
  );

  void _undoLast() {
    if (_undo.isEmpty) return;
    setState(() {
      _strokes
        ..clear()
        ..addAll(_undo.removeLast());
    });
    _recognize();
  }

  void _clear() {
    if (_strokes.isEmpty) return;
    setState(() {
      _undo.add(List.of(_strokes));
      _strokes.clear();
      _results = [];
      _lastTime = null;
    });
  }

  // ---------- recognition ----------

  Future<void> _recognize() async {
    final rec = _recognizer;
    if (rec == null || _modelState != ModelState.ready || _busy) return;
    if (_strokes.isEmpty) {
      setState(() => _results = []);
      return;
    }
    setState(() => _busy = true);
    final watch = Stopwatch()..start();
    final lines = groupIntoLines(_strokes);
    final previous = {for (final r in _results) r.line: r};
    final results = <LineResult>[];
    var preContext = '';
    for (var line = 0; line < lines.length; line++) {
      final group = lines[line];
      final box = group
          .map((s) => s.bounds)
          .reduce((a, b) => a.expandToInclude(b));
      final ink = mlkit.Ink()
        ..strokes = [
          for (final s in group) mlkit.Stroke()..points = List.of(s.points),
        ];
      try {
        final candidates = await rec.recognize(
          ink,
          context: mlkit.DigitalInkRecognitionContext(
            preContext: preContext,
            writingArea: mlkit.WritingArea(
              width: _canvasSize.width,
              height: math.max(box.height, kLineHeight),
            ),
          ),
        );
        final texts = [for (final c in candidates) c.text]
            .where((t) => t.trim().isNotEmpty)
            .take(5)
            .toList();
        final r = LineResult(line, texts, ruled: group.first.line);
        final old = previous[line];
        if (old != null &&
            old.text.isNotEmpty &&
            texts.contains(old.text) &&
            old.chosen != 0) {
          r.chosen = texts.indexOf(old.text);
        }
        results.add(r);
        final t = r.text;
        preContext = t.length > 20 ? t.substring(t.length - 20) : t;
      } catch (_) {
        results.add(LineResult(line, const [], ruled: group.first.line));
      }
    }
    watch.stop();
    if (!mounted) return;
    setState(() {
      _results = results;
      _busy = false;
      _lastTime = watch.elapsed;
    });
  }

  String get _fullText =>
      _results.map((r) => r.text).where((t) => t.isNotEmpty).join('\n');

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _fullText));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('تم نسخ النص')));
  }

  void _pickAlternative(LineResult r) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'اختر القراءة الصحيحة للسطر ${r.line + 1}',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            for (var i = 0; i < r.candidates.length; i++)
              ListTile(
                leading: Icon(
                  i == r.chosen
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: _accent,
                ),
                title: Text(
                  r.candidates[i],
                  style: const TextStyle(fontSize: 20),
                ),
                onTap: () {
                  setState(() => r.chosen = i);
                  Navigator.pop(ctx);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        titleSpacing: 20,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'FUTURENOTE',
              textDirection: TextDirection.ltr,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
                fontSize: 18,
              ),
            ),
            Text(
              'مختبر قراءة خط اليد',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                for (final l in languages)
                  ButtonSegment(value: l.code, label: Text(l.label)),
              ],
              selected: {_lang.code},
              onSelectionChanged: (s) => _switchLanguage(
                languages.firstWhere((l) => l.code == s.first),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 820;
            final page = _buildPage();
            final result = _buildResult();
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                children: [
                  _buildModelBanner(),
                  _buildToolbar(),
                  const SizedBox(height: 8),
                  Expanded(
                    child: wide
                        ? Row(
                            children: [
                              Expanded(flex: 3, child: page),
                              const SizedBox(width: 12),
                              Expanded(flex: 2, child: result),
                            ],
                          )
                        : Column(
                            children: [
                              Expanded(flex: 3, child: page),
                              const SizedBox(height: 10),
                              Expanded(flex: 2, child: result),
                            ],
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildModelBanner() {
    final (String? text, bool spinner, bool retry) = switch (_modelState) {
      ModelState.checking => ('جارٍ تجهيز محرك القراءة…', true, false),
      ModelState.missing || ModelState.downloading => (
        'جارٍ تحميل محرك ${_lang.label} (مرة واحدة، حوالي 20 ميجا)…',
        true,
        false,
      ),
      ModelState.failed => (
        'تعذّر تحميل محرك القراءة. تأكد من الاتصال بالإنترنت.',
        false,
        true,
      ),
      ModelState.ready => (null, false, false),
    };
    if (text == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _modelState == ModelState.failed
            ? const Color(0xFFFBEBEB)
            : const Color(0xFFE3ECE8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          if (spinner)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (spinner) const SizedBox(width: 12),
          Expanded(child: Text(text)),
          if (retry)
            TextButton(
              onPressed: _prepareModel,
              child: const Text('إعادة المحاولة'),
            ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        IconButton.filledTonal(
          onPressed: _undo.isEmpty ? null : _undoLast,
          icon: const Icon(Icons.undo),
          tooltip: 'تراجع',
        ),
        IconButton.filledTonal(
          onPressed: _strokes.isEmpty ? null : _clear,
          icon: const Icon(Icons.delete_outline),
          tooltip: 'مسح الصفحة',
        ),
        const SizedBox(width: 4),
        for (final w in [2.4, 3.2, 4.6])
          ChoiceChip(
            label: Container(
              width: 22,
              height: w * 1.6,
              decoration: BoxDecoration(
                color: _ink,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            selected: _penWidth == w,
            onSelected: (_) => setState(() => _penWidth = w),
          ),
        const SizedBox(width: 4),
        FilterChip(
          label: const Text('القلم فقط'),
          selected: _penOnly,
          onSelected: (v) => setState(() => _penOnly = v),
          tooltip: _sawStylus ? null : 'لتجاهل لمس اليد عند الكتابة بالقلم',
        ),
        FilterChip(
          label: const Text('تحويل تلقائي'),
          selected: _auto,
          onSelected: (v) => setState(() => _auto = v),
        ),
      ],
    );
  }

  Widget _buildPage() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _paper,
          border: Border.all(color: _rule),
          borderRadius: BorderRadius.circular(14),
        ),
        child: LayoutBuilder(
          builder: (context, c) {
            _canvasSize = c.biggest;
            return Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerUp: _up,
              onPointerCancel: _up,
              child: CustomPaint(
                size: c.biggest,
                painter: PagePainter(
                  _strokes,
                  _results.map((r) => r.ruled).toSet(),
                ),
                child: _strokes.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'اكتب هنا بالعربي، سطر في كل خط.\nالنص يظهر تحت تلقائيًا.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.black38,
                              fontSize: 16,
                              height: 1.8,
                            ),
                          ),
                        ),
                      )
                    : null,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildResult() {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: _rule),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'النص',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                if (_busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (!_busy && _lastTime != null)
                  Text(
                    '${_lastTime!.inMilliseconds} مللي ثانية',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black45,
                    ),
                  ),
                const Spacer(),
                if (!_auto)
                  FilledButton.icon(
                    onPressed:
                        _modelState == ModelState.ready && _strokes.isNotEmpty
                        ? _recognize
                        : null,
                    icon: const Icon(Icons.text_fields),
                    label: const Text('حوّل لنص'),
                  ),
                IconButton(
                  onPressed: _fullText.isEmpty ? null : _copy,
                  icon: const Icon(Icons.copy_rounded),
                  tooltip: 'نسخ',
                ),
              ],
            ),
            const Divider(height: 12),
            Expanded(
              child: _results.isEmpty
                  ? Center(
                      child: Text(
                        _strokes.isEmpty
                            ? 'لسه ما فيش كتابة'
                            : (_auto
                                  ? 'استنَّ ثانية بعد ما تخلص الكلمة'
                                  : 'اضغط «حوّل لنص»'),
                        style: const TextStyle(color: Colors.black38),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final r in _results)
                          InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: r.candidates.length > 1
                                ? () => _pickAlternative(r)
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 6,
                                horizontal: 4,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 22,
                                    child: Text(
                                      '${r.line + 1}',
                                      style: const TextStyle(
                                        color: Colors.black38,
                                        fontFeatures: [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      r.text.isEmpty ? '؟' : r.text,
                                      style: const TextStyle(
                                        fontSize: 22,
                                        height: 1.5,
                                        color: _ink,
                                      ),
                                    ),
                                  ),
                                  if (r.candidates.length > 1)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 6),
                                      child: Icon(
                                        Icons.unfold_more,
                                        size: 18,
                                        color: Colors.black38,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        if (_results.any((r) => r.candidates.length > 1))
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(
                              'لو كلمة غلط، اضغط على السطر واختار القراءة الصح.',
                              style: TextStyle(
                                color: Colors.black45,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class PagePainter extends CustomPainter {
  PagePainter(this.strokes, this.recognisedLines);
  final List<StrokeData> strokes;
  final Set<int> recognisedLines;

  @override
  void paint(Canvas canvas, Size size) {
    final rule = Paint()
      ..color = _rule
      ..strokeWidth = 1;
    final number = TextPainter(textDirection: TextDirection.ltr);
    for (
      var i = 0, y = kTopMargin + kLineHeight;
      y < size.height;
      i++, y += kLineHeight
    ) {
      canvas.drawLine(Offset(16, y), Offset(size.width - 16, y), rule);
      number.text = TextSpan(
        text: '${i + 1}',
        style: TextStyle(
          fontSize: 10,
          color: recognisedLines.contains(i)
              ? _accent
              : const Color(0xFFC9C5BA),
        ),
      );
      number.layout();
      number.paint(canvas, Offset(size.width - 14, y - 14));
    }

    for (final s in strokes) {
      final pts = s.points;
      final paint = Paint()
        ..color = _ink
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
      if (pts.length == 1) {
        canvas.drawCircle(
          Offset(pts.first.x, pts.first.y),
          s.width / 2,
          paint..style = PaintingStyle.fill,
        );
        continue;
      }
      final path = Path()..moveTo(pts.first.x, pts.first.y);
      for (var i = 1; i < pts.length - 1; i++) {
        final mid = Offset(
          (pts[i].x + pts[i + 1].x) / 2,
          (pts[i].y + pts[i + 1].y) / 2,
        );
        path.quadraticBezierTo(pts[i].x, pts[i].y, mid.dx, mid.dy);
      }
      path.lineTo(pts.last.x, pts.last.y);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant PagePainter old) => true;
}
