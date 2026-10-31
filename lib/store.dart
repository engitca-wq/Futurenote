import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Keeps every notebook in memory and writes each one to its own JSON file
/// on the device, a short moment after it changes.
class NotebookStore extends ChangeNotifier {
  NotebookStore({Directory? root}) : _rootOverride = root;

  final Directory? _rootOverride;
  late Directory _dir;
  final Map<String, Notebook> _books = {};
  final Map<String, Timer> _pending = {};
  bool loaded = false;

  static const covers = [
    0xFF2F5D50,
    0xFF1F4FA3,
    0xFF8A3B2E,
    0xFF6B4E9B,
    0xFFB7791F,
    0xFF3D4451,
  ];

  List<Notebook> get notebooks =>
      _books.values.toList()..sort((a, b) => b.updated.compareTo(a.updated));

  Notebook? byId(String id) => _books[id];

  Directory audioDir(String notebookId) =>
      Directory('${_dir.path}/audio/$notebookId');

  Future<void> load() async {
    _dir = Directory(
      '${(_rootOverride ?? await getApplicationDocumentsDirectory()).path}/notebooks',
    );
    await _dir.create(recursive: true);
    for (final f in _dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.json'),
    )) {
      try {
        final book = Notebook.fromJson(
          jsonDecode(await f.readAsString()) as Map<String, dynamic>,
        );
        _books[book.id] = book;
      } catch (e) {
        debugPrint('Skipping unreadable notebook ${f.path}: $e');
      }
    }
    if (_books.isEmpty) {
      create('دفتري الأول', cover: covers.first);
    }
    loaded = true;
    notifyListeners();
  }

  Notebook create(
    String title, {
    int? cover,
    PageTemplate template = PageTemplate.lined,
  }) {
    final now = DateTime.now();
    final book = Notebook(
      id: newId(),
      title: title.trim().isEmpty ? 'دفتر بدون اسم' : title.trim(),
      cover: cover ?? covers[_books.length % covers.length],
      template: template,
      created: now,
      updated: now,
      pages: [NotePage(id: newId(), template: template)],
    );
    _books[book.id] = book;
    changed(book, immediate: true);
    return book;
  }

  /// Marks a notebook as edited and schedules a save.
  void changed(Notebook book, {bool immediate = false}) {
    book.updated = DateTime.now();
    _pending[book.id]?.cancel();
    if (immediate) {
      _write(book);
    } else {
      _pending[book.id] = Timer(
        const Duration(milliseconds: 600),
        () => _write(book),
      );
    }
    notifyListeners();
  }

  final Map<String, Future<void>> _writing = {};

  /// Writes one notebook. Writes of the same notebook run one after another,
  /// so a slow save never overwrites a newer one.
  Future<void> _write(Notebook book) {
    _pending.remove(book.id);
    final previous = _writing[book.id] ?? Future.value();
    final next = previous
        .then((_) async {
          if (!_books.containsKey(book.id)) return;
          final file = File('${_dir.path}/${book.id}.json');
          final tmp = File('${file.path}.tmp');
          await tmp.writeAsString(jsonEncode(book.toJson()));
          await tmp.rename(file.path);
        })
        .catchError((Object e) => debugPrint('Saving ${book.id} failed: $e'));
    _writing[book.id] = next;
    return next;
  }

  Future<void> flush() async {
    for (final id in _pending.keys.toList()) {
      _pending.remove(id)?.cancel();
      final book = _books[id];
      if (book != null) _write(book);
    }
    await Future.wait(_writing.values);
  }

  Future<void> delete(Notebook book) async {
    _pending.remove(book.id)?.cancel();
    _books.remove(book.id);
    notifyListeners();
    await _writing[book.id];
    _writing.remove(book.id);
    final file = File('${_dir.path}/${book.id}.json');
    if (await file.exists()) await file.delete();
    final audio = audioDir(book.id);
    if (await audio.exists()) await audio.delete(recursive: true);
  }

  @override
  void dispose() {
    for (final t in _pending.values) {
      t.cancel();
    }
    super.dispose();
  }
}
