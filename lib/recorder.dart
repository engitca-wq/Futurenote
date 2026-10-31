import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'models.dart';
import 'store.dart';

/// How a recording is made. Phones give the microphone to one listener at a
/// time, so keeping the audio file and live speech-to-text are separate modes.
enum RecordMode {
  live(
    'تحويل الكلام لنص',
    'يكتب الكلام العربي نصًا وانت بتتكلم (محتاج إنترنت، والصوت نفسه مش بيتحفظ)',
  ),
  audio(
    'تسجيل صوت فقط',
    'يحفظ الصوت بدون نص، وتقدر تضغط على أي كلمة كتبتها تسمع اللي اتقال وقتها',
  );

  const RecordMode(this.label, this.hint);
  final String label;
  final String hint;
}

/// Records audio or live transcription for one notebook at a time.
class NoteRecorder extends ChangeNotifier {
  NoteRecorder(this.store);

  final NotebookStore store;
  // Created on first use so screens open without touching the microphone.
  late final _audio = AudioRecorder();
  bool _audioMade = false;
  final _speech = SpeechToText();
  bool _speechReady = false;
  String? _localeId;

  Notebook? _book;
  RecordMode? mode;
  DateTime? started;
  String? _path;
  String? _id;
  final List<TranscriptPiece> pieces = [];
  String partial = '';
  String? error;
  Timer? _tick;

  bool get recording => mode != null;
  Duration get elapsed =>
      started == null ? Duration.zero : DateTime.now().difference(started!);

  Future<bool> start(Notebook book, RecordMode m) async {
    try {
      return await _start(book, m);
    } catch (e) {
      debugPrint('Recording failed: $e');
      mode = null;
      started = null;
      _tick?.cancel();
      error = 'التسجيل ما اشتغلش: $e';
      notifyListeners();
      return false;
    }
  }

  Future<bool> _start(Notebook book, RecordMode m) async {
    if (recording) return false;
    error = null;
    pieces.clear();
    partial = '';
    _book = book;
    _id = newId();
    if (m == RecordMode.audio) {
      _audioMade = true;
      if (!await _audio.hasPermission()) {
        error = 'لازم تسمح للتطبيق باستخدام الميكروفون';
        notifyListeners();
        return false;
      }
      final dir = store.audioDir(book.id);
      await dir.create(recursive: true);
      _path = '${dir.path}/$_id.m4a';
      await _audio.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000),
        path: _path!,
      );
    } else {
      if (!await _initSpeech()) {
        error ??= 'خدمة تحويل الكلام لنص مش موجودة على الموبايل. نزّل أو حدّث تطبيق Google وجرّب تاني.';
        notifyListeners();
        return false;
      }
    }
    mode = m;
    started = DateTime.now();
    _tick = Timer.periodic(
      const Duration(seconds: 1),
      (_) => notifyListeners(),
    );
    if (m == RecordMode.live) await _listen();
    notifyListeners();
    return true;
  }

  Future<bool> _initSpeech() async {
    if (_speechReady) return true;
    _speechReady = await _speech.initialize(
      onStatus: _onStatus,
      onError: (e) {
        final msg = speechErrorText(e.errorMsg);
        if (msg != null) {
          error = msg;
          notifyListeners();
        }
      },
    );
    if (!_speechReady) return false;
    final locales = await _speech.locales();
    String norm(String s) => s.replaceAll('-', '_').toLowerCase();
    _localeId = locales
        .map((l) => l.localeId)
        .firstWhere(
          (id) => norm(id) == 'ar_eg',
          orElse: () => locales
              .map((l) => l.localeId)
              .firstWhere((id) => norm(id).startsWith('ar'), orElse: () => ''),
        );
    if (_localeId!.isEmpty) _localeId = 'ar-EG';
    return true;
  }

  Future<void> _listen() async {
    if (mode != RecordMode.live) return;
    await _speech.listen(
      onResult: _onResult,
      listenOptions: SpeechListenOptions(
        localeId: _localeId,
        listenFor: const Duration(minutes: 10),
        pauseFor: const Duration(seconds: 8),
        partialResults: true,
        cancelOnError: false,
        listenMode: ListenMode.dictation,
      ),
    );
  }

  void _onResult(SpeechRecognitionResult r) {
    if (mode != RecordMode.live) return;
    if (r.finalResult) {
      final text = r.recognizedWords.trim();
      if (text.isNotEmpty) {
        pieces.add(TranscriptPiece(elapsed, text));
      }
      partial = '';
    } else {
      partial = r.recognizedWords;
    }
    notifyListeners();
  }

  void _onStatus(String status) {
    // Android stops listening after a pause; keep going until the user stops.
    if (mode == RecordMode.live &&
        (status == 'done' || status == 'notListening')) {
      Future.delayed(const Duration(milliseconds: 250), () {
        if (mode == RecordMode.live && !_speech.isListening) _listen();
      });
    }
  }

  /// Stops and saves the recording into its notebook.
  Future<Recording?> stop() async {
    try {
      return await _stop();
    } catch (e) {
      debugPrint('Stopping failed: $e');
      mode = null;
      _tick?.cancel();
      error = 'حصلت مشكلة وقت إيقاف التسجيل: $e';
      notifyListeners();
      return null;
    }
  }

  Future<Recording?> _stop() async {
    if (!recording) return null;
    final m = mode!;
    final duration = elapsed;
    mode = null;
    _tick?.cancel();
    if (m == RecordMode.audio) {
      final path = await _audio.stop() ?? _path;
      final f = path == null ? null : File(path);
      if (f == null || !await f.exists() || await f.length() == 0) {
        error = 'التسجيل اتوقف بس ملف الصوت فاضي، جرّب تاني';
      }
    } else {
      await _speech.stop();
      if (partial.trim().isNotEmpty) {
        pieces.add(TranscriptPiece(duration, partial.trim()));
      }
    }
    partial = '';
    final book = _book!;
    final rec = Recording(
      id: _id!,
      file: m == RecordMode.audio ? '$_id.m4a' : '',
      started: started!,
      duration: duration,
      transcript: List.of(pieces),
    );
    started = null;
    book.recordings.add(rec);
    store.changed(book, immediate: true);
    notifyListeners();
    return rec;
  }

  @override
  void dispose() {
    _tick?.cancel();
    if (_audioMade) _audio.dispose();
    super.dispose();
  }
}

/// Explains a speech recognition error, or returns null for the ordinary
/// ones (silence, nothing understood) that just restart listening.
String? speechErrorText(String code) => switch (code) {
  'error_permission' ||
  'error_insufficient_permissions' => 'لازم تسمح للتطبيق باستخدام الميكروفون',
  'error_network' ||
  'error_network_timeout' ||
  'error_server' ||
  'error_server_disconnected' =>
    'تحويل الكلام لنص محتاج إنترنت. اتأكد إن النت شغال.',
  'error_language_not_supported' || 'error_language_unavailable' => 'اللغة العربية مش متاحة في خدمة الكلام على الموبايل. من إعدادات Google > الصوت، نزّل العربية.',
  'error_audio_error' ||
  'error_audio' => 'الميكروفون مشغول بتطبيق تاني. اقفله وجرّب تاني.',
  'error_no_match' ||
  'error_speech_timeout' ||
  'error_busy' ||
  'error_client' => null,
  _ => 'مشكلة في تحويل الكلام: $code',
};

/// Plays recordings and reports the position, so the page can light up
/// what was written at that moment.
class NotePlayer extends ChangeNotifier {
  NotePlayer(this.store);

  final NotebookStore store;
  AudioPlayer? _made;
  final List<StreamSubscription> _subs = [];

  AudioPlayer get _player {
    final existing = _made;
    if (existing != null) return existing;
    final p = _made = AudioPlayer();
    _subs.addAll([
      p.onPositionChanged.listen((d) {
        position = d;
        notifyListeners();
      }),
      p.onPlayerStateChanged.listen((s) {
        playing = s == PlayerState.playing;
        notifyListeners();
      }),
      p.onPlayerComplete.listen((_) {
        playing = false;
        notifyListeners();
      }),
    ]);
    return p;
  }

  Recording? current;
  Duration position = Duration.zero;
  bool playing = false;

  /// Epoch milliseconds of the current playback moment, or null.
  int? get nowMs => current == null
      ? null
      : current!.started.millisecondsSinceEpoch + position.inMilliseconds;

  String? error;

  Future<void> play(Notebook book, Recording rec, {Duration? from}) async {
    if (rec.file.isEmpty) return;
    final file = File('${store.audioDir(book.id).path}/${rec.file}');
    if (!await file.exists()) {
      error = 'ملف الصوت مش موجود على الجهاز';
      notifyListeners();
      return;
    }
    current = rec;
    position = from ?? Duration.zero;
    try {
      await _player.play(DeviceFileSource(file.path), position: from);
    } catch (e) {
      debugPrint('Playback failed: $e');
      current = null;
      error = 'تشغيل الصوت ما اشتغلش: $e';
    }
    notifyListeners();
  }

  /// Plays from a little before the moment a stroke was written.
  Future<bool> playAt(Notebook book, int epochMs) async {
    for (final r in book.recordings.reversed) {
      if (r.file.isEmpty) continue;
      final start = r.started.millisecondsSinceEpoch;
      if (epochMs >= start && epochMs <= start + r.duration.inMilliseconds) {
        final at = Duration(milliseconds: epochMs - start - 2000);
        await play(book, r, from: at.isNegative ? Duration.zero : at);
        return true;
      }
    }
    return false;
  }

  Future<void> toggle() async {
    if (playing) {
      await _player.pause();
    } else if (current != null) {
      await _player.resume();
    }
  }

  Future<void> stop() async {
    await _made?.stop();
    current = null;
    playing = false;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _made?.dispose();
    super.dispose();
  }
}
