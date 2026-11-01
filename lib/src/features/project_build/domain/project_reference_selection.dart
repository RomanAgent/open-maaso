import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/features/agent/application/project_build/project_reference_input.dart';

export 'package:maaso/src/features/agent/application/project_build/project_reference_input.dart'
    show ProjectReferenceImage, ProjectReferencePurpose;

/// The user's immutable source selection. It contains no visual summary,
/// upload assertion or claim that a model has consumed the images.
final class ProjectReferenceSelection {
  ProjectReferenceSelection({
    required this.scopeKey,
    required List<ProjectReferenceImage> references,
    this.inputRevision = 1,
  }) : references = List.unmodifiable(references) {
    if (scopeKey.isEmpty ||
        scopeKey.length > 256 ||
        scopeKey.runes.any((r) => r < 32 || (r >= 127 && r <= 159)) ||
        inputRevision < 1 ||
        inputRevision > 1000000 ||
        references.isEmpty ||
        references.length > 4 ||
        references.any((image) => image.byteLength > maximumImageBytes) ||
        references.map((image) => image.sha256).toSet().length !=
            references.length) {
      throw const FormatException('project_reference_invalid_selection');
    }
  }

  static const maximumImageBytes = 2 * 1024 * 1024;
  final String scopeKey;
  final int inputRevision;
  final List<ProjectReferenceImage> references;

  /// Preserves the existing source-identity algorithm, including image order
  /// and purpose. Adapting an old analyzed snapshot does not invent a new input.
  String get sourceIdentityDigest => sha256
      .convert(
        utf8.encode(
          'maaso.project.reference-sources.v1\n${jsonEncode({'scopeKey': scopeKey, 'inputRevision': inputRevision, 'references': references.map((image) => image.toJson()).toList(growable: false)})}',
        ),
      )
      .toString();

  factory ProjectReferenceSelection.fromSnapshot(
    ProjectReferenceInputSnapshot snapshot,
  ) => ProjectReferenceSelection(
    scopeKey: snapshot.scopeKey,
    references: snapshot.references,
    inputRevision: snapshot.inputRevision,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'kind': 'project_reference_selection',
    'scopeKey': scopeKey,
    'inputRevision': inputRevision,
    'references': references.map((image) => image.toJson()).toList(),
    'sourceIdentityDigest': sourceIdentityDigest,
  };

  factory ProjectReferenceSelection.fromJson(Object? raw) {
    const keys = {
      'schemaVersion',
      'kind',
      'scopeKey',
      'inputRevision',
      'references',
      'sourceIdentityDigest',
    };
    if (raw is! Map ||
        raw.length != keys.length ||
        raw.keys.any((key) => !keys.contains(key)) ||
        raw['schemaVersion'] is! int ||
        raw['schemaVersion'] != 1 ||
        raw['kind'] != 'project_reference_selection' ||
        raw['scopeKey'] is! String ||
        raw['inputRevision'] is! int ||
        raw['references'] is! List) {
      throw const FormatException('project_reference_selection_fields');
    }
    final selection = ProjectReferenceSelection(
      scopeKey: raw['scopeKey']! as String,
      inputRevision: raw['inputRevision']! as int,
      references: (raw['references']! as List)
          .map(ProjectReferenceImage.fromJson)
          .toList(),
    );
    if (raw['sourceIdentityDigest'] != selection.sourceIdentityDigest) {
      throw const FormatException('project_reference_selection_digest');
    }
    return selection;
  }
}
