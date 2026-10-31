import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'models.dart';

/// Keeps page pictures in one app folder and decodes them for painting.
class ImageStore {
  ImageStore._();
  static final instance = ImageStore._();

  Directory? root;
  final Map<String, ui.Image> _decoded = {};
  final Set<String> _loading = {};

  /// Bumped whenever a picture finishes loading, so pages repaint.
  final version = ValueNotifier(0);

  /// The decoded picture, or null while it loads (a load starts if needed).
  ui.Image? get(String file) {
    final img = _decoded[file];
    if (img == null) _load(file);
    return img;
  }

  Future<void> _load(String file) async {
    final dir = root;
    if (dir == null || !_loading.add(file)) return;
    try {
      final bytes = await File('${dir.path}/$file').readAsBytes();
      // Decode at a moderate size: a page never needs a full camera photo.
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1400);
      _decoded[file] = (await codec.getNextFrame()).image;
      version.value++;
    } catch (e) {
      debugPrint('Picture $file failed to load: $e');
    } finally {
      _loading.remove(file);
    }
  }

  /// Loads every picture on [pages], for exporting.
  Future<void> ensure(Iterable<NotePage> pages) async {
    for (final p in pages) {
      for (final i in p.images) {
        if (!_decoded.containsKey(i.file)) {
          await _load(i.file);
        }
      }
    }
  }

  /// Copies a picked picture into the app and returns its name and size.
  Future<(String, ui.Size)> add(String path) async {
    final dir = root!;
    await dir.create(recursive: true);
    final dot = path.lastIndexOf('.');
    final ext = dot == -1 ? '.jpg' : path.substring(dot).toLowerCase();
    final name = '${newId()}$ext';
    await File(path).copy('${dir.path}/$name');
    await _load(name);
    final img = _decoded[name];
    return (
      name,
      img == null
          ? const ui.Size(600, 400)
          : ui.Size(img.width.toDouble(), img.height.toDouble()),
    );
  }

  Future<void> remove(Iterable<String> files) async {
    for (final f in files) {
      _decoded.remove(f)?.dispose();
      try {
        await File('${root!.path}/$f').delete();
      } catch (_) {}
    }
  }
}
