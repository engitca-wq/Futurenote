import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import 'images.dart';
import 'ink_canvas.dart';
import 'models.dart';

/// Draws a page into PNG bytes, [width] pixels wide.
Future<Uint8List> renderPagePng(NotePage page, {double width = 1600}) async {
  await ImageStore.instance.ensure([page]);
  final scale = width / kPageWidth;
  final size = Size(width, kPageHeight * scale);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  PagePainter(
    page: page,
    scale: scale,
    accent: const Color(0xFF2F5D50),
  ).paint(canvas, size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.round(), size.height.round());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  return data!.buffer.asUint8List();
}

String _safeName(String title) {
  final cleaned = title.replaceAll(RegExp(r'[\\/:*?"<>|\n]'), ' ').trim();
  return cleaned.isEmpty ? 'FUTURENOTE' : cleaned;
}

Future<File> _tempFile(String name) async {
  final dir = await getTemporaryDirectory();
  return File('${dir.path}/$name');
}

/// Shares one page as a PNG picture.
Future<void> sharePageImage(Notebook book, int index) async {
  final png = await renderPagePng(book.pages[index]);
  final file = await _tempFile('${_safeName(book.title)} - ${index + 1}.png');
  await file.writeAsBytes(png);
  await SharePlus.instance.share(
    ShareParams(files: [XFile(file.path, mimeType: 'image/png')]),
  );
}

/// Builds a PDF of the whole notebook, one picture per page, so Arabic text
/// and handwriting look exactly as on screen.
Future<File> buildNotebookPdf(Notebook book) async {
  final doc = pw.Document(title: book.title, creator: 'FUTURENOTE');
  for (final page in book.pages) {
    final png = await renderPagePng(page, width: 1240);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Image(pw.MemoryImage(png), fit: pw.BoxFit.fill),
      ),
    );
  }
  final file = await _tempFile('${_safeName(book.title)}.pdf');
  await file.writeAsBytes(await doc.save());
  return file;
}

Future<void> shareNotebookPdf(Notebook book) async {
  final file = await buildNotebookPdf(book);
  await SharePlus.instance.share(
    ShareParams(files: [XFile(file.path, mimeType: 'application/pdf')]),
  );
}
