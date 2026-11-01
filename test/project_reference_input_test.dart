import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/project_build/project_reference_input.dart';

ProjectReferenceImage image(
  String marker, {
  ProjectReferencePurpose purpose = ProjectReferencePurpose.reference,
}) => ProjectReferenceImage(
  sha256: marker * 64,
  byteLength: 100,
  mime: 'image/jpeg',
  purpose: purpose,
);

void main() {
  test(
    'snapshot keeps order, purpose, revision and prior summary immutable',
    () {
      final references = [
        image('a', purpose: ProjectReferencePurpose.layout),
        image('b', purpose: ProjectReferencePurpose.style),
      ];
      final snapshot = ProjectReferenceInputSnapshot(
        scopeKey: 'scope-a',
        visualSummary: '图一是布局，图二是风格。',
        inputRevision: 3,
        references: references,
      );
      final restored = ProjectReferenceInputSnapshot.fromJson(
        jsonDecode(jsonEncode(snapshot.toJson())),
      );
      references.clear();
      expect(restored.digest, snapshot.digest);
      expect(restored.inputRevision, 3);
      expect(restored.references.map((item) => item.purpose), [
        ProjectReferencePurpose.layout,
        ProjectReferencePurpose.style,
      ]);
      expect(() => restored.references.clear(), throwsUnsupportedError);
      expect(
        restored.toPromptContext(),
        contains('not the original image bytes'),
      );
      expect(restored.toJson().keys, isNot(contains('uploaded')));
    },
  );

  test(
    'identity changes with bytes, order, purpose, summary, revision or scope',
    () {
      ProjectReferenceInputSnapshot snapshot({
        String scope = 'scope-a',
        String summary = 'summary',
        int revision = 1,
        List<ProjectReferenceImage>? refs,
      }) => ProjectReferenceInputSnapshot(
        scopeKey: scope,
        visualSummary: summary,
        inputRevision: revision,
        references: refs ?? [image('a'), image('b')],
      );
      final original = snapshot().digest;
      for (final value in [
        snapshot(scope: 'scope-b'),
        snapshot(summary: 'different'),
        snapshot(revision: 2),
        snapshot(refs: [image('b'), image('a')]),
        snapshot(refs: [image('a'), image('c')]),
        snapshot(
          refs: [
            image('a', purpose: ProjectReferencePurpose.asset),
            image('b'),
          ],
        ),
      ]) {
        expect(value.digest, isNot(original));
      }
    },
  );

  test(
    'source identity ignores summary wording but retains all user source choices',
    () {
      ProjectReferenceInputSnapshot snapshot({
        String scope = 'scope-a',
        String summary = 'summary',
        int revision = 1,
        List<ProjectReferenceImage>? refs,
      }) => ProjectReferenceInputSnapshot(
        scopeKey: scope,
        visualSummary: summary,
        inputRevision: revision,
        references: refs ?? [image('a'), image('b')],
      );
      final original = snapshot();
      final rephrased = snapshot(
        summary: 'same images, different analysis wording',
      );
      expect(rephrased.digest, isNot(original.digest));
      expect(rephrased.sourceIdentityDigest, original.sourceIdentityDigest);
      expect(
        ProjectReferenceInputSnapshot.fromJson(
          rephrased.toJson(),
        ).sourceIdentityDigest,
        original.sourceIdentityDigest,
      );
      for (final value in [
        snapshot(scope: 'scope-b'),
        snapshot(revision: 2),
        snapshot(refs: [image('b'), image('a')]),
        snapshot(refs: [image('a'), image('c')]),
        snapshot(
          refs: [
            image('a', purpose: ProjectReferencePurpose.asset),
            image('b'),
          ],
        ),
      ]) {
        expect(
          value.sourceIdentityDigest,
          isNot(original.sourceIdentityDigest),
        );
      }
    },
  );

  test('rejects invalid count, duplicate images and metadata tampering', () {
    for (final refs in <List<ProjectReferenceImage>>[
      [],
      [image('a'), image('a')],
      [image('a'), image('b'), image('c'), image('d'), image('e')],
    ]) {
      expect(
        () => ProjectReferenceInputSnapshot(
          scopeKey: 'scope-a',
          visualSummary: 'summary',
          references: refs,
        ),
        throwsFormatException,
      );
    }
    final original = ProjectReferenceInputSnapshot(
      scopeKey: 'scope-a',
      visualSummary: 'summary',
      references: [image('a')],
    );
    for (final update in <Map<String, Object?>>[
      {'scopeKey': 'scope-b'},
      {'schemaVersion': 2},
      {'inputRevision': 1.0},
      {'visualSummary': ''},
      {'uploaded': true},
      {'assetUrl': 'https://example.test/expired'},
    ]) {
      final raw = original.toJson()..addAll(update);
      expect(
        () => ProjectReferenceInputSnapshot.fromJson(raw),
        throwsFormatException,
      );
    }
    expect(
      () => ProjectReferenceImage(
        sha256: 'a' * 64,
        byteLength: 1,
        mime: 'image/svg+xml',
      ),
      throwsFormatException,
    );
    expect(
      () => ProjectReferenceInputSnapshot(
        scopeKey: 'scope-a',
        visualSummary: 'x' * 12001,
        references: [image('a')],
      ),
      throwsFormatException,
    );
  });
}
