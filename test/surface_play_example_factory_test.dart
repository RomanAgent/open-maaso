import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'support/surface_play_example_factory_fixture.dart';

void main() {
  test(
    'all playable reference games are real production bundles with bound docs and controls',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'maaso-play-bundle-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      for (final rules in [
        'gomoku.v1',
        'cooperative-switches.v1',
        'private-cards.v1',
      ]) {
        final bundle = SurfacePlayExampleFactory.build(
          projectId: 'pb_project_00000000-0000-0000-0000-000000000001',
          revisionId: 'pb_revision_00000000-0000-0000-0000-000000000002',
          contentManifestId: 'pb_manifest_00000000-0000-0000-0000-000000000003',
          requirementDigest: 'a' * 64,
          rulesId: rules,
        );
        expect(bundle.protocol.rulesId, rules);
        expect(bundle.entryRouteId, 'game');
        expect(bundle.routes.map((route) => route.routeId), ['game', 'rules']);
        expect(bundle.agentMarkdown, contains('maaso.agent.document.v2'));
        final source = utf8.decode(bundle.files['src/main.js']!);
        expect(source, contains('Maaso.playSubmit(command)'));
        expect(source, isNot(contains('crypto.randomUUID')));
        expect(source, contains('crypto.getRandomValues(new Uint8Array(16))'));
        expect(source, contains("const requestId='r_'"));
        expect(source, contains('Maaso.onPlayState'));
        expect(source, contains("Maaso.navigate('rules'"));
        expect(source, contains('Maaso.back()'));
        expect(bundle.runtimeHtml, contains('maaso-white-frost'));
        expect(
          const ProjectBundleV2Codec()
              .decodeString(const ProjectBundleV2Codec().encode(bundle))
              .candidateDigest,
          bundle.candidateDigest,
        );
        // Standalone files are a review/test artifact, not a published fixture or
        // substitute for a model-generated deliverable.
        final prefix = '${directory.path}/example-${rules.split('.').first}';
        await File('$prefix.js').writeAsString(source);
        await File(
          '$prefix.bundle.json',
        ).writeAsString(const ProjectBundleV2Codec().encode(bundle));
      }
    },
  );
}
