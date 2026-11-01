import 'agent_widget.dart';

/// Product formats that may remain in generated-work storage and entry points.
///
/// This is a structural retirement policy, not execution authority. Privileged
/// Applets still require their existing installation and signed-report checks.
enum AgentWidgetProductKind { webGame, webApplet, privilegedApplet, retired }

AgentWidgetProductKind classifyAgentWidgetProduct(AgentWidget widget) {
  if (!widget.isSurface) return AgentWidgetProductKind.retired;
  final spec = widget.spec;
  final experience = spec['experienceType'];
  if (experience != 'game' && experience != 'utility') {
    return AgentWidgetProductKind.retired;
  }
  if (experience == 'utility' && spec['category'] == 'game') {
    return AgentWidgetProductKind.retired;
  }
  if (spec['rendering'] == 'webApp' && !spec.containsKey('bundleReference')) {
    return experience == 'game'
        ? AgentWidgetProductKind.webGame
        : AgentWidgetProductKind.webApplet;
  }
  if (experience != 'utility' || spec['rendering'] != 'projectBundle') {
    return AgentWidgetProductKind.retired;
  }
  final reference = spec['bundleReference'];
  if (reference is! Map ||
      reference.length != 5 ||
      reference['packageSchema'] != 2) {
    return AgentWidgetProductKind.retired;
  }
  for (final key in const [
    'projectId',
    'revisionId',
    'candidateDigest',
    'reportDigest',
  ]) {
    final value = reference[key];
    if (value is! String || value.trim().isEmpty) {
      return AgentWidgetProductKind.retired;
    }
  }
  return AgentWidgetProductKind.privilegedApplet;
}

bool isCurrentAgentWidgetProduct(AgentWidget widget) =>
    classifyAgentWidgetProduct(widget) != AgentWidgetProductKind.retired;

bool isRetiredAgentWidgetProduct(AgentWidget widget) =>
    classifyAgentWidgetProduct(widget) == AgentWidgetProductKind.retired;
