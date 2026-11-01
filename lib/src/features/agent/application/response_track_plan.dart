import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';

class ResponseTrackPlan {
  const ResponseTrackPlan({
    this.expression = false,
    this.voice = false,
    this.skill = false,
    this.surface = false,
  });

  static const none = ResponseTrackPlan();

  final bool expression;
  final bool voice;
  final bool skill;
  final bool surface;

  bool get hasAny => expression || voice || skill || surface;

  List<String> get names => [
    if (expression) 'expression',
    if (voice) 'voice',
    if (skill) 'skill',
    if (surface) 'surface',
  ];

  String get promptDirective =>
      promptDirectiveFor(AgentPromptCatalog.currentLocale);

  String promptDirectiveFor(AppLocale locale) {
    if (!hasAny) return '';
    return AgentPromptCatalog.text(
      'runtime.response_track.directive',
      locale: locale,
      params: {'tracks': names.join(',')},
    );
  }

  static ResponseTrackPlan forTurn({
    required bool hasSkillWork,
    required SurfaceIntent surface,
  }) {
    return ResponseTrackPlan(
      expression: true,
      voice: true,
      skill: hasSkillWork || surface.isSurface,
      surface: surface.isSurface,
    );
  }
}
