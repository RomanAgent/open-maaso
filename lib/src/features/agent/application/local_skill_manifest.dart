import 'package:maaso/src/features/agent/application/local_skill_risk.dart';

export 'package:maaso/src/features/agent/application/local_skill_risk.dart';

abstract class LocalSkillManifestProvider {
  LocalSkillManifest? get localManifest;
}

/// Compact local-only metadata for skills that the on-device agent may see.
///
/// This is deliberately separate from the cloud JS prompt/manual. The local
/// model receives only a few retrieved manifests per turn, while cloud runtime
/// continues to use the full [SkillCatalog] + [AgentSkill] prompt surface.
class LocalSkillManifest {
  final String id;
  final String skillName;
  final String method;
  final String summary;
  final List<String> tags;
  final Map<String, dynamic> argsSchema;

  /// Args bound to this manifest at registration time (e.g. a navigation
  /// destination's page id). Merged into the planner-supplied args by
  /// [LocalSkillInvoker] before the handler runs; fixed host args win on
  /// collision so the model cannot redirect a pre-authorized operation.
  final Map<String, dynamic> fixedArgs;

  final LocalSkillRisk risk;
  final bool localEligible;

  const LocalSkillManifest({
    required this.id,
    required this.skillName,
    required this.method,
    required this.summary,
    required this.tags,
    required this.argsSchema,
    this.fixedArgs = const {},
    this.risk = LocalSkillRisk.read,
    this.localEligible = true,
  });

  bool get requiresConfirmation =>
      risk == LocalSkillRisk.sideEffect || risk == LocalSkillRisk.unsafe;

  Map<String, dynamic> toPromptJson() => {
    'id': id,
    'summary': summary,
    'args_schema': argsSchema,
    'risk': risk.name,
  };

  static List<LocalSkillManifest> fromCatalog(
    Iterable<LocalSkillManifestProvider> specs,
  ) => [
    for (final spec in specs)
      if (spec.localManifest != null && spec.localManifest!.localEligible)
        spec.localManifest!,
  ];
}
