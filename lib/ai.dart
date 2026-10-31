import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

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

/// Sends notes to Claude, either through the app's server function (the
/// release setup, where the key stays on the server) or straight to the API
/// with a key saved on this device (for testing before the server exists).
class AiService extends ChangeNotifier {
  AiService({http.Client? client}) : _http = client ?? http.Client();

  static const model = 'claude-opus-5-5';
  final http.Client _http;
  String serverUrl = '';
  String apiKey = '';
  bool loaded = false;

  bool get configured => serverUrl.isNotEmpty || apiKey.isNotEmpty;

  Future<File> _file() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/ai.json');

  Future<void> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        serverUrl = j['server'] as String? ?? '';
        apiKey = j['key'] as String? ?? '';
      }
    } catch (e) {
      debugPrint('AI settings unreadable: $e');
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> save({required String server, required String key}) async {
    serverUrl = server.trim();
    apiKey = key.trim();
    final f = await _file();
    await f.writeAsString(jsonEncode({'server': serverUrl, 'key': apiKey}));
    notifyListeners();
  }

  /// Runs [task] on [notes] and returns the answer text.
  Future<String> run(AiTask task, String notes, {String? question}) async {
    if (notes.trim().isEmpty) {
      throw AiError('مفيش نص في الملاحظات لسه. اكتب أو سجّل الأول.');
    }
    if (serverUrl.isNotEmpty) return _viaServer(task, notes, question);
    if (apiKey.isNotEmpty) return _direct(task, notes, question);
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

  /// Raw HTTP to the Messages API: Dart has no official Anthropic SDK.
  Future<String> _direct(AiTask task, String notes, String? q) async {
    final res = await _send(
      () => _http.post(
        Uri.parse('https://api.anthropic.com/v1/messages'),
        headers: {
          'content-type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2026-10-21',
          'anthropic-beta': 'server-side-fallback-2026-07-01',
        },
        body: jsonEncode(buildRequest(task, notes, q)),
      ),
    );
    final body = _json(res);
    if (res.statusCode != 200) {
      final err = body['error'];
      final type = err is Map ? err['type'] : null;
      throw AiError(switch (res.statusCode) {
        401 => 'مفتاح الخدمة غلط. راجعه في الإعدادات.',
        402 || 403 => 'الحساب مفيهوش رصيد أو صلاحية للخدمة.',
        429 => 'طلبات كتير ورا بعض. استنى دقيقة وجرّب تاني.',
        >= 500 => 'الخدمة مشغولة دلوقتي. جرّب كمان شوية.',
        _ => 'الطلب اترفض ($type).',
      });
    }
    return parseAnswer(body);
  }

  Future<http.Response> _send(Future<http.Response> Function() call) async {
    try {
      return await call().timeout(const Duration(seconds: 120));
    } on SocketException {
      throw AiError('مفيش إنترنت. المساعد محتاج اتصال.');
    } on http.ClientException {
      throw AiError('مفيش إنترنت. المساعد محتاج اتصال.');
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

@visibleForTesting
Map<String, dynamic> buildRequest(AiTask task, String notes, String? q) => {
  'model': AiService.model,
  'max_tokens': 16000,
  'fallbacks': 'default',
  'output_config': {
    'effort': task == AiTask.minutes || task == AiTask.ask ? 'medium' : 'low',
  },
  'system': _system,
  'messages': [
    {
      'role': 'user',
      'content': '<notes>\n$notes\n</notes>\n\n${_instruction(task, q)}',
    },
  ],
};

/// Pulls the answer text out of a Messages API response.
@visibleForTesting
String parseAnswer(Map<String, dynamic> body) {
  if (body['stop_reason'] == 'refusal') {
    throw AiError('المساعد رفض الطلب ده. جرّب صياغة تانية.');
  }
  final content = body['content'] as List? ?? const [];
  final text = [
    for (final b in content)
      if (b is Map && b['type'] == 'text') b['text'] as String,
  ].join().trim();
  if (text.isEmpty) throw AiError('ما رجعش رد. جرّب تاني.');
  return text;
}
