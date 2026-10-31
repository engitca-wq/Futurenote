import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../ai.dart';
import '../export.dart';
import '../images.dart';
import '../ink_canvas.dart';
import '../models.dart';
import '../recognition.dart';
import '../recorder.dart';
import '../store.dart';
import 'assistant.dart';

/// One open notebook: write on pages, convert them to text, and record.
class NotebookScreen extends StatefulWidget {
  const NotebookScreen({
    super.key,
    required this.store,
    required this.book,
    required this.recorder,
    required this.ai,
  });

  final NotebookStore store;
  final Notebook book;
  final NoteRecorder recorder;
  final AiService ai;

  @override
  State<NotebookScreen> createState() => _NotebookScreenState();
}

class _NotebookScreenState extends State<NotebookScreen> {
  final pen = PenSettings();
  late final player = NotePlayer(widget.store);
  final Map<String, List<PageContent>> _undo = {};
  final Map<String, List<PageContent>> _redo = {};
  final selection = Selection();
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
    selection.dispose();
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

  PageContent get _now => page.content;

  void _restore(PageContent s) {
    selection.clear();
    page.content = s;
  }

  void _changed(PageContent before) {
    (_undo[page.id] ??= []).add(before);
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
    selection.clear();
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

  /// All pages as thumbnails; tap one to open it.
  void _pagesOverview() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        final accent = Theme.of(context).colorScheme.primary;
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.75,
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 160,
                childAspectRatio: kPageWidth / (kPageHeight + 120),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
              ),
              itemCount: book.pages.length,
              itemBuilder: (context, i) => InkWell(
                onTap: () {
                  Navigator.pop(context);
                  _goTo(i);
                },
                child: Column(
                  children: [
                    Expanded(
                      child: AspectRatio(
                        aspectRatio: kPageWidth / kPageHeight,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: i == _index ? accent : Colors.black12,
                              width: i == _index ? 3 : 1,
                            ),
                          ),
                          child: LayoutBuilder(
                            builder: (context, c) => CustomPaint(
                              painter: PagePainter(
                                page: book.pages[i],
                                scale: c.maxWidth / kPageWidth,
                                accent: accent,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('${i + 1}'),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ---- Layers ----

  void _layers() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          final p = page;
          void update(VoidCallback f) {
            f();
            setSheet(() {});
            setState(() {});
            widget.store.changed(book);
          }

          final theme = Theme.of(context);
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    'اختار الطبقة اللي هتكتب عليها. الممحاة والتحديد بيشتغلوا على الطبقة دي بس.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 8),
                // Top layer first, like a stack of sheets.
                for (final l in p.layers.reversed)
                  ListTile(
                    selected: p.active == l.id,
                    selectedTileColor: theme.colorScheme.secondaryContainer,
                    leading: IconButton(
                      tooltip: l.visible ? 'إخفاء' : 'إظهار',
                      icon: Icon(
                        l.visible ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () => update(() => l.visible = !l.visible),
                    ),
                    title: Text(l.name),
                    subtitle: Text(
                      p.active == l.id
                          ? 'بتكتب عليها دلوقتي'
                          : 'دوس عشان تكتب عليها',
                    ),
                    onTap: () => update(() {
                      p.active = l.id;
                      l.visible = true;
                      selection.clear();
                    }),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) async {
                        final i = p.layers.indexOf(l);
                        switch (v) {
                          case 'up' when i < p.layers.length - 1:
                            update(() {
                              p.layers
                                ..removeAt(i)
                                ..insert(i + 1, l);
                            });
                          case 'down' when i > 0:
                            update(() {
                              p.layers
                                ..removeAt(i)
                                ..insert(i - 1, l);
                            });
                          case 'rename':
                            final name = await _askText('اسم الطبقة', l.name);
                            if (name != null && name.trim().isNotEmpty) {
                              update(() => l.name = name.trim());
                            }
                          case 'delete':
                            _changed(p.content);
                            update(() {
                              bool keep(String x) => p.layerOf(x) != l.id;
                              p.strokes = [
                                for (final s in p.strokes)
                                  if (keep(s.layer)) s,
                              ];
                              p.typed = [
                                for (final t in p.typed)
                                  if (keep(t.layer)) t,
                              ];
                              p.images = [
                                for (final x in p.images)
                                  if (keep(x.layer)) x,
                              ];
                              p.layers.remove(l);
                              p.active = p.active;
                              selection.clear();
                            });
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'up', child: Text('لفوق')),
                        const PopupMenuItem(value: 'down', child: Text('لتحت')),
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('تغيير الاسم'),
                        ),
                        if (p.layers.length > 1)
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('حذف الطبقة وما عليها'),
                          ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('طبقة جديدة'),
                    onPressed: () => update(() {
                      final l = PageLayer(
                        id: newId(),
                        name: 'طبقة ${p.layers.length + 1}',
                      );
                      p.layers.add(l);
                      p.active = l.id;
                      selection.clear();
                    }),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<String?> _askText(String title, String initial) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: const Text('تم'),
          ),
        ],
      ),
    ).whenComplete(c.dispose);
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
                leading: Icon(switch (m) {
                  RecordMode.audio => Icons.mic,
                  RecordMode.live => Icons.subtitles_outlined,
                  RecordMode.dictate => Icons.record_voice_over_outlined,
                }),
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
    recorder.onDictated = mode == RecordMode.dictate
        ? (text) {
            if (mounted) _insertText([text], dictated: true);
          }
        : null;
    await recorder.start(book, mode);
  }

  Future<void> _stopRecording() async {
    final was = recorder.mode;
    final rec = await recorder.stop();
    recorder.onDictated = null;
    if (!mounted || rec == null) return;
    if (was == RecordMode.dictate && rec.transcript.isNotEmpty) {
      _toast('اتكتب الكلام على الصفحة. زرار التراجع يشيل آخر جملة.');
    } else if (rec.transcript.isNotEmpty) {
      _recordings();
    } else if (was?.speech ?? false) {
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
            'اتحفظ التسجيل. اضغط زرار الإيد وبعدين أي كلمة كتبتها عشان تسمع، أو حوّله لنص من التسجيلات.',
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
      builder: (_) => _RecordingsSheet(
        book: book,
        store: widget.store,
        player: player,
        ai: widget.ai,
        onInsert: _insertText,
      ),
    );
  }

  /// Text tool, before the page opens a field: a tap on a task's box ticks
  /// it (returns true). A tap on a typed line loads its style into the pen,
  /// so the field opens looking like the line.
  bool _onTextTap(Offset at, TypedLine? hit) {
    if (hit == null) return false;
    if (hit.todo) {
      final side = hit.box.height * 0.5 + 12;
      final onBox = hit.rtl
          ? at.dx > hit.box.right - side
          : at.dx < hit.box.left + side;
      if (onBox) {
        _changed(page.content);
        setState(() {
          page.typed = [
            for (final t in page.typed)
              identical(t, hit) ? t.copyWith(done: !t.done) : t,
          ];
        });
        widget.store.changed(book);
        return true;
      }
    }
    pen.font = hit.font;
    pen.textHeight = hit.box.height;
    pen.todo = hit.todo;
    pen.color = hit.color;
    pen.mode = PenMode.text;
    return false;
  }

  /// The page's text field closed: place what was typed as ruled lines from
  /// where the field sat, replacing the edited line (empty text deletes it).
  void _onTextCommit(NotePage target, TypedLine? hit, Rect box, String text) {
    final h = pen.textHeight;
    final wrap = (48 * 50 / h).round().clamp(10, 80);
    final lines = [for (final l in text.split('\n')) ...wrapLine(l, max: wrap)];
    if (hit == null && lines.isEmpty) return;
    if (hit != null &&
        lines.length == 1 &&
        lines.first == hit.text &&
        hit.font == pen.font &&
        hit.color == pen.color &&
        hit.todo == pen.todo &&
        hit.box.height == h) {
      return; // nothing changed
    }
    final step = h + 6 < 56 ? 56.0 : h + 6;
    final bottom = box.bottom;
    final placed = [
      for (var i = 0; i < lines.length; i++)
        if (bottom + i * step <= kPageHeight - 10)
          TypedLine(
            box: Rect.fromLTWH(box.left, bottom + i * step - h, box.width, h),
            text: lines[i],
            color: pen.color,
            font: pen.font,
            todo: pen.todo,
            done: pen.todo && (hit?.done ?? false) && lines.length == 1,
            layer: hit?.layer ?? target.active,
          ),
    ];
    final undo = _undo[target.id] ??= [];
    undo.add(target.content);
    if (undo.length > 100) undo.removeAt(0);
    _redo[target.id]?.clear();
    target.typed = [
      for (final t in target.typed)
        if (!identical(t, hit)) t,
      ...placed,
    ];
    widget.store.changed(book);
    if (mounted) setState(() {});
  }

  /// Asks where the picture comes from: gallery, camera or files.
  Future<void> _pickImageSource() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (v, icon, label) in const [
              ('gallery', Icons.image_outlined, 'من المعرض'),
              ('camera', Icons.photo_camera_outlined, 'صورة بالكاميرا'),
              ('files', Icons.folder_open, 'من الملفات'),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(context, v),
              ),
          ],
        ),
      ),
    );
    switch (choice) {
      case 'gallery':
        await _addImage(ImageSource.gallery);
      case 'camera':
        await _addImage(ImageSource.camera);
      case 'files':
        await _addImage(null);
    }
  }

  /// Adds a picture from [source], or from the phone's files when null.
  Future<void> _addImage(ImageSource? source) async {
    String? path;
    try {
      if (source == null) {
        final f = await FilePicker.pickFile(type: FileType.image);
        if (f == null) return;
        path = f.path;
        if (path == null) {
          // A document from a cloud or content provider: copy it first.
          final bytes = await f.xFile.readAsBytes();
          final dot = f.name.lastIndexOf('.');
          final tmp = File(
            '${Directory.systemTemp.path}/${newId()}${dot == -1 ? '.jpg' : f.name.substring(dot)}',
          );
          await tmp.writeAsBytes(bytes);
          path = tmp.path;
        }
      } else {
        final picked = await ImagePicker().pickImage(
          source: source,
          maxWidth: 2000,
        );
        path = picked?.path;
      }
    } catch (e) {
      _toast(
        'مش قادر أفتح ${switch (source) {
          ImageSource.camera => 'الكاميرا',
          ImageSource.gallery => 'الصور',
          null => 'الملفات',
        }}: $e',
      );
      return;
    }
    if (path == null || !mounted) return;
    final (file, size) = await ImageStore.instance.add(path);
    // Fit inside 70% of the page width, centred near the top third.
    var w = kPageWidth * 0.7, h = w * size.height / size.width;
    if (h > kPageHeight * 0.5) {
      h = kPageHeight * 0.5;
      w = h * size.width / size.height;
    }
    final img = PageImage(
      file: file,
      layer: page.active,
      box: Rect.fromLTWH((kPageWidth - w) / 2, 160, w, h),
    );
    _changed(page.content);
    setState(() => page.images = [...page.images, img]);
    pen.mode = PenMode.lasso;
    selection.select(page, [
      img.box.topLeft,
      img.box.topRight,
      img.box.bottomRight,
      img.box.bottomLeft,
    ]);
    _toast('اسحب الصورة عشان تحرّكها، والدايرة اللي في الركن تكبّرها.');
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _export(Future<void> Function() job) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await job();
    } catch (e) {
      _toast('التصدير ما اشتغلش: $e');
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  void _selectionEdit(PageContent? before) {
    if (before == null) return;
    _changed(before);
  }

  void _paste() {
    final clip = Selection.clipboard;
    if (clip == null) return;
    pen.mode = PenMode.lasso;
    _changed(selection.paste(page, clip, const Offset(30, 30)));
  }

  void _assistant() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => AssistantSheet(
        ai: widget.ai,
        book: book,
        page: page,
        onInsert: _insertText,
        onOpenSettings: () {
          Navigator.pop(sheet);
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AssistantSettingsScreen(ai: widget.ai),
            ),
          );
        },
      ),
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
  void _insertText(List<String> raw, {bool dictated = false}) {
    final lines = [for (final l in raw) ...wrapLine(l)];
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
          layer: target.active,
          color: dictated ? pen.color : 0xFF1D1F22,
          font: dictated ? pen.font : '',
        ),
      );
      y += rule;
    }
    (_undo[target.id] ??= []).add(_now);
    _redo[target.id]?.clear();
    setState(() {
      target.typed = [...target.typed, ...placed];
      if (!dictated) target.text = lines.join('\n');
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
              color: dictated ? pen.color : 0xFF1D1F22,
              font: dictated ? pen.font : '',
            ),
        ];
        book.pages.insert(_index + 1, next);
        // Dictation keeps going on the new page.
        if (dictated) _index++;
      }
    });
    widget.store.changed(book, immediate: true);
    if (dictated) return;
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
            tooltip: 'المساعد الذكي',
            icon: const Icon(Icons.auto_awesome),
            onPressed: _assistant,
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
                case 'gallery':
                  _addImage(ImageSource.gallery);
                case 'camera':
                  _addImage(ImageSource.camera);
                case 'files':
                  _addImage(null);
                case 'sharePage':
                  _export(() => sharePageImage(book, _index));
                case 'sharePdf':
                  _export(() => shareNotebookPdf(book));
                default:
                  _setTemplate(PageTemplate.byName(v));
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'gallery',
                child: ListTile(
                  leading: Icon(Icons.image_outlined),
                  title: Text('صورة من المعرض'),
                ),
              ),
              const PopupMenuItem(
                value: 'camera',
                child: ListTile(
                  leading: Icon(Icons.photo_camera_outlined),
                  title: Text('صورة بالكاميرا'),
                ),
              ),
              const PopupMenuItem(
                value: 'files',
                child: ListTile(
                  leading: Icon(Icons.folder_open),
                  title: Text('صورة من الملفات'),
                ),
              ),
              const PopupMenuItem(
                value: 'sharePage',
                child: ListTile(
                  leading: Icon(Icons.ios_share),
                  title: Text('مشاركة الصفحة صورة'),
                ),
              ),
              const PopupMenuItem(
                value: 'sharePdf',
                child: ListTile(
                  leading: Icon(Icons.picture_as_pdf_outlined),
                  title: Text('مشاركة الدفتر PDF'),
                ),
              ),
              const PopupMenuDivider(),
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
              onImage: _pickImageSource,
              layerName: page.layers.length > 1
                  ? page.layers.firstWhere((l) => l.id == page.active).name
                  : null,
              onLayers: _layers,
            ),
            if (!_listenMode) _ModeBar(pen: pen),
            ListenableBuilder(
              listenable: Listenable.merge([selection, pen]),
              builder: (_, _) => _SelectionBar(
                selection: selection,
                lassoOn: pen.mode == PenMode.lasso,
                onEdit: _selectionEdit,
                onPaste: _paste,
              ),
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
                              selection: selection,
                              onChanged: _changed,
                              onStrokeTap: _listenMode ? _onStrokeTap : null,
                              onTextTap: _onTextTap,
                              onTextCommit: _onTextCommit,
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
              onAll: _pagesOverview,
            ),
          ],
        ),
      ),
    );
  }
}

/// Splits a long line at spaces so each piece fits one ruled line.
List<String> wrapLine(String line, {int max = 48}) {
  final out = <String>[];
  var current = '';
  for (final word in line.split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    if (current.isEmpty) {
      current = word;
    } else if (current.length + 1 + word.length <= max) {
      current = '$current $word';
    } else {
      out.add(current);
      current = word;
    }
  }
  if (current.isNotEmpty) out.add(current);
  return out;
}

/// Actions for what the lasso selected, or a paste button.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.selection,
    required this.lassoOn,
    required this.onEdit,
    required this.onPaste,
  });

  final Selection selection;
  final bool lassoOn;
  final void Function(PageContent? before) onEdit;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!selection.active && !(lassoOn && Selection.clipboard != null)) {
      if (lassoOn) {
        return Container(
          width: double.infinity,
          color: theme.colorScheme.secondaryContainer,
          padding: const EdgeInsets.all(8),
          child: const Text(
            'لفّ بالقلم حوالين الحاجة اللي عايز تحددها',
            textAlign: TextAlign.center,
          ),
        );
      }
      return const SizedBox.shrink();
    }
    Widget action(IconData icon, String label, VoidCallback onTap) =>
        TextButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label),
        );
    return Container(
      width: double.infinity,
      color: theme.colorScheme.secondaryContainer,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            if (selection.active) ...[
              action(Icons.copy, 'نسخ', () {
                selection.copy();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('اتنسخ. تقدر تلصقه في أي صفحة.'),
                  ),
                );
                (context as Element).markNeedsBuild();
              }),
              action(Icons.content_cut, 'قص', () {
                selection.copy();
                onEdit(selection.delete());
              }),
              action(
                Icons.control_point_duplicate,
                'تكرار',
                () => onEdit(selection.duplicate()),
              ),
              action(
                Icons.delete_outline,
                'حذف',
                () => onEdit(selection.delete()),
              ),
              if (selection.hasText) ...[
                const _Divider(),
                IconButton(
                  tooltip: 'تصغير الخط',
                  icon: const Icon(Icons.text_decrease),
                  onPressed: () => onEdit(selection.styleText(k: 0.8)),
                ),
                IconButton(
                  tooltip: 'تكبير الخط',
                  icon: const Icon(Icons.text_increase),
                  onPressed: () => onEdit(selection.styleText(k: 1.25)),
                ),
                PopupMenuButton<String>(
                  tooltip: 'نوع الخط',
                  icon: const Icon(Icons.font_download_outlined),
                  onSelected: (f) => onEdit(selection.styleText(font: f)),
                  itemBuilder: (_) => [
                    for (final (f, label) in textFonts)
                      PopupMenuItem(
                        value: f,
                        child: Text(
                          label,
                          style: TextStyle(
                            fontFamily: f.isEmpty ? null : f,
                            fontSize: 18,
                          ),
                        ),
                      ),
                  ],
                ),
                for (final c in PenSettings.moreColors)
                  GestureDetector(
                    onTap: () => onEdit(selection.styleText(color: c)),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                const _Divider(),
              ],
            ],
            if (Selection.clipboard != null)
              action(Icons.content_paste, 'لصق', onPaste),
            if (selection.active)
              action(Icons.close, 'إلغاء التحديد', selection.clear),
          ],
        ),
      ),
    );
  }
}

/// Options for the tool in hand: font, size and task boxes while typing,
/// line style while drawing shapes.
class _ModeBar extends StatelessWidget {
  const _ModeBar({required this.pen});
  final PenSettings pen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: pen,
      builder: (context, _) {
        final List<Widget> items;
        if (pen.mode == PenMode.text) {
          items = [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('دوس على الصفحة واكتب'),
            ),
            const _Divider(),
            for (final (f, label) in textFonts)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: ChoiceChip(
                  label: Text(
                    label,
                    style: TextStyle(fontFamily: f.isEmpty ? null : f),
                  ),
                  selected: pen.font == f,
                  onSelected: (_) => pen.font = f,
                ),
              ),
            const _Divider(),
            for (final (h, label) in PenSettings.textSizes)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: ChoiceChip(
                  label: Text(label),
                  selected: pen.textHeight == h,
                  onSelected: (_) => pen.textHeight = h,
                ),
              ),
            const _Divider(),
            FilterChip(
              avatar: const Icon(Icons.check_box_outlined, size: 18),
              label: const Text('مهام'),
              selected: pen.todo,
              onSelected: (v) => pen.todo = v,
            ),
          ];
        } else if (pen.mode == PenMode.shape) {
          items = [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('${pen.shape.label}: اسحب على الصفحة'),
            ),
            const _Divider(),
            for (final l in LineStyle.values)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: ChoiceChip(
                  label: Text(l.label),
                  selected: pen.lineStyle == l,
                  onSelected: (_) => pen.lineStyle = l,
                ),
              ),
          ];
        } else {
          return const SizedBox.shrink();
        }
        return Container(
          width: double.infinity,
          color: theme.colorScheme.surfaceContainerLow,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(children: items),
          ),
        );
      },
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.pen,
    required this.listenMode,
    required this.onListenMode,
    required this.recording,
    required this.onRecord,
    required this.layerName,
    required this.onLayers,
    required this.onImage,
  });

  final PenSettings pen;
  final bool listenMode;
  final VoidCallback onListenMode;
  final bool recording;
  final VoidCallback onRecord;
  final String? layerName;
  final VoidCallback onLayers;
  final VoidCallback onImage;

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
                tool(PenMode.text, Icons.keyboard_outlined, 'كتابة بالكيبورد'),
                tool(PenMode.lasso, Icons.highlight_alt, 'تحديد (لاسو)'),
                PopupMenuButton<ShapeKind>(
                  tooltip: 'أشكال',
                  initialValue: pen.shape,
                  onSelected: (k) {
                    if (listenMode) onListenMode();
                    pen.shape = k;
                  },
                  itemBuilder: (_) => [
                    for (final k in ShapeKind.values)
                      PopupMenuItem(
                        value: k,
                        child: ListTile(
                          leading: Icon(k.icon),
                          title: Text(k.label),
                        ),
                      ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: pen.mode == PenMode.shape && !listenMode
                          ? theme.colorScheme.secondaryContainer
                          : null,
                    ),
                    child: Icon(pen.shape.icon),
                  ),
                ),
                IconButton(
                  tooltip: 'خط مستقيم',
                  isSelected:
                      pen.mode == PenMode.shape && pen.shape == ShapeKind.line,
                  style: IconButton.styleFrom(
                    backgroundColor:
                        pen.mode == PenMode.shape &&
                            pen.shape == ShapeKind.line &&
                            !listenMode
                        ? theme.colorScheme.secondaryContainer
                        : null,
                  ),
                  icon: const Icon(Icons.horizontal_rule),
                  onPressed: () {
                    if (listenMode) onListenMode();
                    pen.shape = ShapeKind.line;
                  },
                ),
                IconButton(
                  tooltip: 'إضافة صورة',
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  onPressed: onImage,
                ),
                layerName == null
                    ? IconButton(
                        tooltip: 'الطبقات',
                        icon: const Icon(Icons.layers_outlined),
                        onPressed: onLayers,
                      )
                    : ActionChip(
                        avatar: const Icon(Icons.layers, size: 18),
                        label: Text(layerName!),
                        onPressed: onLayers,
                      ),
                const _Divider(),
                for (final c in [
                  ...PenSettings.inkColors,
                  if (!PenSettings.inkColors.contains(pen.color)) pen.color,
                ])
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
                IconButton(
                  tooltip: 'ألوان أكتر',
                  icon: const Icon(Icons.palette_outlined),
                  onPressed: () async {
                    final c = await showModalBottomSheet<int>(
                      context: context,
                      showDragHandle: true,
                      builder: (context) => SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              for (final c in PenSettings.moreColors)
                                InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: () => Navigator.pop(context, c),
                                  child: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: Color(c),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.black12,
                                        width: pen.color == c ? 4 : 1,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                    if (c == null) return;
                    if (listenMode) onListenMode();
                    if (pen.mode == PenMode.highlighter) pen.mode = PenMode.pen;
                    pen.color = c;
                  },
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
    final live = recorder.mode?.speech ?? false;
    final dictating = recorder.mode == RecordMode.dictate;
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
            '${dictating
                ? 'بيكتب بالصوت'
                : live
                ? 'تفريغ مباشر'
                : 'تسجيل'} ${clock(recorder.elapsed)}',
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
    required this.onAll,
  });

  final int index;
  final int count;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onAdd;
  final VoidCallback onAll;

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
          TextButton.icon(
            onPressed: onAll,
            icon: const Icon(Icons.grid_view, size: 18),
            label: Text('صفحة ${index + 1} من $count'),
          ),
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
    final out = await reader.readPage(widget.page);
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
    required this.ai,
    required this.onInsert,
  });

  final Notebook book;
  final NotebookStore store;
  final NotePlayer player;
  final AiService ai;
  final void Function(List<String> lines) onInsert;

  @override
  State<_RecordingsSheet> createState() => _RecordingsSheetState();
}

class _RecordingsSheetState extends State<_RecordingsSheet> {
  final _busy = <String>{};

  Future<void> _transcribe(Recording r) async {
    setState(() => _busy.add(r.id));
    try {
      final file = File(
        '${widget.store.audioDir(widget.book.id).path}/${r.file}',
      );
      final pieces = await widget.ai.transcribe(file);
      final done = Recording(
        id: r.id,
        file: r.file,
        started: r.started,
        duration: r.duration,
        transcript: pieces,
      );
      final i = widget.book.recordings.indexOf(r);
      if (i != -1) widget.book.recordings[i] = done;
      widget.store.changed(widget.book, immediate: true);
    } on AiError catch (e) {
      _say(e.message);
    } catch (e) {
      _say('التحويل ما اشتغلش: $e');
    } finally {
      if (mounted) setState(() => _busy.remove(r.id));
    }
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

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
                      if (r.transcript.isEmpty && r.file.isNotEmpty)
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: _busy.contains(r.id)
                              ? const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : FilledButton.tonalIcon(
                                  icon: const Icon(Icons.subtitles_outlined),
                                  label: const Text('حوّل التسجيل لنص'),
                                  onPressed: () => _transcribe(r),
                                ),
                        ),
                      if (r.transcript.isEmpty && r.file.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'ما اتسمعش كلام في التفريغ ده. اتأكد من النت واتكلم قريب من الموبايل.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      if (r.transcript.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        // Each piece with its time; tap a time to listen.
                        for (final p in r.transcript)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                InkWell(
                                  onTap: r.file.isEmpty
                                      ? null
                                      : () {
                                          widget.player.play(
                                            widget.book,
                                            r,
                                            from: p.at,
                                          );
                                          Navigator.pop(context);
                                        },
                                  child: Padding(
                                    padding: const EdgeInsetsDirectional.only(
                                      end: 8,
                                    ),
                                    child: Text(
                                      clock(p.at),
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: r.file.isEmpty
                                                ? null
                                                : theme.colorScheme.primary,
                                          ),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: SelectableText(
                                    p.text,
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton.icon(
                              icon: const Icon(Icons.copy, size: 16),
                              label: const Text('نسخ'),
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(
                                    text: r.transcript
                                        .map((p) => p.text)
                                        .join(' '),
                                  ),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'اتنسخ. تقدر تلصقه بأداة الكيبورد في الصفحة أو في أي تطبيق.',
                                    ),
                                  ),
                                );
                              },
                            ),
                            FilledButton.tonalIcon(
                              icon: const Icon(
                                Icons.vertical_align_bottom,
                                size: 16,
                              ),
                              label: const Text('إدراج في الصفحة'),
                              onPressed: () {
                                widget.onInsert([
                                  for (final p in r.transcript) p.text,
                                ]);
                                Navigator.pop(context);
                              },
                            ),
                          ],
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
