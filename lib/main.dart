import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'ai.dart';
import 'recognition.dart';
import 'recorder.dart';
import 'screens/library_screen.dart';
import 'store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
  runApp(FutureNoteApp(store: NotebookStore()));
}

const _accent = Color(0xFF2F5D50);

class FutureNoteApp extends StatefulWidget {
  const FutureNoteApp({
    super.key,
    required this.store,
    this.prepareReader = true,
  });

  final NotebookStore store;

  /// Tests turn this off; it downloads the handwriting model.
  final bool prepareReader;

  @override
  State<FutureNoteApp> createState() => _FutureNoteAppState();
}

class _FutureNoteAppState extends State<FutureNoteApp>
    with WidgetsBindingObserver {
  late final recorder = NoteRecorder(widget.store);
  final ai = AiService();
  late final Future<void> _loading = widget.store.loaded
      ? Future.value()
      : widget.store.load();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.prepareReader) {
      HandwritingReader.instance.prepare();
      ai.load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      widget.store.flush();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _accent,
      surface: const Color(0xFFF7F6F2),
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
      home: FutureBuilder(
        future: _loading,
        builder: (context, snap) {
          if (snap.hasError) {
            return Scaffold(
              body: Center(child: Text('تعذّر فتح الدفاتر: ${snap.error}')),
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return LibraryScreen(store: widget.store, recorder: recorder, ai: ai);
        },
      ),
    );
  }
}
