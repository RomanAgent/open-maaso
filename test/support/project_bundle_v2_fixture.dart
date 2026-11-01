import 'dart:convert';
import 'dart:io';

import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';

ValidatedProjectBundleV2 productionBundleFixture({int revision = 2}) {
  final raw =
      jsonDecode(
            File(
              'tool/fixtures/project_bundle_v2_golden.json',
            ).readAsStringSync(),
          )
          as Map;
  final original = const ProjectBundleV2Codec().decode(raw['bundle']);
  if (revision == 2) return original;
  final revisionId =
      'pb_revision_00000000-0000-0000-0000-${revision.toString().padLeft(12, '0')}';
  final contentId =
      'pb_manifest_00000000-0000-0000-0000-${(revision + 100).toString().padLeft(12, '0')}';
  final bytes = {
    for (final entry in original.files.entries)
      entry.key: List<int>.from(entry.value),
  };
  final jcs = const ProjectJsonCanonicalizer();
  for (final path in ['project.json', 'agent.protocol.json', 'routes.json']) {
    final value = Map<String, Object?>.from(
      jsonDecode(utf8.decode(bytes[path]!)) as Map,
    );
    value['revisionId'] = revisionId;
    if (path == 'project.json') value['contentManifestId'] = contentId;
    bytes[path] = jcs.canonicalBytes(value);
  }
  final lines = utf8.decode(bytes['agent.md']!).split('\n');
  final header = Map<String, Object?>.from(jsonDecode(lines[1]) as Map);
  header['revisionId'] = revisionId;
  header['contentManifestId'] = contentId;
  header['protocolSha256'] = projectBundleV2BytesDigest(
    bytes['agent.protocol.json']!,
  );
  lines[1] = jcs.canonicalize(header);
  bytes['agent.md'] = utf8.encode(lines.join('\n'));
  final files = [
    for (final metadata in original.manifest.files)
      ProjectBundleV2File(
        path: metadata.path,
        mimeType: metadata.mimeType,
        role: metadata.role,
        bytes: bytes[metadata.path]!,
      ),
  ];
  final manifest = ProjectBundleV2Manifest.create(
    projectId: original.manifest.projectId,
    revisionId: revisionId,
    contentManifestId: contentId,
    requirementRevision: revision - 1,
    requirementDigest: original.manifest.requirementDigest,
    baseRevision: original.manifest.revisionId,
    projectKind: original.manifest.projectKind,
    files: files.map((file) => file.metadata),
  );
  return const ProjectBundleV2Codec().verify(manifest, files);
}
