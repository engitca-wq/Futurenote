import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'models.dart';

enum PenMode { pen, highlighter, eraser }

/// Pen settings shared by every page of an open notebook.
class PenSettings extends ChangeNotifier {
  PenMode _mode = PenMode.pen;
  int _color = 0xFF1D1F22;
  double _width = 3.2;
  bool _penOnly = false;

  PenMode get mode => _mode;
  int get color => _color;
  double get width => _width;

  /// Ignore finger and palm touches once a stylus is in use.
  bool get penOnly => _penOnly;

  set mode(PenMode v) => _set(() => _mode = v);
  set color(int v) => _set(() {
    _color = v;
    if (_mode == PenMode.eraser) _mode = PenMode.pen;
  });
  set width(double v) => _set(() => _width = v);
  set penOnly(bool v) => _set(() => _penOnly = v);

  void _set(VoidCallback f) {
    f();
    notifyListeners();
  }

  static const inkColors = [0xFF1D1F22, 0xFF1F4FA3, 0xFFB3261E, 0xFF2F7D4F];
  static const highlightColor = 0x66F2C94C;
  static const widths = [2.2, 3.2, 5.0];
}

/// One page you can write on. Ink is kept in page coordinates
/// ([kPageWidth] x [kPageHeight]) and scaled to the widget's width.
class InkPageView extends StatefulWidget {
  const InkPageView({
    super.key,
    required this.page,
    required this.pen,
    required this.onChanged,
    this.onStrokeTap,
    this.litRange,
  });

  final NotePage page;
  final PenSettings pen;

  /// Called with the page's previous strokes after every edit, for undo.
  final void Function(List<InkStroke> before, List<TypedLine> typedBefore)
  onChanged;

  /// When set, a tap on ink reports the stroke instead of drawing a dot.
  final void Function(InkStroke stroke)? onStrokeTap;

  /// Strokes written inside this time range (epoch ms) are drawn in the
  /// accent colour, to show what was written up to the playing moment.
  final ({int from, int to})? litRange;

  @override
  State<InkPageView> createState() => _InkPageViewState();
}

class _InkPageViewState extends State<InkPageView> {
  final _live = ValueNotifier<InkStroke?>(null);
  List<InkStroke>? _before;
  List<TypedLine>? _typedBefore;
  double _scale = 1;
  bool _erasedAny = false;
  int? _pointer;

  @override
  void dispose() {
    _live.dispose();
    super.dispose();
  }

  bool _accepts(PointerEvent e) {
    if (_pointer != null) return false;
    if (e.kind == PointerDeviceKind.stylus ||
        e.kind == PointerDeviceKind.invertedStylus) {
      return true;
    }
    return !(widget.pen.penOnly && e.kind == PointerDeviceKind.touch);
  }

  InkPoint _toPage(PointerEvent e) {
    var p = 0.5;
    if (e.kind == PointerDeviceKind.stylus && e.pressureMax > e.pressureMin) {
      p = ((e.pressure - e.pressureMin) / (e.pressureMax - e.pressureMin))
          .clamp(0.0, 1.0);
    }
    return InkPoint(
      e.localPosition.dx / _scale,
      e.localPosition.dy / _scale,
      DateTime.now().millisecondsSinceEpoch,
      p,
    );
  }

  void _down(PointerDownEvent e) {
    if (!_accepts(e)) return;
    final pt = _toPage(e);
    if (widget.onStrokeTap != null) {
      // Listening mode: a tap plays the audio, it never draws.
      final hit = widget.page.strokes.reversed
          .where((s) => s.hits(Offset(pt.x, pt.y), 14))
          .firstOrNull;
      if (hit != null) widget.onStrokeTap!(hit);
      return;
    }
    _pointer = e.pointer;
    _before = List.of(widget.page.strokes);
    _typedBefore = widget.page.typed;
    final eraser =
        widget.pen.mode == PenMode.eraser ||
        e.kind == PointerDeviceKind.invertedStylus;
    if (eraser) {
      _erasedAny = false;
      _eraseAt(pt);
      return;
    }
    final highlighter = widget.pen.mode == PenMode.highlighter;
    _live.value = InkStroke(
      tool: highlighter ? InkTool.highlighter : InkTool.pen,
      color: highlighter ? PenSettings.highlightColor : widget.pen.color,
      width: highlighter ? 22 : widget.pen.width,
      points: [pt],
    );
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    final pt = _toPage(e);
    final s = _live.value;
    if (s == null) {
      _eraseAt(pt);
      return;
    }
    final last = s.points.last;
    if ((pt.x - last.x).abs() + (pt.y - last.y).abs() < 0.6) return;
    s.points.add(pt);
    s.invalidate();
    // Notify by reassigning so the live layer repaints.
    _live.value = null;
    _live.value = s;
  }

  void _up(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    final s = _live.value;
    _live.value = null;
    if (s != null) {
      setState(() => widget.page.strokes = [...widget.page.strokes, s]);
      widget.onChanged(_before!, _typedBefore!);
    } else if (_erasedAny) {
      widget.onChanged(_before!, _typedBefore!);
    }
    _before = null;
  }

  void _eraseAt(InkPoint pt) {
    final at = Offset(pt.x, pt.y);
    final keep = widget.page.strokes.where((s) => !s.hits(at, 10)).toList();
    if (keep.length != widget.page.strokes.length) {
      _erasedAny = true;
      setState(() => widget.page.strokes = keep);
    }
    final typed = widget.page.typed.where((t) => !t.box.contains(at)).toList();
    if (typed.length != widget.page.typed.length) {
      _erasedAny = true;
      setState(() => widget.page.typed = typed);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: kPageWidth / kPageHeight,
      child: LayoutBuilder(
        builder: (context, c) {
          _scale = c.maxWidth / kPageWidth;
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _up,
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                  child: CustomPaint(
                    painter: PagePainter(
                      page: widget.page,
                      scale: _scale,
                      litRange: widget.litRange,
                      accent: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                RepaintBoundary(
                  child: ValueListenableBuilder<InkStroke?>(
                    valueListenable: _live,
                    builder: (_, s, _) =>
                        CustomPaint(painter: _LivePainter(s, _scale)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class PagePainter extends CustomPainter {
  PagePainter({
    required this.page,
    required this.scale,
    this.litRange,
    required this.accent,
  }) : strokes = page.strokes,
       typed = page.typed,
       template = page.template;

  final NotePage page;
  final double scale;
  final List<InkStroke> strokes;
  final List<TypedLine> typed;
  final PageTemplate template;
  final ({int from, int to})? litRange;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFCFBF7),
    );
    paintTemplate(canvas, size, page.template, scale);
    for (final s in page.strokes) {
      final r = litRange;
      final t = s.points.isEmpty ? 0 : s.points.first.t;
      final lit =
          r != null && s.tool == InkTool.pen && t >= r.from && t <= r.to;
      paintStroke(canvas, s, scale, colorOverride: lit ? accent : null);
    }
    for (final t in page.typed) {
      paintTyped(canvas, t, scale);
    }
  }

  @override
  bool shouldRepaint(PagePainter old) =>
      old.page != page ||
      old.scale != scale ||
      old.strokes != strokes ||
      old.typed != typed ||
      old.template != template ||
      old.litRange != litRange;
}

class _LivePainter extends CustomPainter {
  _LivePainter(this.stroke, this.scale);
  final InkStroke? stroke;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    if (stroke != null) paintStroke(canvas, stroke!, scale);
  }

  @override
  bool shouldRepaint(_LivePainter old) => true;
}

void paintTyped(Canvas canvas, TypedLine t, double scale) {
  final rtl = t.rtl;
  final tp = TextPainter(
    text: TextSpan(
      text: t.text,
      style: TextStyle(
        color: Color(t.color),
        fontSize: (t.box.height * 0.62) * scale,
        height: 1.2,
      ),
    ),
    textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
    textAlign: rtl ? TextAlign.right : TextAlign.left,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: t.box.width * scale);
  final dx = rtl ? t.box.right * scale - tp.width : t.box.left * scale;
  final dy = (t.box.top + t.box.height / 2) * scale - tp.height / 2;
  tp.paint(canvas, Offset(dx, dy));
  tp.dispose();
}

void paintTemplate(Canvas canvas, Size size, PageTemplate t, double scale) {
  final line = Paint()
    ..color = const Color(0xFFE4E1D8)
    ..strokeWidth = math.max(1, scale);
  const gap = 56.0;
  switch (t) {
    case PageTemplate.lined:
      for (var y = 110.0; y < kPageHeight - 40; y += gap) {
        canvas.drawLine(
          Offset(40 * scale, y * scale),
          Offset((kPageWidth - 40) * scale, y * scale),
          line,
        );
      }
    case PageTemplate.grid:
      for (var y = gap; y < kPageHeight; y += gap / 1.4) {
        canvas.drawLine(
          Offset(0, y * scale),
          Offset(size.width, y * scale),
          line,
        );
      }
      for (var x = gap / 1.4; x < kPageWidth; x += gap / 1.4) {
        canvas.drawLine(
          Offset(x * scale, 0),
          Offset(x * scale, size.height),
          line,
        );
      }
    case PageTemplate.dots:
      final dot = Paint()..color = const Color(0xFFCFCBBF);
      for (var y = gap; y < kPageHeight; y += gap / 1.4) {
        for (var x = gap / 1.4; x < kPageWidth; x += gap / 1.4) {
          canvas.drawCircle(
            Offset(x * scale, y * scale),
            1.6 * scale + 0.4,
            dot,
          );
        }
      }
    case PageTemplate.blank:
      break;
  }
}

void paintStroke(
  Canvas canvas,
  InkStroke s,
  double scale, {
  Color? colorOverride,
}) {
  final pts = s.points;
  if (pts.isEmpty) return;
  final highlighter = s.tool == InkTool.highlighter;
  final color = colorOverride ?? Color(s.color);
  if (pts.length == 1) {
    canvas.drawCircle(
      Offset(pts.first.x * scale, pts.first.y * scale),
      s.width * scale / 2,
      Paint()..color = color,
    );
    return;
  }
  final paint = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeCap = highlighter ? StrokeCap.square : StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;
  if (highlighter) {
    paint
      ..strokeWidth = s.width * scale
      ..blendMode = BlendMode.multiply;
    canvas.drawPath(_smooth(pts, scale, 0, pts.length), paint);
    return;
  }
  // Vary the width with pressure by drawing short smoothed segments.
  const chunk = 6;
  for (var i = 0; i < pts.length - 1; i += chunk) {
    final end = math.min(pts.length, i + chunk + 1);
    var p = 0.0;
    for (var k = i; k < end; k++) {
      p += pts[k].pressure;
    }
    p /= end - i;
    paint.strokeWidth = s.width * (0.55 + p * 0.9) * scale;
    canvas.drawPath(_smooth(pts, scale, i, end), paint);
  }
}

Path _smooth(List<InkPoint> pts, double scale, int from, int to) {
  final path = Path()..moveTo(pts[from].x * scale, pts[from].y * scale);
  for (var i = from + 1; i < to - 1; i++) {
    final mx = (pts[i].x + pts[i + 1].x) / 2,
        my = (pts[i].y + pts[i + 1].y) / 2;
    path.quadraticBezierTo(
      pts[i].x * scale,
      pts[i].y * scale,
      mx * scale,
      my * scale,
    );
  }
  path.lineTo(pts[to - 1].x * scale, pts[to - 1].y * scale);
  return path;
}
