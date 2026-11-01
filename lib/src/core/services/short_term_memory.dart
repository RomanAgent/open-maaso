import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';

class ChatTurn {
  final String role;
  final String content;
  final DateTime timestamp;
  final bool isSummary;

  ChatTurn({
    required this.role,
    required this.content,
    this.isSummary = false,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() => toPromptString();

  String toPromptString({AppLocale? locale}) {
    final prefix = isSummary
        ? AgentPromptCatalog.text(
            'app.memory.short.summary_prefix',
            locale: locale,
          )
        : '';
    final roleLabel = AgentPromptCatalog.text(switch (role.toLowerCase()) {
      'user' => 'app.memory.short.role.user',
      'agent' => 'app.memory.short.role.agent',
      'system' => 'app.memory.short.role.system',
      _ => 'app.memory.short.role.other',
    }, locale: locale);
    return '$prefix$roleLabel: $content';
  }
}

class ShortTermMemory extends AppService {
  final List<ChatTurn> _buffer = [];
  static const _maxTurns = 20;
  static const _compressBatch = 5;

  LLMProxyService get _llm => appServices.find<LLMProxyService>();

  Future<ShortTermMemory> init() async => this;

  void appendUser(String text) {
    _buffer.add(ChatTurn(role: 'user', content: text));
    _maybeCompress();
  }

  void appendAgent(String text) {
    _buffer.add(ChatTurn(role: 'agent', content: text));
  }

  void _maybeCompress() {
    if (_buffer.length <= _maxTurns) return;
    _compressOldest();
  }

  Future<void> _compressOldest() async {
    if (_buffer.length < _compressBatch) return;

    final old = _buffer.take(_compressBatch).toList();
    final summary = await _summarize(old);

    _buffer.removeRange(0, _compressBatch);
    _buffer.insert(
      0,
      ChatTurn(role: 'system', content: summary, isSummary: true),
    );
  }

  Future<String> _summarize(List<ChatTurn> turns) async {
    final locale = AgentPromptCatalog.currentLocale;
    final transcript = turns
        .map((t) => t.toPromptString(locale: locale))
        .join('\n');
    try {
      final result = await _llm.chat(
        AgentPromptCatalog.text(
          'app.memory.short.compress',
          locale: locale,
          params: <String, Object?>{'transcript': transcript},
        ),
      );
      return result.trim().isEmpty ? transcript : result.trim();
    } catch (_) {
      return turns.map((t) => t.toPromptString(locale: locale)).join('; ');
    }
  }

  String toContextBlock({AppLocale? locale}) {
    if (_buffer.isEmpty) return '';
    final buf = StringBuffer()
      ..writeln(
        AgentPromptCatalog.text(
          'app.memory.short.context_header',
          locale: locale,
        ),
      );
    for (final t in _buffer) {
      buf.writeln(t.toPromptString(locale: locale));
    }
    return buf.toString();
  }

  List<ChatTurn> get turns => List.unmodifiable(_buffer);

  void clear() {
    _buffer.clear();
  }
}
