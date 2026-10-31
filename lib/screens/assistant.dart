import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai.dart';
import '../models.dart';
import '../recognition.dart';

/// Collects the text of [pages] (converting handwriting where a page has no
/// text yet) and, optionally, recording transcripts.
Future<String> gatherNotes(
  List<NotePage> pages, {
  List<Recording> recordings = const [],
}) async {
  final reader = HandwritingReader.instance;
  final parts = <String>[];
  for (var i = 0; i < pages.length; i++) {
    final p = pages[i];
    var text = p.text?.trim() ?? '';
    final hasInk = p.strokes.any((s) => s.tool == InkTool.pen);
    if (text.isEmpty && hasInk) {
      await reader.prepare();
      if (reader.ready) {
        text = (await reader.readPage(p)).map((l) => l.first).join('\n');
      }
    }
    final typed = p.typed.map((t) => t.text).where((t) => !text.contains(t));
    final all = [if (text.isNotEmpty) text, ...typed].join('\n').trim();
    if (all.isNotEmpty) {
      parts.add(pages.length > 1 ? 'صفحة ${i + 1}:\n$all' : all);
    }
  }
  for (final r in recordings) {
    final said = r.transcript.map((t) => t.text).join(' ').trim();
    if (said.isNotEmpty) parts.add('تفريغ تسجيل صوتي:\n$said');
  }
  return parts.join('\n\n');
}

/// Bottom sheet: pick what to ask the assistant and see the answer.
class AssistantSheet extends StatefulWidget {
  const AssistantSheet({
    super.key,
    required this.ai,
    required this.book,
    required this.page,
    required this.onInsert,
    required this.onOpenSettings,
  });

  final AiService ai;
  final Notebook book;
  final NotePage page;
  final void Function(List<String> lines) onInsert;
  final VoidCallback onOpenSettings;

  @override
  State<AssistantSheet> createState() => _AssistantSheetState();
}

class _AssistantSheetState extends State<AssistantSheet> {
  bool _wholeBook = false;
  bool _busy = false;
  String? _answer;
  String? _error;
  final _question = TextEditingController();

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  Future<void> _run(AiTask task) async {
    if (task == AiTask.ask && _question.text.trim().isEmpty) {
      setState(() => _error = 'اكتب سؤالك الأول.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _answer = null;
    });
    try {
      final notes = await gatherNotes(
        _wholeBook ? widget.book.pages : [widget.page],
        recordings: _wholeBook ? widget.book.recordings : const [],
      );
      final answer = await widget.ai.run(
        task,
        notes,
        question: _question.text.trim(),
      );
      if (mounted) setState(() => _answer = answer);
    } on AiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'حصلت مشكلة: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ai = widget.ai;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text('المساعد الذكي', style: theme.textTheme.titleLarge),
                  ],
                ),
                const SizedBox(height: 12),
                if (!ai.configured) ...[
                  const Text(
                    'المساعد محتاج إعداد مرة واحدة: تختار مزوّد النموذج المفتوح وتحط المفتاح.',
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.settings),
                    label: const Text('افتح إعدادات المساعد'),
                    onPressed: widget.onOpenSettings,
                  ),
                ] else ...[
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('الصفحة دي')),
                      ButtonSegment(
                        value: true,
                        label: Text('الدفتر كله مع التسجيلات'),
                      ),
                    ],
                    selected: {_wholeBook},
                    onSelectionChanged: _busy
                        ? null
                        : (v) => setState(() => _wholeBook = v.first),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final t in AiTask.values)
                        if (t != AiTask.ask)
                          ActionChip(
                            avatar: Icon(switch (t) {
                              AiTask.summary => Icons.short_text,
                              AiTask.minutes => Icons.checklist,
                              _ => Icons.translate,
                            }, size: 18),
                            label: Text(t.label),
                            onPressed: _busy ? null : () => _run(t),
                          ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _question,
                    enabled: !_busy,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _run(AiTask.ask),
                    decoration: InputDecoration(
                      hintText: 'اسأل عن ملاحظاتك… مثلًا: إيه المطلوب مني؟',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.send),
                        onPressed: _busy ? null : () => _run(AiTask.ask),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  if (_answer != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: SelectableText(
                        _answer!,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            icon: const Icon(Icons.vertical_align_bottom),
                            label: const Text('إدراج في الصفحة'),
                            onPressed: () {
                              widget.onInsert(
                                _answer!
                                    .split('\n')
                                    .map((l) => l.trimRight())
                                    .where((l) => l.isNotEmpty)
                                    .toList(),
                              );
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
                              Clipboard.setData(ClipboardData(text: _answer!));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('اتنسخ')),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Settings for where the assistant sends notes.
class AssistantSettingsScreen extends StatefulWidget {
  const AssistantSettingsScreen({super.key, required this.ai});
  final AiService ai;

  @override
  State<AssistantSettingsScreen> createState() =>
      _AssistantSettingsScreenState();
}

class _AssistantSettingsScreenState extends State<AssistantSettingsScreen> {
  late final _server = TextEditingController(text: widget.ai.serverUrl);
  late final _base = TextEditingController(text: widget.ai.baseUrl);
  late final _key = TextEditingController(text: widget.ai.apiKey);
  late final _model = TextEditingController(text: widget.ai.model);
  late final _stt = TextEditingController(text: widget.ai.sttModel);
  bool _show = false;
  String? _note;

  @override
  void dispose() {
    _server.dispose();
    _base.dispose();
    _key.dispose();
    _model.dispose();
    _stt.dispose();
    super.dispose();
  }

  void _usePreset(AiPreset p) {
    setState(() {
      _base.text = p.baseUrl;
      _model.text = p.modelHint;
      _note = p.note;
    });
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: c,
      obscureText: secret && !_show,
      textDirection: TextDirection.ltr,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        suffixIcon: secret
            ? IconButton(
                icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _show = !_show),
              )
            : null,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('إعدادات المساعد الذكي')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('نموذج مفتوح المصدر', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'اختار مزوّد، أو اكتب رابط أي خدمة متوافقة مع OpenAI. المفتاح بيتحفظ على الجهاز ده بس.',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final p in aiPresets)
                ActionChip(label: Text(p.name), onPressed: () => _usePreset(p)),
            ],
          ),
          if (_note != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_note!, style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: 12),
          _field(_base, 'رابط الخدمة', hint: 'https://…/v1'),
          _field(_model, 'اسم النموذج', hint: 'qwen/qwen-2.5-72b-instruct'),
          _field(_key, 'المفتاح (لو الخدمة محتاجاه)', secret: true),
          _field(
            _stt,
            'نموذج تحويل التسجيلات لنص',
            hint: AiService.defaultSttModel,
          ),
          const Divider(height: 32),
          Text('أو: سيرفر FUTURENOTE', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'لما نرفع السيرفر، المفتاح هيبقى عليه بدل الموبايل. لو الرابط ده مكتوب، المساعد هيستخدمه.',
          ),
          const SizedBox(height: 8),
          _field(
            _server,
            'رابط السيرفر',
            hint: 'https://….supabase.co/functions/v1/ai',
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () async {
              await widget.ai.save(
                server: _server.text,
                base: _base.text,
                key: _key.text,
                model: _model.text,
                stt: _stt.text,
              );
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }
}
