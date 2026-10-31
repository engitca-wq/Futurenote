import 'dart:math' as math;
import 'dart:ui';

/// Pages are stored in a fixed coordinate space (A4 proportions), so ink
/// keeps its place whatever the screen size or orientation.
const double kPageWidth = 1000;
const double kPageHeight = 1414;

enum InkTool { pen, highlighter }

enum PageTemplate {
  lined('مسطّر'),
  grid('مربعات'),
  dots('نقاط'),
  blank('فارغ');

  const PageTemplate(this.label);
  final String label;

  static PageTemplate byName(String? name) => PageTemplate.values.firstWhere(
    (t) => t.name == name,
    orElse: () => PageTemplate.lined,
  );
}

class InkPoint {
  const InkPoint(this.x, this.y, this.t, [this.pressure = 0.5]);
  final double x;
  final double y;

  /// Milliseconds since epoch, used by handwriting recognition and to link
  /// ink to the moment of a recording.
  final int t;
  final double pressure;
}

class InkStroke {
  InkStroke({
    required this.tool,
    required this.color,
    required this.width,
    List<InkPoint>? points,
  }) : points = points ?? [];

  final InkTool tool;
  final int color;
  final double width;
  final List<InkPoint> points;

  Rect? _bounds;
  Rect get bounds {
    if (_bounds != null) return _bounds!;
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
    return _bounds = Rect.fromLTRB(l, t, r, b);
  }

  /// Call after adding points while the stroke is being drawn.
  void invalidate() => _bounds = null;

  bool hits(Offset at, double radius) {
    if (!bounds.inflate(radius + width).contains(at)) return false;
    final r2 = (radius + width / 2) * (radius + width / 2);
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      if ((p.x - at.dx) * (p.x - at.dx) + (p.y - at.dy) * (p.y - at.dy) <= r2) {
        return true;
      }
      if (i > 0 && _segmentDistance2(points[i - 1], p, at) <= r2) return true;
    }
    return false;
  }

  static double _segmentDistance2(InkPoint a, InkPoint b, Offset p) {
    final dx = b.x - a.x, dy = b.y - a.y;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0 ? 0.0 : ((p.dx - a.x) * dx + (p.dy - a.y) * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final x = a.x + t * dx - p.dx, y = a.y + t * dy - p.dy;
    return x * x + y * y;
  }

  Map<String, dynamic> toJson() => {
    'tool': tool.name,
    'color': color,
    'width': width,
    // Flat list keeps files small: x, y, t, pressure for each point.
    'p': [
      for (final p in points) ...[
        (p.x * 10).round() / 10,
        (p.y * 10).round() / 10,
        p.t,
        (p.pressure * 100).round() / 100,
      ],
    ],
  };

  factory InkStroke.fromJson(Map<String, dynamic> j) {
    final flat = (j['p'] as List).cast<num>();
    return InkStroke(
      tool: InkTool.values.firstWhere(
        (t) => t.name == j['tool'],
        orElse: () => InkTool.pen,
      ),
      color: j['color'] as int,
      width: (j['width'] as num).toDouble(),
      points: [
        for (var i = 0; i + 3 < flat.length; i += 4)
          InkPoint(
            flat[i].toDouble(),
            flat[i + 1].toDouble(),
            flat[i + 2].toInt(),
            flat[i + 3].toDouble(),
          ),
      ],
    );
  }
}

class NotePage {
  NotePage({
    required this.id,
    required this.template,
    List<InkStroke>? strokes,
    this.text,
  }) : strokes = strokes ?? [];

  final String id;
  PageTemplate template;
  List<InkStroke> strokes;

  /// Last handwriting-to-text result for this page.
  String? text;

  Map<String, dynamic> toJson() => {
    'id': id,
    'template': template.name,
    'strokes': [for (final s in strokes) s.toJson()],
    if (text != null) 'text': text,
  };

  factory NotePage.fromJson(Map<String, dynamic> j) => NotePage(
    id: j['id'] as String,
    template: PageTemplate.byName(j['template'] as String?),
    strokes: [
      for (final s in (j['strokes'] as List? ?? []))
        InkStroke.fromJson(s as Map<String, dynamic>),
    ],
    text: j['text'] as String?,
  );
}

class Recording {
  Recording({
    required this.id,
    required this.file,
    required this.started,
    required this.duration,
    this.transcript = const [],
  });

  final String id;

  /// File name inside the notebook's audio folder.
  final String file;
  final DateTime started;
  final Duration duration;

  /// Transcript pieces with the time they were spoken.
  final List<TranscriptPiece> transcript;

  Map<String, dynamic> toJson() => {
    'id': id,
    'file': file,
    'started': started.millisecondsSinceEpoch,
    'ms': duration.inMilliseconds,
    'transcript': [for (final p in transcript) p.toJson()],
  };

  factory Recording.fromJson(Map<String, dynamic> j) => Recording(
    id: j['id'] as String,
    file: j['file'] as String,
    started: DateTime.fromMillisecondsSinceEpoch(j['started'] as int),
    duration: Duration(milliseconds: j['ms'] as int),
    transcript: [
      for (final p in (j['transcript'] as List? ?? []))
        TranscriptPiece.fromJson(p as Map<String, dynamic>),
    ],
  );
}

class TranscriptPiece {
  const TranscriptPiece(this.at, this.text);

  /// Offset from the start of the recording.
  final Duration at;
  final String text;

  Map<String, dynamic> toJson() => {'at': at.inMilliseconds, 'text': text};

  factory TranscriptPiece.fromJson(Map<String, dynamic> j) => TranscriptPiece(
    Duration(milliseconds: j['at'] as int),
    j['text'] as String,
  );
}

class Notebook {
  Notebook({
    required this.id,
    required this.title,
    required this.cover,
    required this.template,
    required this.created,
    required this.updated,
    List<NotePage>? pages,
    List<Recording>? recordings,
  }) : pages = pages ?? [],
       recordings = recordings ?? [];

  final String id;
  String title;
  int cover;
  PageTemplate template;
  final DateTime created;
  DateTime updated;
  final List<NotePage> pages;
  final List<Recording> recordings;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'cover': cover,
    'template': template.name,
    'created': created.millisecondsSinceEpoch,
    'updated': updated.millisecondsSinceEpoch,
    'pages': [for (final p in pages) p.toJson()],
    'recordings': [for (final r in recordings) r.toJson()],
  };

  factory Notebook.fromJson(Map<String, dynamic> j) => Notebook(
    id: j['id'] as String,
    title: j['title'] as String,
    cover: j['cover'] as int,
    template: PageTemplate.byName(j['template'] as String?),
    created: DateTime.fromMillisecondsSinceEpoch(j['created'] as int),
    updated: DateTime.fromMillisecondsSinceEpoch(j['updated'] as int),
    pages: [
      for (final p in (j['pages'] as List? ?? []))
        NotePage.fromJson(p as Map<String, dynamic>),
    ],
    recordings: [
      for (final r in (j['recordings'] as List? ?? []))
        Recording.fromJson(r as Map<String, dynamic>),
    ],
  );
}

String newId() =>
    DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
    math.Random().nextInt(1 << 20).toRadixString(36);
