import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// What the assistant can do with a set of notes.
enum AiTask {
  summary('ملخص'),
  minutes('محضر اجتماع ومهام'),
  translateEn('ترجمة للإنجليزية'),
  translateAr('ترجمة للعربية'),
  ask('اسأل عن ملاحظاتك');

  const AiTask(this.label);
  final String label;
}

/// The instructions for each task. The server function keeps the same text,
/// so both routes answer alike.
const _system =
    'You are the assistant inside FUTURENOTE, a handwriting and voice notes app '
    'used mostly by Arabic speakers, many in Egypt. The notes come from '
    'handwriting recognition and speech-to-text, so expect misread letters, '
    'missing dots and dialect; read through those errors to the intended '
    'meaning. Base everything only on the notes; never invent names, numbers, '
    'dates or decisions. Write plain text with simple "- " bullets, no '
    'Markdown headings or bold. Keep lines short so they fit on a notebook '
    'page.';

String _instruction(AiTask task, String? question) => switch (task) {
  AiTask.summary =>
    'Summarize these notes in the language they are mostly written in. Start '
        'with one sentence on what they are about, then up to 7 short bullets '
        'with the key points.',
  AiTask.minutes =>
    'Turn these notes into meeting minutes in the language they are mostly '
        'written in, with three parts: the topic, the decisions taken, and the '
        'action items. Write each action item as "- task - owner - due date", '
        'leaving owner or date out when the notes do not say them.',
  AiTask.translateEn =>
    'Translate these notes into clear English. Keep the line structure. '
        'Output only the translation.',
  AiTask.translateAr =>
    'Translate these notes into clear Modern Standard Arabic. Keep the line '
        'structure. Output only the translation.',
  AiTask.ask =>
    'Answer this question using only the notes, in the language of the '
        'question. If the notes do not contain the answer, say so in one '
        'sentence.\n\nQuestion: ${question ?? ''}',
};

class AiError implements Exception {
  AiError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A ready-made provider setting. All of them speak the common
/// "chat completions" protocol, so any open model host works.
class AiPreset {
  const AiPreset(this.name, this.baseUrl, this.modelHint, this.note);
  final String name;
  final String baseUrl;
  final String modelHint;
  final String note;
}

const aiPresets = [
  AiPreset(
    'OpenRouter',
    'https://openrouter.ai/api/v1',
    'qwen/qwen-2.5-72b-instruct',
    'مفتاح واحد لعشرات النماذج المفتوحة (Qwen وLlama وغيرهم)، والدفع على قد الاستخدام.',
  ),
  AiPreset(
    'Groq',
    'https://api.groq.com/openai/v1',
    'llama-3.3-70b-versatile',
    'سريع جدًا، وفيه استخدام مجاني محدود، وبيحوّل التسجيلات الصوتية لنص كمان (Whisper).',
  ),
  AiPreset(
    'Ollama (سيرفرك)',
    'http://192.168.1.10:11434/v1',
    'qwen2.5:7b',
    'تشغّل النموذج على جهازك أو سيرفرك، من غير أي تكلفة على كل طلب.',
  ),
];

/// Sends notes to an open-source model, either through the app's server
/// function (the release setup, where the key stays on the server) or
/// straight to a provider with a key saved on this device (for testing).
class AiService extends ChangeNotifier {
  AiService({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;
  String serverUrl = '';
  String baseUrl = '';
  String apiKey = '';
  String model = '';

  /// Speech model for turning saved recordings into text.
  String sttModel = '';
  bool loaded = false;

  static const defaultSttModel = 'whisper-large-v3-turbo';

  bool get configured =>
      serverUrl.isNotEmpty || (baseUrl.isNotEmpty && model.isNotEmpty);

  Future<File> _file() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/ai.json');

  Future<void> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        serverUrl = j['server'] as String? ?? '';
        baseUrl = j['base'] as String? ?? '';
        apiKey = j['key'] as String? ?? '';
        model = j['model'] as String? ?? '';
        sttModel = j['stt'] as String? ?? '';
      }
    } catch (e) {
      debugPrint('AI settings unreadable: $e');
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> save({
    required String server,
    required String base,
    required String key,
    required String model,
    String? stt,
  }) async {
    serverUrl = server.trim();
    baseUrl = base.trim().replaceAll(RegExp(r'/+$'), '');
    apiKey = key.trim();
    this.model = model.trim();
    if (stt != null) sttModel = stt.trim();
    final f = await _file();
    await f.writeAsString(
      jsonEncode({
        'server': serverUrl,
        'base': baseUrl,
        'key': apiKey,
        'model': this.model,
        'stt': sttModel,
      }),
    );
    notifyListeners();
  }

  /// Runs [task] on [notes] and returns the answer text.
  Future<String> run(AiTask task, String notes, {String? question}) async {
    if (notes.trim().isEmpty) {
      throw AiError('مفيش نص في الملاحظات لسه. اكتب أو سجّل الأول.');
    }
    if (serverUrl.isNotEmpty) return _viaServer(task, notes, question);
    if (baseUrl.isNotEmpty && model.isNotEmpty) {
      return _direct(task, notes, question);
    }
    throw AiError(
      'المساعد محتاج إعداد الأول. افتح الإعدادات من الشاشة الرئيسية.',
    );
  }

  Future<String> _viaServer(AiTask task, String notes, String? q) async {
    final res = await _send(
      () => _http.post(
        Uri.parse(serverUrl),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'task': task.name, 'notes': notes, 'question': q}),
      ),
    );
    final body = _json(res);
    final error = body['error'];
    if (res.statusCode != 200 || error is String) {
      throw AiError(
        error is String ? error : 'السيرفر رجّع خطأ ${res.statusCode}',
      );
    }
    return (body['text'] as String? ?? '').trim();
  }

  Future<String> _direct(AiTask task, String notes, String? q) async {
    final res = await _send(
      () => _http.post(
        Uri.parse('$baseUrl/chat/completions'),
        headers: {
          'content-type': 'application/json',
          if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
        },
        body: jsonEncode(buildRequest(model, task, notes, q)),
      ),
    );
    final body = _json(res);
    if (res.statusCode != 200) {
      throw AiError(switch (res.statusCode) {
        401 || 403 => 'المفتاح غلط أو مالوش صلاحية. راجعه في الإعدادات.',
        402 => 'الحساب مفيهوش رصيد كفاية.',
        404 => 'اسم النموذج أو الرابط غلط. راجعهم في الإعدادات.',
        429 => 'طلبات كتير ورا بعض. استنى دقيقة وجرّب تاني.',
        >= 500 => 'الخدمة مشغولة دلوقتي. جرّب كمان شوية.',
        _ => 'الطلب اترفض (${res.statusCode}).',
      });
    }
    return parseAnswer(body);
  }

  /// Turns a saved recording into timed text with a Whisper model on the
  /// same provider (Groq and most OpenAI-compatible hosts offer one).
  Future<List<TranscriptPiece>> transcribe(File audio) async {
    if (baseUrl.isEmpty) {
      throw AiError(
        'تحويل التسجيل لنص محتاج إعداد المساعد الأول (Groq مثلًا). افتح إعدادات المساعد.',
      );
    }
    final req =
        http.MultipartRequest(
            'POST',
            Uri.parse('$baseUrl/audio/transcriptions'),
          )
          ..fields['model'] = sttModel.isEmpty ? defaultSttModel : sttModel
          ..fields['language'] = 'ar'
          ..fields['response_format'] = 'verbose_json'
          ..files.add(await http.MultipartFile.fromPath('file', audio.path));
    if (apiKey.isNotEmpty) req.headers['authorization'] = 'Bearer $apiKey';
    final res = await _send(
      () async => http.Response.fromStream(await _http.send(req)),
    );
    final body = _json(res);
    if (res.statusCode != 200) {
      throw AiError(switch (res.statusCode) {
        401 || 403 => 'المفتاح غلط أو مالوش صلاحية. راجعه في الإعدادات.',
        404 || 400 => 'المزوّد ده مش بيحوّل الصوت لنص. استخدم Groq، أو اكتب اسم نموذج الصوت في الإعدادات.',
        413 => 'التسجيل كبير على المزوّد. جرّب تسجيل أقصر.',
        429 => 'طلبات كتير ورا بعض. استنى دقيقة وجرّب تاني.',
        _ => 'الطلب اترفض (${res.statusCode}).',
      });
    }
    return parseTranscription(body);
  }

  Future<http.Response> _send(Future<http.Response> Function() call) async {
    try {
      return await call().timeout(const Duration(seconds: 180));
    } on SocketException {
      throw AiError('مش قادر أوصل للخدمة. اتأكد من النت ومن الرابط.');
    } on http.ClientException {
      throw AiError('مش قادر أوصل للخدمة. اتأكد من النت ومن الرابط.');
    } on FormatException {
      throw AiError('الرابط مكتوب غلط. راجعه في الإعدادات.');
    } on Exception {
      throw AiError('الطلب خد وقت طويل. جرّب تاني.');
    }
  }

  Map<String, dynamic> _json(http.Response res) {
    try {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }
}

/// A chat-completions request, the protocol open model hosts share.
@visibleForTesting
Map<String, dynamic> buildRequest(
  String model,
  AiTask task,
  String notes,
  String? q,
) => {
  'model': model,
  'temperature': 0.3,
  'messages': [
    {'role': 'system', 'content': _system},
    {
      'role': 'user',
      'content': '<notes>\n$notes\n</notes>\n\n${_instruction(task, q)}',
    },
  ],
};

/// Pulls the answer text out of a chat-completions response. Reasoning
/// models may wrap their thinking in `<think>` tags; that part is dropped.
@visibleForTesting
String parseAnswer(Map<String, dynamic> body) {
  final choices = body['choices'] as List? ?? const [];
  final message = choices.isEmpty ? null : (choices.first as Map)['message'];
  var text = message is Map ? (message['content'] as String? ?? '') : '';
  text = text.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
  if (text.isEmpty) throw AiError('ما رجعش رد. جرّب تاني.');
  return text;
}

/// Reads a Whisper "verbose_json" answer into timed pieces, falling back to
/// the plain text when there are no segments.
@visibleForTesting
List<TranscriptPiece> parseTranscription(Map<String, dynamic> body) {
  final segments = body['segments'] as List? ?? const [];
  final pieces = [
    for (final s in segments.whereType<Map>())
      if ((s['text'] as String? ?? '').trim().isNotEmpty)
        TranscriptPiece(
          Duration(milliseconds: (((s['start'] as num?) ?? 0) * 1000).round()),
          (s['text'] as String).trim(),
        ),
  ];
  if (pieces.isNotEmpty) return pieces;
  final text = (body['text'] as String? ?? '').trim();
  if (text.isEmpty) throw AiError('ما اتسمعش كلام في التسجيل ده.');
  return [TranscriptPiece(Duration.zero, text)];
}
