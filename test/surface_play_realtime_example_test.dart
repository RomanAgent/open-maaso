import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'support/surface_play_example_factory_fixture.dart';

void main() {
  test(
    'realtime example binds true human frame rendering and bounded commands',
    () async {
      final bundle = SurfacePlayExampleFactory.build(
        projectId: 'pb_project_00000000-0000-0000-0000-000000000001',
        revisionId: 'pb_revision_00000000-0000-0000-0000-000000000002',
        contentManifestId: 'pb_manifest_00000000-0000-0000-0000-000000000003',
        requirementDigest: 'a' * 64,
        rulesId: 'cooperative-dodge.v1',
      );
      expect(bundle.protocol.isRealtime, isTrue);
      expect(bundle.routes.map((r) => r.routeId), ['game']);
      expect(bundle.agentMarkdown, contains('30'));
      final js = utf8.decode(bundle.files['src/main.js']!);
      expect(js, contains('Maaso.onPlayFrame'));
      expect(js, contains('Maaso.playSubmit(command)'));
      expect(js, contains('Maaso.playReceipt(pending)'));
      expect(js, isNot(contains('crypto.randomUUID')));
      expect(js, isNot(contains('setInterval')));
      expect(js, isNot(contains('rngState')));
      final directory = Directory(
        'build/verification/applet-harness-v2/runner-inputs',
      );
      await directory.create(recursive: true);
      await File(
        '${directory.path}/example-cooperative-dodge.bundle.json',
      ).writeAsString(const ProjectBundleV2Codec().encode(bundle));
      await File(
        '${directory.path}/example-cooperative-dodge.js',
      ).writeAsString(js);
    },
  );
}
