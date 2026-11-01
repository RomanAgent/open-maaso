import 'package:maaso/src/features/agent/application/local_skill_risk.dart';

enum CapabilityKind { navigate, action }

/// Outcome of running a capability. [message] is a short English status string
/// (the agent phrases the user-facing reply itself). [needsConfirm] is reserved
/// for Phase 3/4 destructive actions; always false for navigation.
class CapabilityResult {
  final bool ok;
  final String message;
  final bool needsConfirm;

  const CapabilityResult({
    required this.ok,
    required this.message,
    this.needsConfirm = false,
  });

  factory CapabilityResult.ok(String message) =>
      CapabilityResult(ok: true, message: message);

  factory CapabilityResult.error(String message) =>
      CapabilityResult(ok: false, message: message);
}

/// One agent-invocable thing in the app — a navigation target or (Phase 3) an
/// in-page action. The single source of truth that generates both runtime
/// bridges (cloud AgentSkill + on-device LocalSkillManifest).
class Capability {
  /// Stable id, e.g. 'nav.settings'.
  final String id;
  final CapabilityKind kind;

  /// Localized title shown to the LLM, e.g. `Settings` or `设置`.
  final String _title;
  final String Function()? _titleResolver;
  String get title => _titleResolver?.call() ?? _title;

  /// Localized description used in LLM prompts.
  final String _description;
  final String Function()? _descriptionResolver;
  String get description => _descriptionResolver?.call() ?? _description;

  /// EN + ZH; drives retrieval + slash aliases.
  final List<String> keywords;
  final Map<String, dynamic> argsSchema;
  final LocalSkillRisk risk;
  final CapabilityResult Function(Map<String, dynamic> args) run;

  const Capability({
    required this.id,
    required this.kind,
    required String title,
    required String description,
    required this.keywords,
    required this.run,
    String Function()? titleResolver,
    String Function()? descriptionResolver,
    this.argsSchema = const {},
    this.risk = LocalSkillRisk.read,
  }) : _title = title,
       _description = description,
       _titleResolver = titleResolver,
       _descriptionResolver = descriptionResolver;
}
