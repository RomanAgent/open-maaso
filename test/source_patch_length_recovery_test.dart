import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';

import 'support/project_source_fixture.dart';

const _requirement =
    'Keep the full requested game, every control and feature unchanged.';
String _patch(String source, String oldText, String newText) => jsonEncode({
  'fileId': 'game.js',
  'baseHash': sourceWorkspaceDigest(source),
  'edits': [
    {'oldText': oldText, 'newText': newText},
  ],
});
ProjectSourceResponse _length(String text) => ProjectSourceResponse(
  visibleText: text,
  termination: ProjectSourceTermination.knownLength,
);
GeneratedGameArtifact _producer(
  SourceFixtureClient client, {
  SourceWorkspaceSnapshot? initial,
  bool Function()? cancel,
  List<SourceWorkspaceSnapshot>? drafts,
  List<String>? notes,
}) => GeneratedGameArtifact(
  client: client,
  instruction: _requirement,
  surfaceId: 'host-fixed',
  zh: true,
  initialDraft: initial,
  shouldCancel: cancel,
  onDraft: (value) => drafts?.add(value),
  onCheckpoint: (phase, {publicSummary}) {
    if (phase == GeneratedTaskCheckpoint.contentRepair &&
        publicSummary != null) {
      notes?.add(publicSummary);
    }
  },
);

void main() {
  test(
    'three physical length shapes keep original bytes and switch to one local edit',
    () async {
      final closed = _patch(
        sourceJs,
        'let score=0;',
        'const NEVER_APPLY_TRUNCATED=true;',
      );
      for (final text in [
        closed,
        closed.substring(0, closed.length - 8),
        '{"fileId":',
      ]) {
        final drafts = <SourceWorkspaceSnapshot>[], notes = <String>[];
        final client = SourceFixtureClient([
          ...sourceFixtureResponses(),
          _length(text),
          _patch(sourceJs, 'let score=0;', 'let score=0;const repaired=true;'),
        ]);
        final producer = _producer(client, drafts: drafts, notes: notes);
        final original = await producer.generate();
        final repaired = await producer.repair(
          original,
          'surface worker first frame rejected: runtime_failed',
        );
        final diagnosticDraft = drafts.firstWhere(
          (d) => d.diagnostic?.knownLength == true,
        );
        expect(diagnosticDraft.diagnostic?.closedJson, text == closed);
        expect(diagnosticDraft.stallCount, 0);
        expect(diagnosticDraft.files.every((f) => f.complete), isTrue);
        expect(
          diagnosticDraft.files
              .singleWhere((f) => f.plan.id == 'game.js')
              .source,
          sourceJs,
        );
        expect(client.requests, hasLength(6));
        expect(
          client.requests.last.first.content,
          contains('Delivery strategy: single_local_edit'),
        );
        expect(
          client.requests.last.first.content,
          isNot(contains('NEVER_APPLY_TRUNCATED')),
        );
        expect(notes.single, contains('已保存源码保持完整'));
        expect(
          (repaired.actions.single['surface'] as Map)['js'],
          sourceJs.replaceFirst(
            'let score=0;',
            'let score=0;const repaired=true;',
          ),
        );
        final before = original.actions.single['surface'] as Map,
            after = repaired.actions.single['surface'] as Map;
        for (final key in before.keys.where((key) => key != 'js')) {
          expect(after[key], before[key], reason: '$key');
        }
        expect(repaired.reply, original.reply);
        for (final request in client.requests) {
          expect(request.last.content, _requirement);
        }
      }
    },
  );

  test(
    'single local edit delivery persists across observed runtime failures',
    () async {
      const bad = '$sourceJs\nmissingOne();\nmissingTwo();';
      const first = '$sourceJs\n\nmissingTwo();';
      const finalSource = '$sourceJs\n\n';
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(js: bad),
        _length(_patch(bad, 'missingOne();', '')),
        _patch(bad, 'missingOne();', ''),
        _patch(first, 'missingTwo();', ''),
      ]);
      final producer = _producer(client);
      final original = await producer.generate();
      const diagnostic = 'surface worker first frame rejected: runtime_failed';
      final partial = await producer.repair(original, diagnostic);
      expect(
        (partial.actions.single['surface'] as Map)['js'],
        contains('missingTwo();'),
        reason:
            'A second host execution still encounters the remaining ReferenceError',
      );
      final repaired = await producer.repair(partial, diagnostic);
      expect((repaired.actions.single['surface'] as Map)['js'], finalSource);
      SurfaceProjectValidator.validateForPublicGame(
        SurfaceProject.fromJson(repaired.actions.single['surface'] as Map),
      );
      expect(client.requests, hasLength(7));
      expect(
        client.requests.last.first.content,
        contains('Delivery strategy: single_local_edit'),
      );
      expect((repaired.actions.single['surface'] as Map)['html'], sourceHtml);
      expect((repaired.actions.single['surface'] as Map)['css'], sourceCss);
    },
  );

  test(
    'second length switches immediately to bound cursor rewrite without a third invalid patch request',
    () async {
      final rewrite = '$sourceJs\nconst cursorRecovered=true;';
      final prefix = rewrite.substring(0, 70), suffix = rewrite.substring(70);
      final drafts = <SourceWorkspaceSnapshot>[], notes = <String>[];
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        _length(_patch(sourceJs, 'let score=0;', 'let score=1;')),
        _length(
          '{"fileId":"game.js","baseHash":"${sourceWorkspaceDigest(sourceJs)}","edits":[',
        ),
        jsonEncode(boundSourceChunk('game.js', prefix, done: false)),
        jsonEncode(boundSourceChunk('game.js', suffix, prefix: prefix)),
      ]);
      final producer = _producer(client, drafts: drafts, notes: notes);
      final original = await producer.generate();
      final repaired = await producer.repair(
        original,
        'surface worker first frame rejected: runtime_failed',
      );
      expect(client.requests, hasLength(8));
      expect(client.requests[5].first.content, contains('single_local_edit'));
      expect(client.requests[6].first.content, contains('"baseCursor":0'));
      expect(
        client.requests[6].first.content,
        isNot(contains('Delivery strategy:')),
      );
      expect(
        client.requests[7].first.content,
        contains('"baseCursor":${utf8.encode(prefix).length}'),
      );
      expect(client.requests[6].first.content, contains(jsonEncode(sourceJs)));
      final lengthDrafts = drafts.where(
        (d) =>
            d.diagnostic?.knownLength == true &&
            d.files.every((f) => f.complete) &&
            d.files.singleWhere((f) => f.plan.id == 'game.js').source ==
                sourceJs,
      );
      expect(lengthDrafts, hasLength(2));
      expect(
        lengthDrafts.every(
          (d) =>
              d.files.singleWhere((f) => f.plan.id == 'game.js').source ==
              sourceJs,
        ),
        isTrue,
      );
      expect(notes, hasLength(2));
      expect(notes.last, contains('原文件已保留'));
      expect((repaired.actions.single['surface'] as Map)['js'], rewrite);
      expect(
        drafts.last.files
            .singleWhere((f) => f.plan.id == 'game.js')
            .previousSource,
        sourceJs,
      );
    },
  );

  test(
    'cancellation before the next strategy admission dispatches no recovery request',
    () async {
      var cancelled = false;
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        _length('{"fileId":'),
      ]);
      final producer = _producer(
        client,
        cancel: () => cancelled,
        drafts: drafts,
      );
      final original = await producer.generate();
      client.beforeAdmission = () {
        if (client.requests.length == 5) cancelled = true;
      };
      await expectLater(
        producer.repair(
          original,
          'surface worker first frame rejected: runtime_failed',
        ),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (e) => e.code,
            'code',
            GeneratedTaskFailureCode.interrupted,
          ),
        ),
      );
      expect(client.requests, hasLength(5));
      expect(drafts.last.files.every((f) => f.complete), isTrue);
      expect(
        drafts.last.files.singleWhere((f) => f.plan.id == 'game.js').source,
        sourceJs,
      );
    },
  );

  test(
    'capacity rejection after length recovery retains the complete original source',
    () async {
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        _length('{"fileId":'),
        _patch(sourceJs, 'let score=0;', 'x' * (8 * 1024 * 1024 + 1)),
      ]);
      final producer = _producer(client, drafts: drafts);
      final original = await producer.generate();
      await expectLater(
        producer.repair(
          original,
          'surface worker first frame rejected: runtime_failed',
        ),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (e) => e.code,
            'code',
            GeneratedTaskFailureCode.generationCapacityExceeded,
          ),
        ),
      );
      expect(client.requests, hasLength(6));
      expect(drafts.last.files.every((f) => f.complete), isTrue);
      expect(
        drafts.last.files.singleWhere((f) => f.plan.id == 'game.js').source,
        sourceJs,
      );
    },
  );

  test(
    'an explicit retry of retained length stall3 starts single edit with a fresh stall counter',
    () async {
      final baselineDrafts = <SourceWorkspaceSnapshot>[];
      final baseline = _producer(
        SourceFixtureClient(sourceFixtureResponses()),
        drafts: baselineDrafts,
      );
      await baseline.generate();
      final saved = baselineDrafts.last;
      final retained = SourceWorkspaceSnapshot(
        requirementSha256: saved.requirementSha256,
        experienceType: saved.experienceType,
        blueprint: saved.blueprint,
        blueprintComplete: true,
        files: saved.files,
        stallCount: 3,
        diagnostic: const SourceGenerationDiagnostic(
          phase: SourceDiagnosticPhase.append,
          reason: SourceDiagnosticReason.jsonIncomplete,
          fileId: 'game.js',
          knownLength: true,
          closedJson: false,
        ),
      );
      final client = SourceFixtureClient([
        _patch(sourceJs, 'absent text', 'wrong'),
        jsonEncode(
          boundSourceChunk(
            'game.js',
            sourceJs.replaceFirst(
              'let score=0;',
              'let score=0;const resumed=true;',
            ),
          ),
        ),
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      final producer = _producer(client, initial: retained, drafts: drafts);
      final original = await producer.generate();
      expect(client.requests, isEmpty);
      final repaired = await producer.repair(
        original,
        'surface worker first frame rejected: runtime_failed',
      );
      expect(client.requests, hasLength(2));
      expect(
        client.requests.first.first.content,
        contains('single_local_edit'),
      );
      expect(drafts.first.stallCount, 0);
      expect(drafts.first.files.every((f) => f.complete), isTrue);
      expect(
        drafts.first.files.singleWhere((f) => f.plan.id == 'game.js').source,
        sourceJs,
      );
      expect(drafts.last.stallCount, 0);
      expect(
        (repaired.actions.single['surface'] as Map)['js'],
        contains('resumed=true'),
      );
    },
  );

  test(
    'authentication failure in a recovery strategy never triggers another mode or request',
    () async {
      const error = LLMResponseIntegrityException.publicFailure(
        'modelAuthentication',
      );
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        _length('{"fileId":'),
        error,
      ]);
      final producer = _producer(client);
      final original = await producer.generate();
      await expectLater(
        producer.repair(
          original,
          'surface worker first frame rejected: runtime_failed',
        ),
        throwsA(same(error)),
      );
      expect(client.requests, hasLength(6));
    },
  );
}
