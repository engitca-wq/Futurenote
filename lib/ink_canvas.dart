import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'images.dart';
import 'models.dart';

enum PenMode { pen, highlighter, eraser, text, lasso, shape }

enum ShapeKind {
  line('خط', Icons.horizontal_rule),
  arrow('سهم', Icons.arrow_right_alt),
  rect('مستطيل', Icons.crop_square),
  ellipse('دايرة', Icons.circle_outlined);

  const ShapeKind(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Pen settings shared by every page of an open notebook.
class PenSettings extends ChangeNotifier {
  PenMode _mode = PenMode.pen;
  int _color = 0xFF1D1F22;
  double _width = 3.2;
  bool _penOnly = false;
  ShapeKind _shape = ShapeKind.rect;

  PenMode get mode => _mode;
  int get color => _color;
  double get width => _width;
  ShapeKind get shape => _shape;

  /// Ignore finger and palm touches once a stylus is in use.
  bool get penOnly => _penOnly;

  set mode(PenMode v) => _set(() => _mode = v);
  set color(int v) => _set(() {
    _color = v;
    if (_mode == PenMode.eraser || _mode == PenMode.lasso) _mode = PenMode.pen;
  });
  set width(double v) => _set(() => _width = v);
  set penOnly(bool v) => _set(() => _penOnly = v);
  set shape(ShapeKind v) => _set(() {
    _shape = v;
    _mode = PenMode.shape;
  });

  void _set(VoidCallback f) {
    f();
    notifyListeners();
  }

  static const inkColors = [0xFF1D1F22, 0xFF1F4FA3, 0xFFB3261E, 0xFF2F7D4F];
  static const highlightColor = 0x66F2C94C;
  static const widths = [2.2, 3.2, 5.0];
}

/// What the lasso picked on a page, and the edits you can make to it. Every
/// edit replaces the page's lists and returns the content before it, for undo.
class Selection extends ChangeNotifier {
  NotePage? page;
  final _strokes = Set<InkStroke>.identity();
  final _typed = Set<TypedLine>.identity();
  final _images = Set<PageImage>.identity();
  Rect? box;

  /// Copied content, shared between pages and notebooks.
  static PageContent? clipboard;

  bool get active => page != null && box != null;

  void clear() {
    if (page == null && box == null) return;
    page = null;
    box = null;
    _strokes.clear();
    _typed.clear();
    _images.clear();
    notifyListeners();
  }

  /// Selects what lies inside [polygon] on [p]. Returns true if anything did.
  bool select(NotePage p, List<Offset> polygon) {
    clear();
    if (polygon.length < 3) return false;
    for (final s in p.strokes) {
      if (s.points.isEmpty) continue;
      final inside = s.points
          .where((q) => _inPolygon(Offset(q.x, q.y), polygon))
          .length;
      if (inside >= s.points.length * 0.6) _strokes.add(s);
    }
    _typed.addAll(p.typed.where((t) => _inPolygon(t.box.center, polygon)));
    _images.addAll(p.images.where((i) => _inPolygon(i.box.center, polygon)));
    if (_strokes.isEmpty && _typed.isEmpty && _images.isEmpty) return false;
    page = p;
    _refreshBox();
    notifyListeners();
    return true;
  }

  void _refreshBox() {
    Rect? b;
    for (final r in [
      ..._strokes.map((s) => s.bounds.inflate(s.width)),
      ..._typed.map((t) => t.box),
      ..._images.map((i) => i.box),
    ]) {
      b = b == null ? r : b.expandToInclude(r);
    }
    box = b;
  }

  /// Moves by [d] and scales by [k] around the box's top-left corner.
  void transform(Offset d, {double k = 1}) {
    final p = page;
    final b = box;
    if (p == null || b == null) return;
    final o = b.topLeft;
    final ns = <InkStroke>[], nt = <TypedLine>[], ni = <PageImage>[];
    p.strokes = [
      for (final s in p.strokes)
        if (_strokes.contains(s))
          (ns..add(s.transformed(d, k: k, origin: o))).last
        else
          s,
    ];
    p.typed = [
      for (final t in p.typed)
        if (_typed.contains(t))
          (nt..add(
                t.copyWith(
                  box: transformRect(t.box, d, k: k, origin: o),
                ),
              ))
              .last
        else
          t,
    ];
    p.images = [
      for (final i in p.images)
        if (_images.contains(i))
          (ni..add(
                i.copyWith(
                  box: transformRect(i.box, d, k: k, origin: o),
                ),
              ))
              .last
        else
          i,
    ];
    _strokes
      ..clear()
      ..addAll(ns);
    _typed
      ..clear()
      ..addAll(nt);
    _images
      ..clear()
      ..addAll(ni);
    box = transformRect(b, d, k: k, origin: o);
    notifyListeners();
  }

  PageContent? delete() {
    final p = page;
    if (p == null) return null;
    final before = p.content;
    p.strokes = [
      for (final s in p.strokes)
        if (!_strokes.contains(s)) s,
    ];
    p.typed = [
      for (final t in p.typed)
        if (!_typed.contains(t)) t,
    ];
    p.images = [
      for (final i in p.images)
        if (!_images.contains(i)) i,
    ];
    clear();
    return before;
  }

  void copy() {
    clipboard = PageContent(
      List.of(_strokes),
      List.of(_typed),
      List.of(_images),
    );
  }

  /// Pastes [content] onto [p], shifted by [d], and selects the pasted items.
  PageContent paste(NotePage p, PageContent content, Offset d) {
    final before = p.content;
    final ns = [for (final s in content.strokes) s.transformed(d)];
    final nt = [for (final t in content.typed) t.copyWith(box: t.box.shift(d))];
    final ni = [
      for (final i in content.images) i.copyWith(box: i.box.shift(d)),
    ];
    p.strokes = [...p.strokes, ...ns];
    p.typed = [...p.typed, ...nt];
    p.images = [...p.images, ...ni];
    clear();
    page = p;
    _strokes.addAll(ns);
    _typed.addAll(nt);
    _images.addAll(ni);
    _refreshBox();
    notifyListeners();
    return before;
  }

  /// Copies and pastes in place, slightly offset.
  PageContent? duplicate() {
    final p = page;
    if (p == null) return null;
    copy();
    return paste(p, clipboard!, const Offset(30, 30));
  }
}

bool _inPolygon(Offset p, List<Offset> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) &&
        p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

/// Points of a shape drawn from [a] to [b], as an ordinary pen stroke.
List<InkPoint> shapePoints(ShapeKind kind, Offset a, Offset b, int t) {
  InkPoint p(double x, double y) => InkPoint(x, y, t);
  List<InkPoint> segment(Offset from, Offset to) {
    final n = math.max(2, ((to - from).distance / 8).ceil());
    return [
      for (var i = 0; i <= n; i++)
        p(
          from.dx + (to.dx - from.dx) * i / n,
          from.dy + (to.dy - from.dy) * i / n,
        ),
    ];
  }

  switch (kind) {
    case ShapeKind.line:
      return segment(a, b);
    case ShapeKind.arrow:
      // The head is drawn as part of the same stroke: shaft, then barbs.
      final dir = b - a;
      final len = dir.distance;
      if (len < 1) return segment(a, b);
      final u = dir / len;
      final head = math.min(36.0, len * 0.35);
      final left = b - u * head + Offset(-u.dy, u.dx) * head * 0.55;
      final right = b - u * head - Offset(-u.dy, u.dx) * head * 0.55;
      return [
        ...segment(a, b),
        ...segment(b, left),
        ...segment(left, b),
        ...segment(b, right),
      ];
    case ShapeKind.rect:
      final r = Rect.fromPoints(a, b);
      return [
        ...segment(r.topLeft, r.topRight),
        ...segment(r.topRight, r.bottomRight),
        ...segment(r.bottomRight, r.bottomLeft),
        ...segment(r.bottomLeft, r.topLeft),
      ];
    case ShapeKind.ellipse:
      final r = Rect.fromPoints(a, b);
      const n = 72;
      return [
        for (var i = 0; i <= n; i++)
          p(
            r.center.dx + r.width / 2 * math.cos(2 * math.pi * i / n),
            r.center.dy + r.height / 2 * math.sin(2 * math.pi * i / n),
          ),
      ];
  }
}

/// One page you can write on. Ink is kept in page coordinates
/// ([kPageWidth] x [kPageHeight]) and scaled to the widget's width.
class InkPageView extends StatefulWidget {
  const InkPageView({
    super.key,
    required this.page,
    required this.pen,
    required this.selection,
    required this.onChanged,
    this.onStrokeTap,
    this.onTextTap,
    this.litRange,
  });

  final NotePage page;
  final PenSettings pen;
  final Selection selection;

  /// Called with the page's previous content after every edit, for undo.
  final void Function(PageContent before) onChanged;

  /// When set, a tap on ink reports the stroke instead of drawing.
  final void Function(InkStroke stroke)? onStrokeTap;

  /// Text mode: a tap reports the page point and the typed line under it.
  final void Function(Offset at, TypedLine? hit)? onTextTap;

  /// Strokes written inside this time range (epoch ms) are drawn in the
  /// accent colour, to show what was written up to the playing moment.
  final ({int from, int to})? litRange;

  @override
  State<InkPageView> createState() => _InkPageViewState();
}

enum _Drag { none, draw, erase, lasso, move, scale, shape }

class _InkPageViewState extends State<InkPageView> {
  final _live = ValueNotifier<InkStroke?>(null);
  final _lassoPath = ValueNotifier<List<Offset>>(const []);
  PageContent? _before;
  double _scale = 1;
  bool _erasedAny = false;
  int? _pointer;
  _Drag _drag = _Drag.none;
  Offset _last = Offset.zero;
  Offset _shapeStart = Offset.zero;

  Selection get sel => widget.selection;

  @override
  void dispose() {
    _live.dispose();
    _lassoPath.dispose();
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

  /// The resize handle sits on the selection's bottom corner.
  Offset? get _handle => sel.box?.bottomRight;

  void _down(PointerDownEvent e) {
    if (!_accepts(e)) return;
    final pt = _toPage(e);
    final at = Offset(pt.x, pt.y);
    if (widget.onStrokeTap != null) {
      // Listening mode: a tap plays the audio, it never draws.
      final hit = widget.page.strokes.reversed
          .where((s) => s.hits(at, 14))
          .firstOrNull;
      if (hit != null) widget.onStrokeTap!(hit);
      return;
    }
    final mode = widget.pen.mode;
    final inverted = e.kind == PointerDeviceKind.invertedStylus;
    if (mode == PenMode.text && !inverted) {
      final hit = widget.page.typed.reversed
          .where((t) => t.box.inflate(6).contains(at))
          .firstOrNull;
      widget.onTextTap?.call(at, hit);
      return;
    }
    _pointer = e.pointer;
    _before = widget.page.content;
    _last = at;
    if (mode == PenMode.lasso && !inverted) {
      final h = _handle;
      if (sel.active && h != null && (at - h).distance < 40) {
        _drag = _Drag.scale;
      } else if (sel.active && sel.box!.inflate(10).contains(at)) {
        _drag = _Drag.move;
      } else {
        sel.clear();
        _drag = _Drag.lasso;
        _lassoPath.value = [at];
      }
      return;
    }
    sel.clear();
    if (mode == PenMode.eraser || inverted) {
      _drag = _Drag.erase;
      _erasedAny = false;
      _eraseAt(at);
      return;
    }
    if (mode == PenMode.shape) {
      _drag = _Drag.shape;
      _shapeStart = at;
      _live.value = InkStroke(
        tool: InkTool.pen,
        color: widget.pen.color,
        width: widget.pen.width,
        points: [pt],
      );
      return;
    }
    _drag = _Drag.draw;
    final highlighter = mode == PenMode.highlighter;
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
    final at = Offset(pt.x, pt.y);
    switch (_drag) {
      case _Drag.erase:
        _eraseAt(at);
      case _Drag.lasso:
        _lassoPath.value = [..._lassoPath.value, at];
      case _Drag.move:
        sel.transform(at - _last);
        setState(() {});
      case _Drag.scale:
        final b = sel.box!;
        final w = b.width + (at - _last).dx;
        final k = (w / b.width).clamp(0.2, 5.0);
        if (b.width * k > 20) sel.transform(Offset.zero, k: k);
        setState(() {});
      case _Drag.shape:
        _live.value = InkStroke(
          tool: InkTool.pen,
          color: widget.pen.color,
          width: widget.pen.width,
          points: shapePoints(widget.pen.shape, _shapeStart, at, pt.t),
        );
      case _Drag.draw:
        final s = _live.value!;
        final last = s.points.last;
        if ((pt.x - last.x).abs() + (pt.y - last.y).abs() < 0.6) return;
        s.points.add(pt);
        s.invalidate();
        // Notify by reassigning so the live layer repaints.
        _live.value = null;
        _live.value = s;
      case _Drag.none:
        break;
    }
    _last = at;
  }

  void _up(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    final before = _before!;
    switch (_drag) {
      case _Drag.draw || _Drag.shape:
        final s = _live.value;
        _live.value = null;
        if (s != null && (s.points.length > 1 || _drag == _Drag.draw)) {
          setState(() => widget.page.strokes = [...widget.page.strokes, s]);
          widget.onChanged(before);
        }
      case _Drag.erase:
        if (_erasedAny) widget.onChanged(before);
      case _Drag.lasso:
        sel.select(widget.page, _lassoPath.value);
        _lassoPath.value = const [];
      case _Drag.move || _Drag.scale:
        widget.onChanged(before);
      case _Drag.none:
        break;
    }
    _drag = _Drag.none;
    _before = null;
  }

  void _eraseAt(Offset at) {
    final p = widget.page;
    final keep = p.strokes.where((s) => !s.hits(at, 10)).toList();
    final typed = p.typed.where((t) => !t.box.contains(at)).toList();
    final images = p.images.where((i) => !i.box.contains(at)).toList();
    if (keep.length != p.strokes.length ||
        typed.length != p.typed.length ||
        images.length != p.images.length) {
      _erasedAny = true;
      setState(() => p.content = PageContent(keep, typed, images));
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
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
                  child: ListenableBuilder(
                    listenable: sel,
                    builder: (context, _) => CustomPaint(
                      painter: PagePainter(
                        page: widget.page,
                        scale: _scale,
                        litRange: widget.litRange,
                        accent: accent,
                      ),
                    ),
                  ),
                ),
                RepaintBoundary(
                  child: ListenableBuilder(
                    listenable: Listenable.merge([_live, _lassoPath, sel]),
                    builder: (_, _) => CustomPaint(
                      painter: _LivePainter(
                        _live.value,
                        _lassoPath.value,
                        sel.page == widget.page ? sel.box : null,
                        _scale,
                        accent,
                      ),
                    ),
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
    this.background = true,
  }) : strokes = page.strokes,
       typed = page.typed,
       images = page.images,
       template = page.template,
       super(repaint: ImageStore.instance.version);

  final NotePage page;
  final double scale;
  final List<InkStroke> strokes;
  final List<TypedLine> typed;
  final List<PageImage> images;
  final PageTemplate template;
  final ({int from, int to})? litRange;
  final Color accent;
  final bool background;

  @override
  void paint(Canvas canvas, Size size) {
    if (background) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = const Color(0xFFFCFBF7),
      );
    }
    paintTemplate(canvas, size, page.template, scale);
    for (final i in page.images) {
      paintImage(canvas, i, scale);
    }
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
      old.images != images ||
      old.template != template ||
      old.litRange != litRange;
}

class _LivePainter extends CustomPainter {
  _LivePainter(this.stroke, this.lasso, this.box, this.scale, this.accent);
  final InkStroke? stroke;
  final List<Offset> lasso;
  final Rect? box;
  final double scale;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    if (stroke != null) paintStroke(canvas, stroke!, scale);
    final dash = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    if (lasso.length > 1) {
      final path = Path()
        ..moveTo(lasso.first.dx * scale, lasso.first.dy * scale);
      for (final p in lasso.skip(1)) {
        path.lineTo(p.dx * scale, p.dy * scale);
      }
      canvas.drawPath(path, dash);
    }
    final b = box;
    if (b != null) {
      final r = Rect.fromLTRB(
        b.left * scale,
        b.top * scale,
        b.right * scale,
        b.bottom * scale,
      );
      canvas.drawRect(r, Paint()..color = accent.withValues(alpha: 0.06));
      canvas.drawRect(r, dash);
      canvas.drawCircle(r.bottomRight, 11, Paint()..color = accent);
      canvas.drawCircle(
        r.bottomRight,
        5,
        Paint()..color = const Color(0xFFFFFFFF),
      );
    }
  }

  @override
  bool shouldRepaint(_LivePainter old) => true;
}

void paintImage(Canvas canvas, PageImage i, double scale) {
  final dst = Rect.fromLTRB(
    i.box.left * scale,
    i.box.top * scale,
    i.box.right * scale,
    i.box.bottom * scale,
  );
  final img = ImageStore.instance.get(i.file);
  if (img == null) {
    canvas.drawRect(dst, Paint()..color = const Color(0x11000000));
    return;
  }
  canvas.drawImageRect(
    img,
    Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
    dst,
    Paint()..filterQuality = ui.FilterQuality.medium,
  );
}

void paintTyped(Canvas canvas, TypedLine t, double scale) {
  final rtl = t.rtl;
  final color = Color(t.color).withValues(alpha: t.done ? 0.45 : 1);
  var box = t.box;
  if (t.todo) {
    // Check box at the start of the line: right side for Arabic.
    final side = t.box.height * 0.5;
    final bx = rtl ? t.box.right - side : t.box.left;
    final r = Rect.fromLTWH(
      bx * scale,
      (t.box.center.dy - side / 2) * scale,
      side * scale,
      side * scale,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, Radius.circular(4 * scale)),
      Paint()
        ..color = Color(t.color)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * scale,
    );
    if (t.done) {
      final tick = Path()
        ..moveTo(r.left + r.width * 0.2, r.top + r.height * 0.55)
        ..lineTo(r.left + r.width * 0.42, r.top + r.height * 0.78)
        ..lineTo(r.left + r.width * 0.82, r.top + r.height * 0.25);
      canvas.drawPath(
        tick,
        Paint()
          ..color = Color(t.color)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 * scale
          ..strokeCap = StrokeCap.round,
      );
    }
    final gap = side + 12;
    box = rtl
        ? Rect.fromLTRB(t.box.left, t.box.top, t.box.right - gap, t.box.bottom)
        : Rect.fromLTRB(t.box.left + gap, t.box.top, t.box.right, t.box.bottom);
  }
  final tp = TextPainter(
    text: TextSpan(
      text: t.text,
      style: TextStyle(
        color: color,
        fontSize: (t.box.height * 0.62) * scale,
        height: 1.2,
        decoration: t.done ? TextDecoration.lineThrough : null,
      ),
    ),
    textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
    textAlign: rtl ? TextAlign.right : TextAlign.left,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: math.max(1, box.width * scale));
  final dx = rtl ? box.right * scale - tp.width : box.left * scale;
  final dy = (box.top + box.height / 2) * scale - tp.height / 2;
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
