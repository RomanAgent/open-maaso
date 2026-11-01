import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'support/project_source_fixture.dart';

String _patch(
  String source,
  List<Map<String, Object?>> edits, {
  String? baseHash,
}) => jsonEncode({
  'fileId': 'game.js',
  'baseHash': baseHash ?? sourceWorkspaceDigest(source),
  'edits': edits,
});
const _source = 'const repeat=1;const repeat=1;const unique=2;';
const _fixed = 'const repeat=1;const repeat=1;const unique=3;';
const _requirement = 'Preserve all original gameplay, screens and controls';
GeneratedGameArtifact _producer(
  SourceFixtureClient client,
  List<SourceWorkspaceSnapshot> drafts,
) => GeneratedGameArtifact(
  client: client,
  instruction: _requirement,
  surfaceId: 'owned',
  zh: true,
  onDraft: drafts.add,
);

void main() {
  for (final badEdits in [
    [
      {'oldText': 'const repeat=1;', 'newText': 'const repeat=3;'},
    ],
    [
      {'oldText': 'not in source', 'newText': 'correct'},
    ],
    [
      {
        'oldText': 'const repeat=1;',
        'newText': 'const repeat=3;',
        'startUtf16': -1,
      },
    ],
    [
      {'oldText': 'const repeat=1;', 'newText': 'changed', 'startUtf16': 0},
      {'oldText': 'repeat', 'newText': 'x', 'startUtf16': 6},
    ],
  ]) {
    test(
      'confirmed unusable bound edit switches once to single local delivery: $badEdits',
      () async {
        final client = SourceFixtureClient([
          ...sourceFixtureResponses(js: _source),
          _patch(_source, badEdits),
          _patch(_source, [
            {'oldText': 'const unique=2;', 'newText': 'const unique=3;'},
          ]),
        ]);
        final drafts = <SourceWorkspaceSnapshot>[];
        final producer = _producer(client, drafts);
        final original = await producer.generate();
        final result = await producer.repair(
          original,
          'surface worker first frame rejected: runtime_failed',
        );
        expect(client.requests, hasLength(6));
        expect(
          client.requests.last.first.content,
          contains('Delivery strategy: single_local_edit'),
        );
        expect(
          client.requests.last.first.content,
          contains('Previous edit rejection facts'),
        );
        expect((result.actions.single['surface'] as Map)['js'], _fixed);
        expect(
          client.requests.every(
            (request) => request.last.content == _requirement,
          ),
          isTrue,
        );
      },
    );
  }
  test(
    'a second failed bound edit enters existing original-preserving source segments',
    () async {
      final bad = _patch(_source, [
        {'oldText': 'const repeat=1;', 'newText': 'changed'},
      ]);
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(js: _source),
        bad,
        bad,
        jsonEncode(boundSourceChunk('game.js', _source, done: false)),
        jsonEncode(
          boundSourceChunk('game.js', 'const appended=true;', prefix: _source),
        ),
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      final producer = _producer(client, drafts);
      final original = await producer.generate();
      final result = await producer.repair(
        original,
        'surface worker first frame rejected: runtime_failed',
      );
      expect(client.requests, hasLength(8));
      expect(client.requests[5].first.content, contains('single_local_edit'));
      expect(
        client.requests[6].first.content,
        contains('continuing exactly at the current byte cursor'),
      );
      expect(client.requests[6].first.content, contains(_source));
      expect(
        (result.actions.single['surface'] as Map)['js'],
        '${_source}const appended=true;',
      );
      expect(
        drafts.last.files
            .singleWhere((file) => file.plan.id == 'game.js')
            .previousSource,
        _source,
      );
    },
  );
  test(
    'source fallback is one-shot and still stops boundedly on empty source segments',
    () async {
      final bad = _patch(_source, [
        {'oldText': 'const repeat=1;', 'newText': 'changed'},
      ]);
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(js: _source),
        bad,
        bad,
        for (var i = 0; i < 3; i++)
          jsonEncode(boundSourceChunk('game.js', '', done: false)),
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      final producer = _producer(client, drafts);
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
            GeneratedTaskFailureCode.generationStalled,
          ),
        ),
      );
      expect(client.requests, hasLength(9));
      expect(
        drafts.last.files
            .singleWhere((file) => file.plan.id == 'game.js')
            .previousSource,
        _source,
      );
    },
  );
  test(
    'stale hashes cannot enter rewrite delivery or modify the retained source',
    () async {
      final bad = _patch(_source, [
        {'oldText': 'const unique=2;', 'newText': 'changed'},
      ], baseHash: 'wrong');
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(js: _source),
        bad,
        bad,
        bad,
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      final producer = _producer(client, drafts);
      final original = await producer.generate();
      final initialDraftCount = drafts.length;
      await expectLater(
        producer.repair(
          original,
          'surface worker first frame rejected: runtime_failed',
        ),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (e) => e.code,
            'code',
            GeneratedTaskFailureCode.generationStalled,
          ),
        ),
      );
      expect(client.requests, hasLength(7));
      expect(
        client.requests
            .skip(4)
            .every(
              (request) => request.first.content.contains(
                'Delivery strategy: exact_edits',
              ),
            ),
        isTrue,
      );
      expect(
        drafts
            .skip(initialDraftCount)
            .every(
              (draft) => draft.files
                  .where((file) => file.plan.id == 'game.js')
                  .every((file) => file.source == _source),
            ),
        isTrue,
      );
    },
  );
}
