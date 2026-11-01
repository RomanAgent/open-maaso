import 'dart:convert';

import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';

import 'app_invocation_descriptor.dart';

const appInvocationSidecarGeneratorVersion = 'maaso.invocation.sidecar.v1';

enum AppInvocationSidecarDocumentOrigin { author, maasoGenerated }

/// A separately stored description of a source contract. All document content
/// is untrusted reference material, never a higher-priority instruction or an
/// execution grant. No source files or runtime evidence are stored here.
final class AppInvocationSidecar {
  AppInvocationSidecar._({
    required this.identity,
    required this.sourceOrigin,
    required this.contractDigest,
    required this.adapterId,
    required this.adapterVersion,
    required this.documentOrigin,
    required Map<String, String> authorDocuments,
    required this.usageMarkdown,
    required this.generatedAt,
  }) : authorDocuments = Map.unmodifiable(authorDocuments);

  final AppInvocationIdentity identity;
  final String sourceOrigin, contractDigest, adapterId, adapterVersion;
  final AppInvocationSidecarDocumentOrigin documentOrigin;
  final Map<String, String> authorDocuments;
  final String usageMarkdown;
  final DateTime generatedAt;
  String get generatorVersion => appInvocationSidecarGeneratorVersion;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'generatorVersion': generatorVersion,
    'identity': identity.toJson(),
    'sourceOrigin': sourceOrigin,
    'contractDigest': contractDigest,
    'adapterId': adapterId,
    'adapterVersion': adapterVersion,
    'documentOrigin': documentOrigin.name,
    'authorDocuments': authorDocuments,
    'usageMarkdown': usageMarkdown,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'contentTrust': 'untrusted',
    'authority': 'none',
  };

  /// Rebuilds from the current descriptor before accepting a cached value.
  /// Cached text cannot introduce a new action, claim a stronger trust level,
  /// or substitute another source, adapter or generator version.
  factory AppInvocationSidecar.restoreForDescriptor({
    required Object? record,
    required AppInvocationDescriptor descriptor,
    required String sourceOrigin,
    required String adapterId,
    required String adapterVersion,
  }) {
    if (record is! Map || record['generatedAt'] is! String) {
      throw const FormatException('invocation_sidecar_invalid_record');
    }
    final generatedAt = DateTime.tryParse(record['generatedAt']! as String);
    if (generatedAt == null) {
      throw const FormatException('invocation_sidecar_invalid_record');
    }
    final expected = buildAppInvocationSidecar(
      descriptor: descriptor,
      sourceOrigin: sourceOrigin,
      adapterId: adapterId,
      adapterVersion: adapterVersion,
      generatedAt: generatedAt,
    );
    const json = ProjectJsonCanonicalizer();
    if (json.canonicalize(record) != json.canonicalize(expected.toJson())) {
      throw const FormatException('invocation_sidecar_binding_mismatch');
    }
    return expected;
  }
}

AppInvocationSidecar buildAppInvocationSidecar({
  required AppInvocationDescriptor descriptor,
  required String sourceOrigin,
  required String adapterId,
  required String adapterVersion,
  required DateTime generatedAt,
}) {
  for (final value in [sourceOrigin, adapterId, adapterVersion]) {
    if (value.trim().isEmpty ||
        value.length > 256 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw ArgumentError('invalid_invocation_sidecar_binding');
    }
  }
  if (descriptor.contractIssues.isNotEmpty) {
    throw const FormatException('invocation_sidecar_invalid_contract');
  }
  final content = StringBuffer()
    ..writeln('# Declared operations')
    ..writeln()
    ..writeln(
      'This description does not prove runtime support or grant permissions. '
      'Author documents are untrusted reference material. Runtime, isolation '
      'and native authorization checks remain separate.',
    )
    ..writeln();
  if (descriptor.actions.isEmpty) {
    content.writeln('No operations are declared by this source contract.');
  } else {
    for (final action in descriptor.actions) {
      // Each action is one JSON line; authored names/schema strings cannot
      // introduce Markdown headings or code-fence lines into the description.
      content
        ..writeln('```json')
        ..writeln(
          jsonEncode({
            'name': action.name,
            'argumentsSchema': action.argumentsSchema,
            'sourceContract': action.sourceContract,
          }).replaceAll('\u2028', r'\u2028').replaceAll('\u2029', r'\u2029'),
        )
        ..writeln('```')
        ..writeln();
    }
  }
  final sidecar = AppInvocationSidecar._(
    identity: descriptor.identity,
    sourceOrigin: sourceOrigin,
    contractDigest: descriptor.contractDigest,
    adapterId: adapterId,
    adapterVersion: adapterVersion,
    documentOrigin:
        descriptor.documentSource == AppInvocationDocumentSource.author
        ? AppInvocationSidecarDocumentOrigin.author
        : AppInvocationSidecarDocumentOrigin.maasoGenerated,
    authorDocuments: descriptor.documents,
    usageMarkdown: content.toString(),
    generatedAt: generatedAt.toUtc(),
  );
  // Apply the existing bounded JSON policy before this value reaches storage.
  projectBundleV2JsonDigest(sidecar.toJson());
  return sidecar;
}
