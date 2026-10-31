import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as mlkit;

import '../ink_canvas.dart';
import '../models.dart';
import '../recognition.dart';
import '../recorder.dart';
import '../store.dart';

/// One open notebook: write on pages, convert them to text, and record.
class NotebookScreen extends StatefulWidget {
  const NotebookScreen({
    super.key,
    required this.store,
    required this.book,
    required this.recorder,
  });

  final NotebookStore store;
  final Notebook book;
  final NoteRecorder recorder;

  @override
  State<NotebookScreen> createState() => _NotebookScreenState();
}

class _NotebookScreenState extends State<NotebookScreen> {
  final pen = PenSettings();
  late final player = NotePlayer(widget.store);
  final Map<String, List<_Snapshot>> _undo = {};
  final Map<String, List<_Snapshot>> _redo = {};
  int _index = 0;
  bool _listenMode = false;

  Notebook get book => widget.book;
  NotePage get page => book.pages[_index];
  NoteRecorder get recorder => widget.recorder;

  @override
  void initState() {
    super.initState();
    if (book.pages.isEmpty) {
      book.pages.add(NotePage(id: newId(), template: book.template));
    }
    _index = book.pages.length - 1;
    recorder.addListener(_onRecorder);
    player.addListener(_onPlayer);
  }

  @override
  void dispose() {
    recorder.removeListener(_onRecorder);
    pen.dispose();
    player.dispose();
    widget.store.flush();
    super.dispose();
  }

  void _onPlayer() {
    final e = player.error;
    if (e != null && mounted) {
      player.error = null;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e)));
    }
  }

  void _onRecorder() {
    if (mounted) setState(() {});
    if (recorder.error != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(recorder.error!)));
      recorder.error = null;
    }
  }

  _Snapshot get _now => (strokes: page.strokes, typed: page.typed);

  void _restore(_Snapshot s) {
    page.strokes = s.strokes;
    page.typed = s.typed;
  }

  void _changed(List<InkStroke> before, List<TypedLine> typedBefore) {
    (_undo[page.id] ??= []).add((strokes: before, typed: typedBefore));
    if (_undo[page.id]!.length > 100) _undo[page.id]!.removeAt(0);
    _redo[page.id]?.clear();
    widget.store.changed(book);
    setState(() {});
  }

  bool get _canUndo => _undo[page.id]?.isNotEmpty ?? false;
  bool get _canRedo => _redo[page.id]?.isNotEmpty ?? false;

  void _undoStep() {
    if (!_canUndo) return;
    (_redo[page.id] ??= []).add(_now);
    setState(() => _restore(_undo[page.id]!.removeLast()));
    widget.store.changed(book);
  }

  void _redoStep() {
    if (!_canRedo) return;
    (_undo[page.id] ??= []).add(_now);
    setState(() => _restore(_redo[page.id]!.removeLast()));
    widget.store.changed(book);
  }

  void _goTo(int i) {
    if (i < 0 || i >= book.pages.length) return;
    setState(() => _index = i);
  }

  void _addPage() {
    setState(() {
      book.pages.insert(
        _index + 1,
        NotePage(id: newId(), template: page.template),
      );
      _index++;
    });
    widget.store.changed(book, immediate: true);
  }

  Future<void> _deletePage() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف الصفحة؟'),
        content: Text('هتتحذف الصفحة ${_index + 1} بكل اللي مكتوب فيها.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _undo.remove(page.id);
      _redo.remove(page.id);
      book.pages.removeAt(_index);
      if (book.pages.isEmpty) {
        book.pages.add(NotePage(id: newId(), template: book.template));
      }
      _index = _index.clamp(0, book.pages.length - 1);
    });
    widget.store.changed(book, immediate: true);
  }

  Future<void> _rename() async {
    final c = TextEditingController(text: book.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('اسم الدفتر'),
        content: TextField(
          controller: c,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    c.dispose();
    if (title == null || title.trim().isEmpty) return;
    setState(() => book.title = title.trim());
    widget.store.changed(book, immediate: true);
  }

  void _setTemplate(PageTemplate t) {
    setState(() => page.template = t);
    widget.store.changed(book);
  }

  // ---- Recording ----

  Future<void> _record() async {
    if (recorder.recording) {
      await _stopRecording();
      return;
    }
    final mode = await showModalBottomSheet<RecordMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in RecordMode.values)
              ListTile(
                leading: Icon(
                  m == RecordMode.audio ? Icons.mic : Icons.subtitles_outlined,
                ),
                title: Text(m.label),
                subtitle: Text(m.hint),
                onTap: () => Navigator.pop(context, m),
              ),
          ],
        ),
      ),
    );
    if (mode == null) return;
    await player.stop();
    await recorder.start(book, mode);
  }

  Future<void> _stopRecording() async {
    final wasLive = recorder.mode == RecordMode.live;
    final rec = await recorder.stop();
    if (!mounted || rec == null) return;
    if (rec.transcript.isNotEmpty) {
      _recordings();
    } else if (wasLive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'ما اتفهمش أي كلام. اتكلم قريب من الموبايل، واتأكد إن النت شغال.',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'اتحفظ التسجيل. اضغط زرار الإيد وبعدين أي كلمة كتبتها عشان تسمع.',
          ),
        ),
      );
    }
  }

  Future<void> _onStrokeTap(InkStroke s) async {
    if (s.points.isEmpty) return;
    final ok = await player.playAt(book, s.points.first.t);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('الجزء ده اتكتب من غير تسجيل صوتي')),
        );
    }
  }

  void _recordings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) =>
          _RecordingsSheet(book: book, store: widget.store, player: player),
    );
  }

  // ---- Handwriting to text ----

  void _convert() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _TextSheet(page: page, onInsert: _insertText),
    );
  }

  /// Puts typed lines under the handwriting, on the ruled lines, keeping the
  /// ink as it is. Continues on a new page when there is no room left.
  void _insertText(List<String> lines) {
    if (lines.isEmpty) return;
    const rule = 56.0, firstRule = 110.0, h = 50.0;
    var target = page;
    var bottom = 0.0;
    for (final s in target.strokes) {
      if (s.points.isNotEmpty && s.bounds.bottom > bottom) {
        bottom = s.bounds.bottom;
      }
    }
    for (final t in target.typed) {
      bottom = bottom > t.box.bottom ? bottom : t.box.bottom;
    }
    var y = firstRule;
    while (y - h < bottom + 12) {
      y += rule;
    }
    final placed = <TypedLine>[];
    final overflow = <String>[];
    for (final text in lines) {
      if (y > kPageHeight - 40) {
        overflow.add(text);
        continue;
      }
      placed.add(
        TypedLine(
          box: Rect.fromLTWH(60, y - h, kPageWidth - 120, h),
          text: text,
        ),
      );
      y += rule;
    }
    (_undo[target.id] ??= []).add(_now);
    _redo[target.id]?.clear();
    setState(() {
      target.typed = [...target.typed, ...placed];
      target.text = lines.join('\n');
      if (overflow.isNotEmpty) {
        final next = NotePage(id: newId(), template: target.template);
        next.typed = [
          for (var i = 0; i < overflow.length; i++)
            TypedLine(
              box: Rect.fromLTWH(
                60,
                firstRule + i * rule - h,
                kPageWidth - 120,
                h,
              ),
              text: overflow[i],
            ),
        ];
        book.pages.insert(_index + 1, next);
      }
    });
    widget.store.changed(book, immediate: true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          overflow.isEmpty
              ? 'اتحط النص تحت الكتابة. زرار التراجع يشيله.'
              : 'اتحط النص تحت الكتابة، والباقي في صفحة جديدة بعدها.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surfaceContainerLow,
      appBar: AppBar(
        title: GestureDetector(
          onTap: _rename,
          child: Text(book.title, overflow: TextOverflow.ellipsis),
        ),
        actions: [
          IconButton(
            tooltip: 'تراجع',
            icon: const Icon(Icons.undo),
            onPressed: _canUndo ? _undoStep : null,
          ),
          IconButton(
            tooltip: 'إعادة',
            icon: const Icon(Icons.redo),
            onPressed: _canRedo ? _redoStep : null,
          ),
          IconButton(
            tooltip: 'تحويل لنص',
            icon: const Icon(Icons.text_fields),
            onPressed: _convert,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'recs':
                  _recordings();
                case 'add':
                  _addPage();
                case 'del':
                  _deletePage();
                case 'pen':
                  pen.penOnly = !pen.penOnly;
                  setState(() {});
                case 'rename':
                  _rename();
                default:
                  _setTemplate(PageTemplate.byName(v));
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'recs',
                child: Text('التسجيلات (${book.recordings.length})'),
              ),
              const PopupMenuItem(
                value: 'add',
                child: Text('صفحة جديدة بعد دي'),
              ),
              const PopupMenuItem(value: 'del', child: Text('حذف الصفحة')),
              CheckedPopupMenuItem(
                value: 'pen',
                checked: pen.penOnly,
                child: const Text('الكتابة بالقلم فقط'),
              ),
              const PopupMenuItem(value: 'rename', child: Text('تغيير الاسم')),
              const PopupMenuDivider(),
              for (final t in PageTemplate.values)
                CheckedPopupMenuItem(
                  value: t.name,
                  checked: page.template == t,
                  child: Text('صفحة ${t.label}'),
                ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _Toolbar(
              pen: pen,
              listenMode: _listenMode,
              onListenMode: () => setState(() => _listenMode = !_listenMode),
              recording: recorder.recording,
              onRecord: _record,
            ),
            if (recorder.recording)
              _RecordingBar(recorder: recorder, onStop: _stopRecording),
            ListenableBuilder(
              listenable: player,
              builder: (_, _) => player.current == null
                  ? const SizedBox.shrink()
                  : _PlayerBar(player: player),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  const ratio = kPageWidth / kPageHeight;
                  final w = (c.maxHeight - 16) * ratio < c.maxWidth - 16
                      ? (c.maxHeight - 16) * ratio
                      : c.maxWidth - 16;
                  return Center(
                    child: SizedBox(
                      width: w,
                      child: Material(
                        elevation: 2,
                        clipBehavior: Clip.antiAlias,
                        borderRadius: BorderRadius.circular(4),
                        child: ListenableBuilder(
                          listenable: Listenable.merge([pen, player]),
                          builder: (context, _) {
                            final now = player.nowMs;
                            return InkPageView(
                              key: ValueKey(page.id),
                              page: page,
                              pen: pen,
                              onChanged: _changed,
                              onStrokeTap: _listenMode ? _onStrokeTap : null,
                              litRange: now == null
                                  ? null
                                  : (
                                      from: player
                                          .current!
                                          .started
                                          .millisecondsSinceEpoch,
                                      to: now,
                                    ),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            _PageBar(
              index: _index,
              count: book.pages.length,
              onPrev: () => _goTo(_index - 1),
              onNext: () => _goTo(_index + 1),
              onAdd: _addPage,
            ),
          ],
        ),
      ),
    );
  }
}

typedef _Snapshot = ({List<InkStroke> strokes, List<TypedLine> typed});

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.pen,
    required this.listenMode,
    required this.onListenMode,
    required this.recording,
    required this.onRecord,
  });

  final PenSettings pen;
  final bool listenMode;
  final VoidCallback onListenMode;
  final bool recording;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: pen,
      builder: (context, _) {
        Widget tool(PenMode m, IconData icon, String tip) => IconButton(
          tooltip: tip,
          isSelected: pen.mode == m && !listenMode,
          icon: Icon(icon),
          style: IconButton.styleFrom(
            backgroundColor: pen.mode == m && !listenMode
                ? theme.colorScheme.secondaryContainer
                : null,
          ),
          onPressed: () {
            if (listenMode) onListenMode();
            pen.mode = m;
          },
        );
        return Material(
          color: theme.colorScheme.surface,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                tool(PenMode.pen, Icons.edit, 'قلم'),
                tool(PenMode.highlighter, Icons.border_color, 'هايلايتر'),
                tool(PenMode.eraser, Icons.cleaning_services_outlined, 'ممحاة'),
                const _Divider(),
                for (final c in PenSettings.inkColors)
                  GestureDetector(
                    onTap: () {
                      if (listenMode) onListenMode();
                      if (pen.mode == PenMode.highlighter) {
                        pen.mode = PenMode.pen;
                      }
                      pen.color = c;
                    },
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          width: pen.color == c ? 3 : 0,
                          color: theme.colorScheme.primaryContainer,
                        ),
                      ),
                    ),
                  ),
                const _Divider(),
                for (final w in PenSettings.widths)
                  InkWell(
                    onTap: () => pen.width = w,
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: pen.width == w
                            ? theme.colorScheme.secondaryContainer
                            : null,
                      ),
                      child: CircleAvatar(
                        radius: w * 1.1,
                        backgroundColor: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                const _Divider(),
                IconButton(
                  tooltip: 'اسمع من الكتابة: اضغط على أي كلمة',
                  isSelected: listenMode,
                  style: IconButton.styleFrom(
                    backgroundColor: listenMode
                        ? theme.colorScheme.tertiaryContainer
                        : null,
                  ),
                  icon: const Icon(Icons.touch_app_outlined),
                  onPressed: onListenMode,
                ),
                IconButton(
                  tooltip: recording ? 'إيقاف التسجيل' : 'تسجيل',
                  icon: Icon(
                    recording ? Icons.stop_circle : Icons.mic_none,
                    color: recording ? theme.colorScheme.error : null,
                  ),
                  onPressed: onRecord,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 24,
    margin: const EdgeInsets.symmetric(horizontal: 8),
    color: Theme.of(context).dividerColor,
  );
}

String clock(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = two(d.inMinutes % 60), s = two(d.inSeconds % 60);
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

class _RecordingBar extends StatelessWidget {
  const _RecordingBar({required this.recorder, required this.onStop});
  final NoteRecorder recorder;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = recorder.mode == RecordMode.live;
    final last = [
      ...recorder.pieces.map((p) => p.text),
      if (recorder.partial.isNotEmpty) recorder.partial,
    ].join(' ');
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(
            Icons.fiber_manual_record,
            color: theme.colorScheme.error,
            size: 14,
          ),
          const SizedBox(width: 8),
          Text(
            '${live ? 'تفريغ مباشر' : 'تسجيل'} ${clock(recorder.elapsed)}',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              live
                  ? (last.isEmpty ? 'اتكلم وهيظهر الكلام هنا…' : last)
                  : 'اكتب عادي، وبعدين اضغط على أي كلمة تسمع اللي اتقال وقتها',
              maxLines: 2,
              overflow: TextOverflow.fade,
              style: theme.textTheme.bodySmall,
            ),
          ),
          TextButton(onPressed: onStop, child: const Text('إيقاف')),
        ],
      ),
    );
  }
}

class _PlayerBar extends StatelessWidget {
  const _PlayerBar({required this.player});
  final NotePlayer player;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rec = player.current!;
    return Container(
      color: theme.colorScheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(player.playing ? Icons.pause : Icons.play_arrow),
            onPressed: player.toggle,
          ),
          Text(
            '${clock(player.position)} / ${clock(rec.duration)}',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'الكتابة الملوّنة اتكتبت لحد اللحظة دي',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(icon: const Icon(Icons.close), onPressed: player.stop),
        ],
      ),
    );
  }
}

class _PageBar extends StatelessWidget {
  const _PageBar({
    required this.index,
    required this.count,
    required this.onPrev,
    required this.onNext,
    required this.onAdd,
  });

  final int index;
  final int count;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'الصفحة السابقة',
            icon: const Icon(Icons.arrow_back),
            onPressed: index > 0 ? onPrev : null,
          ),
          Text('صفحة ${index + 1} من $count'),
          IconButton(
            tooltip: 'الصفحة التالية',
            icon: const Icon(Icons.arrow_forward),
            onPressed: index < count - 1 ? onNext : null,
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.note_add_outlined, size: 18),
            label: const Text('صفحة'),
          ),
        ],
      ),
    );
  }
}

/// Reads every written line of a page and lets the user pick between the
/// readings before copying or saving the text.
class _TextSheet extends StatefulWidget {
  const _TextSheet({required this.page, required this.onInsert});
  final NotePage page;
  final void Function(List<String> lines) onInsert;

  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  final reader = HandwritingReader.instance;
  List<List<String>>? _lines;
  final List<int> _picked = [];
  String? _problem;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _problem = null;
      _lines = null;
    });
    await reader.prepare();
    if (!reader.ready) {
      setState(
        () => _problem = reader.state.value == ReaderState.downloading
            ? 'لسه بننزّل نموذج القراءة، استنى شوية وحاول تاني.'
            : 'محتاجين إنترنت مرة واحدة عشان ننزّل نموذج قراءة الخط.',
      );
      return;
    }
    final ink = widget.page.strokes
        .where((s) => s.tool == InkTool.pen && s.points.isNotEmpty)
        .toList();
    final groups = groupIntoLines<InkStroke>(ink, (s) => s.bounds);
    final out = <List<String>>[];
    var before = '';
    for (final g in groups) {
      final strokes = [
        for (final s in g)
          [for (final p in s.points) mlkit.StrokePoint(x: p.x, y: p.y, t: p.t)],
      ];
      final box = g.map((s) => s.bounds).reduce((a, b) => a.expandToInclude(b));
      final readings = await reader.readLine(
        strokes,
        area: Size(kPageWidth, box.height.clamp(40, kPageHeight)),
        preContext: before,
      );
      if (readings.isEmpty) continue;
      out.add(readings);
      before = readings.first;
      if (before.length > 20) before = before.substring(before.length - 20);
    }
    if (!mounted) return;
    setState(() {
      _lines = out;
      _picked
        ..clear()
        ..addAll(List.filled(out.length, 0));
    });
  }

  String get _text =>
      [for (var i = 0; i < (_lines?.length ?? 0); i++) _lines![i][_picked[i]]]
          .join('\n');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = _lines;
    Widget body;
    if (_problem != null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_problem!, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () async {
              await reader.retry();
              _run();
            },
            child: const Text('حاول تاني'),
          ),
        ],
      );
    } else if (lines == null) {
      body = const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (lines.isEmpty) {
      body = const Padding(
        padding: EdgeInsets.all(24),
        child: Text('مفيش كتابة بالقلم في الصفحة دي.'),
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'اضغط على أي قراءة تانية لو الأولى مش مظبوطة',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < lines.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    lines[i][_picked[i]],
                    style: theme.textTheme.titleMedium,
                  ),
                  if (lines[i].length > 1)
                    Wrap(
                      spacing: 6,
                      children: [
                        for (var k = 0; k < lines[i].length; k++)
                          if (k != _picked[i])
                            ActionChip(
                              visualDensity: VisualDensity.compact,
                              label: Text(lines[i][k]),
                              onPressed: () => setState(() => _picked[i] = k),
                            ),
                      ],
                    ),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.vertical_align_bottom),
                  label: const Text('إدراج تحت الكتابة'),
                  onPressed: () {
                    widget.onInsert(_text.split('\n'));
                    Navigator.pop(context);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.copy),
                  label: const Text('نسخ'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _text));
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('اتنسخ النص')));
                  },
                ),
              ),
            ],
          ),
        ],
      );
    }
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('النص من خط اليد', style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              body,
            ],
          ),
        ),
      ),
    );
  }
}

class _RecordingsSheet extends StatefulWidget {
  const _RecordingsSheet({
    required this.book,
    required this.store,
    required this.player,
  });

  final Notebook book;
  final NotebookStore store;
  final NotePlayer player;

  @override
  State<_RecordingsSheet> createState() => _RecordingsSheetState();
}

class _RecordingsSheetState extends State<_RecordingsSheet> {
  Future<void> _delete(Recording r) async {
    if (widget.player.current?.id == r.id) await widget.player.stop();
    setState(() => widget.book.recordings.remove(r));
    widget.store.changed(widget.book, immediate: true);
    if (r.file.isNotEmpty) {
      final f = widget.store.audioDir(widget.book.id).path;
      unawaited(
        Future(() async {
          try {
            await File('$f/${r.file}').delete();
          } catch (_) {}
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recs = widget.book.recordings.reversed.toList();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Text('التسجيلات', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            if (recs.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('لسه مفيش تسجيلات. اضغط على الميكروفون عشان تبدأ.'),
              ),
            for (final r in recs)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            r.file.isEmpty
                                ? Icons.subtitles_outlined
                                : Icons.mic,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${r.started.day}/${r.started.month} '
                              '${r.started.hour.toString().padLeft(2, '0')}:'
                              '${r.started.minute.toString().padLeft(2, '0')}'
                              ' · ${clock(r.duration)}',
                            ),
                          ),
                          if (r.file.isNotEmpty)
                            IconButton(
                              tooltip: 'تشغيل',
                              icon: const Icon(Icons.play_arrow),
                              onPressed: () {
                                widget.player.play(widget.book, r);
                                Navigator.pop(context);
                              },
                            ),
                          IconButton(
                            tooltip: 'حذف',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(r),
                          ),
                        ],
                      ),
                      if (r.transcript.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        SelectableText(
                          r.transcript.map((p) => p.text).join(' '),
                          style: theme.textTheme.bodyMedium,
                        ),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: TextButton.icon(
                            icon: const Icon(Icons.copy, size: 16),
                            label: const Text('نسخ النص'),
                            onPressed: () => Clipboard.setData(
                              ClipboardData(
                                text: r.transcript.map((p) => p.text).join(' '),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
