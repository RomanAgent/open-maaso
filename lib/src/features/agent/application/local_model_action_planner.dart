import 'dart:convert';

import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/local_agent_runtime.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';

typedef LocalActionCompleter =
    Future<String?> Function(List<({String role, String content})> messages);

class LocalModelActionPlanner implements LocalAgentPlanner {
  LocalModelActionPlanner({
    required LocalActionCompleter complete,
    AppLocale Function()? localeProvider,
  }) : _complete = complete,
       _localeProvider =
           localeProvider ?? (() => AgentPromptCatalog.currentLocale);

  final LocalActionCompleter _complete;
  final AppLocale Function() _localeProvider;

  @override
  Future<LocalAgentAction> next(LocalAgentTurn turn) async {
    final locale = _localeProvider();
    final raw = await _complete(_messagesFor(turn, locale));
    return parseAction(raw, locale: locale);
  }

  List<({String role, String content})> _messagesFor(
    LocalAgentTurn turn,
    AppLocale locale,
  ) {
    return [
      (
        role: 'system',
        content: AgentPromptCatalog.text(
          'runtime.local_action.system',
          locale: locale,
        ),
      ),
      (
        role: 'user',
        content: jsonEncode({
          'user': turn.userText,
          'step': turn.step,
          'skills': [
            for (final candidate in turn.candidates)
              _manifestPromptJson(candidate, locale),
          ],
          'observations': [
            for (final o in turn.observations)
              {
                'skill': o.skillId,
                'status': o.status.name,
                'output': _cap(o.output, 800),
              },
          ],
        }),
      ),
    ];
  }

  Map<String, dynamic> _manifestPromptJson(
    LocalSkillManifest manifest,
    AppLocale locale,
  ) {
    final promptKey = _localManifestPromptKeys[manifest.id];
    return {
      'id': manifest.id,
      'summary': promptKey == null
          ? manifest.summary
          : AgentPromptCatalog.text(promptKey, locale: locale),
      'args_schema': manifest.argsSchema,
      'risk': manifest.risk.name,
    };
  }

  static const _localManifestPromptKeys = <String, String>{
    'todo': 'runtime.local_manifest.todo',
    'scheduled_task': 'runtime.local_manifest.scheduled_task',
    'ble_yoturetoys_projector':
        'runtime.local_manifest.ble_yoturetoys_projector',
  };

  static LocalAgentAction parseAction(String? raw, {AppLocale? locale}) {
    LocalAgentAction clarify() => LocalAgentAction.ask(
      AgentPromptCatalog.text('app.home.local_agent_clarify', locale: locale),
    );

    if (raw == null || raw.trim().isEmpty) {
      return clarify();
    }
    try {
      final decoded = jsonDecode(raw.trim());
      if (decoded is! Map) return clarify();
      final type = decoded['type']?.toString();
      switch (type) {
        case 'call':
          final skill = decoded['skill']?.toString() ?? '';
          final args = decoded['args'];
          if (args is! Map) return clarify();
          return LocalAgentAction.call(skill, Map<String, dynamic>.from(args));
        case 'ask':
          return LocalAgentAction.ask(decoded['question']?.toString() ?? '');
        case 'speak':
          return LocalAgentAction.speak(decoded['text']?.toString() ?? '');
        case 'finish':
          return LocalAgentAction.finish(decoded['text']?.toString() ?? '');
        default:
          return clarify();
      }
    } catch (_) {
      return clarify();
    }
  }

  static String _cap(String value, int maxChars) {
    if (value.length <= maxChars) return value;
    return '${value.substring(0, maxChars)}...';
  }
}
