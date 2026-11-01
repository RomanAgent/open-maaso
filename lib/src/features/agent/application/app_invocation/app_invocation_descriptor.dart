import 'package:maaso/src/core/security/action_schema_validator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';

/// Runtime families, not business categories or lists of permitted functions.
enum AppInvocationRuntimeKind {
  surfaceWebApp,
  legacySurface,
  workerCanvas,
  projectBundleApplet,
  trustedGame,
}

enum AppInvocationDocumentSource { author, absent }

/// Fixed source identity supplied by the source repository, never a grant.
final class AppInvocationIdentity {
  AppInvocationIdentity({
    required this.scopeKey,
    required this.sourceId,
    required this.revisionId,
    required this.sourceDigest,
  }) {
    if (scopeKey.trim().isEmpty ||
        sourceId.trim().isEmpty ||
        revisionId.trim().isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sourceDigest)) {
      throw ArgumentError('invalid_invocation_identity');
    }
  }

  final String scopeKey, sourceId, revisionId, sourceDigest;

  bool matches(AppInvocationIdentity other) =>
      scopeKey == other.scopeKey &&
      sourceId == other.sourceId &&
      revisionId == other.revisionId &&
      sourceDigest == other.sourceDigest;

  Map<String, Object?> toJson() => {
    'scopeKey': scopeKey,
    'sourceId': sourceId,
    'revisionId': revisionId,
    'sourceDigest': sourceDigest,
  };
}

/// Exact declared action plus its existing runtime's argument-schema projection.
/// Neither a declared effect nor an author-supplied risk grants permission.
final class AppInvocationActionDescriptor {
  AppInvocationActionDescriptor._({
    required this.name,
    required Map<String, Object?> sourceContract,
    required Map<String, Object?> argumentsSchema,
  }) : sourceContract = _snapshot(sourceContract),
       argumentsSchema = _snapshot(argumentsSchema);

  final String name;
  final Map<String, Object?> sourceContract;
  final Map<String, Object?> argumentsSchema;
}

/// Immutable content metadata only. Construction does not run or authorize an
/// app, prove a handler exists, or certify storage isolation. Descriptions must
/// still be paired with current host evidence and a separate native grant.
final class AppInvocationDescriptor {
  AppInvocationDescriptor._({
    required this.identity,
    required this.runtimeKind,
    required this.requiresGameAuthority,
    required List<AppInvocationActionDescriptor> actions,
    required Map<String, Object?> sourceContract,
    required Map<String, String> documents,
    required List<String> contractIssues,
  }) : actions = List.unmodifiable(actions),
       sourceContract = _snapshot(sourceContract),
       documents = Map.unmodifiable(documents),
       contractIssues = List.unmodifiable(contractIssues) {
    documentSource = documents.values.any((value) => value.trim().isNotEmpty)
        ? AppInvocationDocumentSource.author
        : AppInvocationDocumentSource.absent;
    documentDigest = projectBundleV2JsonDigest(documents);
    contractDigest = projectBundleV2JsonDigest({
      'descriptorVersion': 1,
      'identity': identity.toJson(),
      'runtimeKind': runtimeKind.name,
      'requiresGameAuthority': requiresGameAuthority,
      'sourceContract': this.sourceContract,
      'documentDigest': documentDigest,
    });
  }

  factory AppInvocationDescriptor.fromSurface({
    required SurfaceProject project,
    required AppInvocationIdentity identity,
  }) {
    if (project.rendering == SurfaceRendering.projectBundle) {
      throw const FormatException('invocation_requires_validated_bundle');
    }
    if (identity.sourceId != project.id) {
      throw ArgumentError('invocation_source_identity_mismatch');
    }
    final manifest = project.manifest;
    final issues = <String>[...manifest.diagnoseContract()];
    if (manifest.actions.length > SurfaceManifest.maxEntriesPerKind) {
      issues.add('invocation_action_budget_exceeded');
    }
    final names = <String>{};
    final actions = <AppInvocationActionDescriptor>[];
    for (final entry in manifest.actions) {
      if (entry.name.isEmpty || !names.add(entry.name)) {
        issues.add('invocation_action_name_invalid');
      }
      final schema = entry.jsonSchema;
      if (!const ActionSchemaValidator()
          .validate(schema: schema, value: null)
          .schemaValid) {
        issues.add('invocation_action_schema_invalid');
      }
      actions.add(
        AppInvocationActionDescriptor._(
          name: entry.name,
          sourceContract: entry.toJson(),
          argumentsSchema: schema,
        ),
      );
    }
    return AppInvocationDescriptor._(
      identity: identity,
      runtimeKind: switch (project.rendering) {
        SurfaceRendering.webApp => AppInvocationRuntimeKind.surfaceWebApp,
        SurfaceRendering.workerCanvas => AppInvocationRuntimeKind.workerCanvas,
        _ => AppInvocationRuntimeKind.legacySurface,
      },
      // A browser game's declared page operations do not control a native
      // rules engine or player seat. Worker/trusted protocols retain their
      // separate game authority instead of inferring it from a UI category.
      requiresGameAuthority:
          project.rendering == SurfaceRendering.workerCanvas &&
          (project.experienceType == SurfaceExperienceType.game ||
              project.category == 'game'),
      actions: actions,
      sourceContract: manifest.toJson(),
      documents: {
        'skillInstructions': project.skillInstructions,
        'manifest.instructions': manifest.instructions,
      },
      contractIssues: issues.toSet().toList(),
    );
  }

  /// Deliberately has no raw JSON alternative. Missing V2 documents/protocols
  /// must fail the existing codec; they cannot enter a legacy fallback here.
  factory AppInvocationDescriptor.fromValidatedBundle({
    required ValidatedProjectBundleV2 bundle,
    required String scopeKey,
  }) => AppInvocationDescriptor._(
    identity: AppInvocationIdentity(
      scopeKey: scopeKey,
      sourceId: bundle.manifest.projectId,
      revisionId: bundle.manifest.revisionId,
      sourceDigest: bundle.candidateDigest,
    ),
    runtimeKind: bundle.protocol.isTrustedGame
        ? AppInvocationRuntimeKind.trustedGame
        : AppInvocationRuntimeKind.projectBundleApplet,
    requiresGameAuthority: bundle.protocol.isTrustedGame,
    actions: [
      for (final action in bundle.protocol.actions)
        AppInvocationActionDescriptor._(
          name: action['id']! as String,
          sourceContract: action,
          argumentsSchema: Map<String, Object?>.from(
            action['argsSchema']! as Map,
          ),
        ),
    ],
    sourceContract: bundle.protocol.toJson(),
    documents: {'agent.md': bundle.agentMarkdown},
    contractIssues: const [],
  );

  final AppInvocationIdentity identity;
  final AppInvocationRuntimeKind runtimeKind;
  final bool requiresGameAuthority;
  final List<AppInvocationActionDescriptor> actions;
  final Map<String, Object?> sourceContract;
  final Map<String, String> documents;
  final List<String> contractIssues;
  late final AppInvocationDocumentSource documentSource;
  late final String documentDigest, contractDigest;
}

Map<String, Object?> _snapshot(Map<String, Object?> value) {
  // Validate JSON/budgets without parsing the canonical bytes back into the
  // source contract: JCS number serialization can round large Dart integers.
  const ProjectJsonCanonicalizer().canonicalize(value);
  return _freeze(value)! as Map<String, Object?>;
}

Object? _freeze(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freeze(entry.value),
    });
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}
