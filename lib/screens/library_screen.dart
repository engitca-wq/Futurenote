import 'package:flutter/material.dart';

import '../ai.dart';
import '../ink_canvas.dart';
import '../models.dart';
import '../recognition.dart';
import '../recorder.dart';
import '../store.dart';
import 'assistant.dart';
import 'notebook_screen.dart';

/// Home screen: every notebook as a cover, newest first.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.store,
    required this.recorder,
    required this.ai,
  });

  final NotebookStore store;
  final NoteRecorder recorder;
  final AiService ai;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _search = TextEditingController();
  bool _searching = false;

  NotebookStore get store => widget.store;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Notebook> _visible() {
    final q = _search.text.trim();
    if (q.isEmpty) return store.notebooks;
    return store.notebooks.where((b) => notebookMatches(b, q)).toList();
  }

  void _open(Notebook book) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NotebookScreen(
          store: store,
          book: book,
          recorder: widget.recorder,
          ai: widget.ai,
        ),
      ),
    );
  }

  Future<void> _create() async {
    final result = await showDialog<_BookDetails>(
      context: context,
      builder: (_) => const _BookDialog(),
    );
    if (result == null || !mounted) return;
    final book = store.create(
      result.title,
      cover: result.cover,
      template: result.template,
    );
    _open(book);
  }

  Future<void> _edit(Notebook book) async {
    final result = await showDialog<_BookDetails>(
      context: context,
      builder: (_) => _BookDialog(existing: book),
    );
    if (result == null) return;
    book.title = result.title.trim().isEmpty ? book.title : result.title.trim();
    book.cover = result.cover;
    store.changed(book, immediate: true);
  }

  Future<void> _delete(Notebook book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف الدفتر؟'),
        content: Text(
          'هيتحذف "${book.title}" بكل صفحاته وتسجيلاته، ومش هتقدر ترجّعه.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok == true) await store.delete(book);
  }

  void _menu(Notebook book) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('تعديل الاسم والغلاف'),
              onTap: () {
                Navigator.pop(context);
                _edit(book);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('حذف الدفتر'),
              onTap: () {
                Navigator.pop(context);
                _delete(book);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'ابحث في الدفاتر والنصوص…',
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() {}),
              )
            : const Text(
                'FUTURENOTE',
                style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1),
              ),
        actions: [
          IconButton(
            tooltip: 'إعدادات المساعد الذكي',
            icon: const Icon(Icons.auto_awesome_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AssistantSettingsScreen(ai: widget.ai),
              ),
            ),
          ),
          IconButton(
            tooltip: _searching ? 'إغلاق البحث' : 'بحث',
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) _search.clear();
            }),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('دفتر جديد'),
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final books = _visible();
          return Column(
            children: [
              const _ReaderBanner(),
              Expanded(
                child: books.isEmpty
                    ? Center(
                        child: Text(
                          _search.text.isEmpty
                              ? 'مفيش دفاتر لسه. اعمل أول دفتر.'
                              : 'مفيش نتائج للبحث',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 210,
                              mainAxisSpacing: 16,
                              crossAxisSpacing: 16,
                              childAspectRatio: 0.62,
                            ),
                        itemCount: books.length,
                        itemBuilder: (context, i) => _BookCard(
                          book: books[i],
                          onTap: () => _open(books[i]),
                          onMenu: () => _menu(books[i]),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// True when [q] appears in the notebook's title, converted text, or
/// recording transcripts.
bool notebookMatches(Notebook b, String q) {
  final needle = q.toLowerCase();
  if (b.title.toLowerCase().contains(needle)) return true;
  for (final p in b.pages) {
    if (p.text?.toLowerCase().contains(needle) ?? false) return true;
    for (final t in p.typed) {
      if (t.text.toLowerCase().contains(needle)) return true;
    }
  }
  for (final r in b.recordings) {
    for (final t in r.transcript) {
      if (t.text.toLowerCase().contains(needle)) return true;
    }
  }
  return false;
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.onTap,
    required this.onMenu,
  });

  final Notebook book;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = book.pages.isEmpty ? null : book.pages.first;
    return InkWell(
      onTap: onTap,
      onLongPress: onMenu,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Color(book.cover),
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [
                  BoxShadow(
                    blurRadius: 6,
                    offset: Offset(0, 2),
                    color: Color(0x22000000),
                  ),
                ],
              ),
              padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 10, 10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: first == null
                    ? const SizedBox()
                    : LayoutBuilder(
                        builder: (context, c) => CustomPaint(
                          size: c.biggest,
                          painter: PagePainter(
                            page: first,
                            scale: c.maxWidth / kPageWidth,
                            accent: theme.colorScheme.primary,
                          ),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              InkWell(
                onTap: onMenu,
                customBorder: const CircleBorder(),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.more_vert, size: 18),
                ),
              ),
            ],
          ),
          Text(
            '${book.pages.length} صفحة'
            '${book.recordings.isEmpty ? '' : ' · ${book.recordings.length} تسجيل'}'
            ' · ${shortDate(book.updated)}',
            style: theme.textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

String shortDate(DateTime d) {
  final now = DateTime.now();
  final days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(d.year, d.month, d.day)).inDays;
  String two(int n) => n.toString().padLeft(2, '0');
  if (days == 0) return 'اليوم ${two(d.hour)}:${two(d.minute)}';
  if (days == 1) return 'أمس';
  return '${d.day}/${d.month}/${d.year}';
}

class _BookDetails {
  const _BookDetails(this.title, this.cover, this.template);
  final String title;
  final int cover;
  final PageTemplate template;
}

class _BookDialog extends StatefulWidget {
  const _BookDialog({this.existing});
  final Notebook? existing;

  @override
  State<_BookDialog> createState() => _BookDialogState();
}

class _BookDialogState extends State<_BookDialog> {
  late final _title = TextEditingController(text: widget.existing?.title);
  late int _cover = widget.existing?.cover ?? NotebookStore.covers.first;
  late PageTemplate _template = widget.existing?.template ?? PageTemplate.lined;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _done() =>
      Navigator.pop(context, _BookDetails(_title.text, _cover, _template));

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return AlertDialog(
      title: Text(editing ? 'تعديل الدفتر' : 'دفتر جديد'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _title,
              autofocus: !editing,
              decoration: const InputDecoration(labelText: 'اسم الدفتر'),
              onSubmitted: (_) => _done(),
            ),
            const SizedBox(height: 18),
            const Text('لون الغلاف'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final c in NotebookStore.covers)
                  GestureDetector(
                    onTap: () => setState(() => _cover = c),
                    child: CircleAvatar(
                      radius: 17,
                      backgroundColor: Color(c),
                      child: _cover == c
                          ? const Icon(
                              Icons.check,
                              color: Colors.white,
                              size: 18,
                            )
                          : null,
                    ),
                  ),
              ],
            ),
            if (!editing) ...[
              const SizedBox(height: 18),
              const Text('شكل الصفحات'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final t in PageTemplate.values)
                    ChoiceChip(
                      label: Text(t.label),
                      selected: _template == t,
                      onSelected: (_) => setState(() => _template = t),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(onPressed: _done, child: Text(editing ? 'حفظ' : 'إنشاء')),
      ],
    );
  }
}

/// Tells the user when the handwriting model is still downloading.
class _ReaderBanner extends StatelessWidget {
  const _ReaderBanner();

  @override
  Widget build(BuildContext context) {
    final reader = HandwritingReader.instance;
    return ValueListenableBuilder(
      valueListenable: reader.state,
      builder: (context, state, _) {
        final (text, busy) = switch (state) {
          ReaderState.ready => (null, false),
          ReaderState.preparing => (null, false),
          ReaderState.downloading => (
            'بننزّل نموذج قراءة الخط العربي (مرة واحدة بس)…',
            true,
          ),
          ReaderState.failed => (
            'محتاجين إنترنت مرة واحدة عشان ننزّل نموذج قراءة الخط.',
            false,
          ),
        };
        if (text == null) return const SizedBox.shrink();
        return MaterialBanner(
          content: Text(text),
          leading: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_off),
          actions: [
            if (!busy)
              TextButton(
                onPressed: reader.retry,
                child: const Text('حاول تاني'),
              ),
            if (busy) const SizedBox.shrink(),
          ],
        );
      },
    );
  }
}
