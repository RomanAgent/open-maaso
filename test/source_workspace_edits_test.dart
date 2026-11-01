import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace_edits.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';

import 'support/project_source_fixture.dart';

const _instruction =
    'Build the complete requested game without replacing any feature.';
SourceFileSnapshot _file(String source) => SourceFileSnapshot(
  plan: SourceFilePlan(
    id: 'game.js',
    kind: SourceFileKind.js,
    purpose: 'Full game',
  ),
  source: source,
  complete: true,
);
String _patch(
  String source,
  List<Map<String, String>> edits, {
  String id = 'game.js',
}) => jsonEncode({
  'fileId': id,
  'baseHash': sourceWorkspaceDigest(source),
  'edits': edits,
});
Map<String, String> _edit(String oldText, String newText) => {
  'oldText': oldText,
  'newText': newText,
};
GeneratedGameArtifact _producer(
  SourceFixtureClient client, {
  bool Function()? cancel,
  List<SourceWorkspaceSnapshot>? drafts,
}) => GeneratedGameArtifact(
  client: client,
  instruction: _instruction,
  surfaceId: 'host-owned',
  zh: false,
  shouldCancel: cancel,
  onDraft: (value) => drafts?.add(value),
);
Matcher _code(String code) =>
    isA<SourceWorkspaceProtocolException>().having((e) => e.code, 'code', code);

void main() {
  test(
    'edits bind exact UTF8 source and apply all positions against one original',
    () {
      const source = '甲😀 BEGIN alpha MID beta END\n';
      final file = _file(source);
      final batch = SourceFileEdits.decode(
        _patch(source, [
          _edit('alpha', 'beta replacement'),
          _edit('beta', 'second'),
        ]),
        file: file,
        knownLength: false,
      );
      expect(batch.apply(file), '甲😀 BEGIN beta replacement MID second END\n');
      expect(file.source, source);
    },
  );
  test(
    'an ambiguous or absent exact oldText is rejected without partial mutation',
    () {
      const source = 'same same unique';
      for (final old in ['same', 'missing']) {
        final file = _file(source);
        final batch = SourceFileEdits.decode(
          _patch(source, [_edit('unique', 'changed'), _edit(old, 'bad')]),
          file: file,
          knownLength: false,
        );
        expect(() => batch.apply(file), throwsA(_code('edit_match')));
        expect(file.source, source);
      }
    },
  );
  test('overlapping replacements are rejected atomically', () {
    const source = 'abcdef';
    final file = _file(source);
    final batch = SourceFileEdits.decode(
      _patch(source, [_edit('abc', 'x'), _edit('bcde', 'y')]),
      file: file,
      knownLength: false,
    );
    expect(() => batch.apply(file), throwsA(_code('edit_overlap')));
    expect(file.source, source);
  });
  test('no-op, empty match and net no-progress edits are rejected', () {
    final file = _file('AB');
    for (final edit in [_edit('A', 'A'), _edit('', 'x')]) {
      expect(
        () => SourceFileEdits.decode(
          _patch('AB', [edit]),
          file: file,
          knownLength: false,
        ),
        throwsA(_code('edit_no_progress')),
      );
    }
    final batch = SourceFileEdits.decode(
      _patch('AB', [_edit('A', ''), _edit('B', 'AB')]),
      file: file,
      knownLength: false,
    );
    expect(() => batch.apply(file), throwsA(_code('edit_no_progress')));
  });
  test('empty edits are a bound per-file skip rather than a source write', () {
    final file = _file('unchanged');
    final batch = SourceFileEdits.decode(
      _patch(file.source, []),
      file: file,
      knownLength: false,
    );
    expect(batch.edits, isEmpty);
    expect(() => batch.apply(file), throwsA(_code('edit_no_progress')));
    expect(file.source, 'unchanged');
  });
  test('wrong ID, stale base hash and a changed file cannot apply a patch', () {
    final file = _file('original');
    expect(
      () => SourceFileEdits.decode(
        _patch(file.source, [], id: 'other.js'),
        file: file,
        knownLength: false,
      ),
      throwsA(_code('chunk_binding')),
    );
    expect(
      () => SourceFileEdits.decode(
        _patch('stale', []),
        file: file,
        knownLength: false,
      ),
      throwsA(_code('chunk_binding')),
    );
    final batch = SourceFileEdits.decode(
      _patch(file.source, [_edit('original', 'new')]),
      file: file,
      knownLength: false,
    );
    expect(
      () => batch.apply(_file('changed')),
      throwsA(_code('chunk_binding')),
    );
  });
  test(
    'truncated patch, nested duplicates and authority fields are closed failures',
    () {
      final file = _file('original');
      final valid = _patch(file.source, [_edit('original', 'new')]);
      expect(
        () => SourceFileEdits.decode(valid, file: file, knownLength: true),
        throwsA(_code('edit_incomplete')),
      );
      expect(
        () => SourceFileEdits.decode(
          valid.substring(0, valid.length - 2),
          file: file,
          knownLength: false,
        ),
        throwsA(_code('edit_incomplete')),
      );
      final raw =
          '{"fileId":"game.js","baseHash":"${file.prefixHash}","edits":[{"oldText":"original","oldText":"original","newText":"new"}]}';
      expect(
        () => SourceFileEdits.decode(raw, file: file, knownLength: false),
        throwsA(_code('json_duplicate_key')),
      );
      for (final extra in [
        'path',
        'manifest',
        'actions',
        'permissions',
        'done',
      ]) {
        final data = jsonDecode(valid) as Map<String, Object?>;
        data[extra] = 'model supplied';
        expect(
          () => SourceFileEdits.decode(
            jsonEncode(data),
            file: file,
            knownLength: false,
          ),
          throwsA(_code('fields')),
        );
      }
    },
  );
  test(
    'edits reject invalid Unicode instead of encoding replacement characters',
    () {
      final file = _file('original');
      expect(
        () => SourceFileEdits.decode(
          _patch(file.source, [_edit('original', String.fromCharCode(0xd800))]),
          file: file,
          knownLength: false,
        ),
        throwsA(isA<SourceWorkspaceProtocolException>()),
      );
    },
  );

  test(
    'producer changes only the selected segments and preserves complete metadata and other files',
    () async {
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        _patch(sourceJs, [_edit('let score=0;', 'let score=1;')]),
      ]);
      final producer = _producer(client, drafts: drafts);
      final before = await producer.generate();
      final after = await producer.repair(
        before,
        'surface worker first frame rejected: runtime_failed',
      );
      final original = before.actions.single['surface'] as Map;
      final changed = after.actions.single['surface'] as Map;
      for (final key in original.keys.where((key) => key != 'js')) {
        expect(changed[key], original[key], reason: '$key');
      }
      expect(after.reply, before.reply);
      expect(
        changed['js'],
        sourceJs.replaceFirst('let score=0;', 'let score=1;'),
      );
      expect(client.requests, hasLength(5));
      expect(
        client.requests.last.first.content,
        contains('smallest complete set of exact edits'),
      );
      expect(
        client.requests.last.first.content,
        contains(jsonEncode(sourceJs)),
      );
      expect(
        client.requests.last.first.content,
        contains(jsonEncode(sourceHtml)),
      );
      expect(
        client.requests.last.first.content,
        contains(jsonEncode(sourceCss)),
      );
      expect(
        drafts.last.files
            .singleWhere((f) => f.plan.id == 'game.js')
            .previousSource,
        sourceJs,
      );
    },
  );
  test(
    'unmatched complete patches preserve every original byte and then stall',
    () async {
      final drafts = <SourceWorkspaceSnapshot>[];
      final invalid = ProjectSourceResponse(
        visibleText: _patch(sourceJs, [_edit('absent segment', 'changed')]),
        termination: ProjectSourceTermination.complete,
      );
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        invalid,
        invalid,
        for (var index = 0; index < 3; index++)
          jsonEncode(boundSourceChunk('game.js', '', done: false)),
      ]);
      final producer = _producer(client, drafts: drafts);
      final envelope = await producer.generate();
      final baseline = drafts.last.files
          .map((f) => (id: f.plan.id, source: f.source))
          .toList();
      await expectLater(
        producer.repair(
          envelope,
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
            .where((file) => file.plan.id != 'game.js')
            .map((f) => (id: f.plan.id, source: f.source))
            .toList(),
        baseline.where((file) => file.id != 'game.js').toList(),
      );
      expect(
        drafts.last.files
            .singleWhere((file) => file.plan.id == 'game.js')
            .previousSource,
        sourceJs,
      );
      expect(
        drafts.last.files
            .singleWhere((file) => file.plan.id == 'game.js')
            .source,
        isEmpty,
      );
    },
  );
  test(
    'cancellation after patch response prevents applying or saving the candidate',
    () async {
      var cancel = false;
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        _patch(sourceJs, [_edit('let score=0;', 'let score=1;')]),
      ]);
      final producer = GeneratedGameArtifact(
        client: client,
        instruction: _instruction,
        surfaceId: 'host-owned',
        zh: false,
        shouldCancel: () => cancel,
        onDraft: (snapshot) {
          expect(
            cancel,
            isFalse,
            reason: 'Cancellation fences every later draft write.',
          );
          drafts.add(snapshot);
        },
      );
      final envelope = await producer.generate();
      final count = drafts.length;
      final sourceIdentity = drafts.last.executionDigest;
      client.afterResponse = () => cancel = true;
      await expectLater(
        producer.repair(
          envelope,
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
      // The request checkpoint is durable before dispatch; the cancelled
      // response must neither advance source nor persist another checkpoint.
      final pending = drafts.skip(count).single;
      expect(pending.executionDigest, sourceIdentity);
      expect(pending.executionCheckpoint!.operation, 'repair');
      expect(pending.executionCheckpoint!.requestPending, isTrue);
      expect(
        pending.executionCheckpoint!.systemPrompt,
        client.requests.last.first.content,
      );
      expect(
        drafts.last.files.singleWhere((f) => f.plan.id == 'game.js').source,
        sourceJs,
      );
    },
  );
  test(
    'provider authentication failure does not fall back or replay a model request',
    () async {
      const error = LLMResponseIntegrityException.publicFailure(
        'modelAuthentication',
      );
      final client = SourceFixtureClient([...sourceFixtureResponses(), error]);
      final producer = _producer(client);
      final envelope = await producer.generate();
      await expectLater(
        producer.repair(
          envelope,
          'surface worker first frame rejected: runtime_failed',
        ),
        throwsA(same(error)),
      );
      expect(client.requests, hasLength(5));
    },
  );
  test(
    'explicit complete source rewrite reuses the same first response without another request',
    () async {
      final rewritten = '$sourceJs\nconst completeRewrite=true;';
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        jsonEncode(boundSourceChunk('game.js', rewritten)),
      ]);
      final producer = _producer(client);
      final original = await producer.generate();
      final repaired = await producer.repair(
        original,
        'surface worker first frame rejected: runtime_failed',
      );
      expect((repaired.actions.single['surface'] as Map)['js'], rewritten);
      expect(client.requests, hasLength(5));
    },
  );
  test(
    'first valid rewrite segment continues at its own UTF8 cursor without echoing the prefix',
    () async {
      final full = '$sourceJs\nconst rewritten=true;';
      final prefix = full.substring(0, 50), suffix = full.substring(50);
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        jsonEncode(boundSourceChunk('game.js', prefix, done: false)),
        jsonEncode(boundSourceChunk('game.js', suffix, prefix: prefix)),
      ]);
      final producer = _producer(client);
      final original = await producer.generate();
      final repaired = await producer.repair(
        original,
        'surface worker first frame rejected: runtime_failed',
      );
      expect((repaired.actions.single['surface'] as Map)['js'], full);
      expect(client.requests, hasLength(6));
      expect(
        client.requests.last.first.content,
        contains('"baseCursor":${utf8.encode(prefix).length}'),
      );
    },
  );

  for (final changeSecond in [true, false]) {
    test(
      'two JS files can skip the healthy file; changeSecond=$changeSecond',
      () async {
        const helper = 'const helperValue=1;';
        final plan = {
          ...sourcePlan,
          'files': [
            ...(sourcePlan['files'] as List).take(2),
            {
              'id': 'helper.js',
              'kind': 'js',
              'purpose': 'Healthy helper',
              'dependsOn': [],
            },
            (sourcePlan['files'] as List).last,
          ],
        };
        final client = SourceFixtureClient([
          jsonEncode(plan),
          jsonEncode(boundSourceChunk('screen.html', sourceHtml)),
          jsonEncode(boundSourceChunk('skin.css', sourceCss)),
          jsonEncode(boundSourceChunk('helper.js', helper)),
          jsonEncode(boundSourceChunk('game.js', sourceJs)),
          _patch(helper, [], id: 'helper.js'),
          _patch(
            sourceJs,
            changeSecond ? [_edit('let score=0;', 'let score=1;')] : [],
          ),
        ]);
        final drafts = <SourceWorkspaceSnapshot>[];
        final producer = _producer(client, drafts: drafts);
        final original = await producer.generate();
        if (changeSecond) {
          final repaired = await producer.repair(
            original,
            'surface worker first frame rejected: runtime_failed',
          );
          expect(
            (repaired.actions.single['surface'] as Map)['js'],
            '$helper\n;\n${sourceJs.replaceFirst('let score=0;', 'let score=1;')}',
          );
        } else {
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
        }
        expect(client.requests, hasLength(7));
        expect(
          drafts.last.files.singleWhere((f) => f.plan.id == 'helper.js').source,
          helper,
        );
        expect(drafts.last.files.every((f) => f.complete), isTrue);
      },
    );
  }

  for (final reason in [
    'exactMatchRejected',
    'overlapRejected',
    'jsonIncomplete',
  ]) {
    test(
      'the next repair request carries the accurate host rejection code $reason',
      () async {
        final rejected = reason == 'exactMatchRejected'
            ? _patch(sourceJs, [_edit('absent segment', 'changed')])
            : reason == 'overlapRejected'
            ? _patch(sourceJs, [
                _edit('let score=0;', 'let score=1;'),
                _edit('let score=0', 'let score=2'),
              ])
            : ProjectSourceResponse(
                visibleText: _patch(sourceJs, [
                  _edit('let score=0;', 'let score=1;'),
                ]),
                termination: ProjectSourceTermination.knownLength,
              );
        final drafts = <SourceWorkspaceSnapshot>[];
        final client = SourceFixtureClient([
          ...sourceFixtureResponses(),
          rejected,
          _patch(sourceJs, [_edit('let score=0;', 'let score=1;')]),
        ]);
        final producer = _producer(client, drafts: drafts);
        final original = await producer.generate();
        final repaired = await producer.repair(
          original,
          'surface worker first frame rejected: runtime_failed',
        );
        expect(
          (repaired.actions.single['surface'] as Map)['js'],
          sourceJs.replaceFirst('let score=0;', 'let score=1;'),
        );
        expect(client.requests, hasLength(6));
        expect(
          client.requests.last.first.content,
          contains('Previous patch rejected with host diagnostic: $reason.'),
        );
        expect(drafts.any((d) => d.diagnostic?.reason.name == reason), isTrue);
        for (final draft in drafts.where(
          (d) => d.diagnostic?.reason.name == reason && d.stallCount > 0,
        )) {
          expect(
            draft.files.singleWhere((f) => f.plan.id == 'game.js').source,
            sourceJs,
          );
        }
      },
    );
  }

  test(
    'a lexical rejection selects only JavaScript and preserves HTML and CSS bytes',
    () async {
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        _patch(sourceJs, [_edit('let score=0;', 'let score=1;')]),
      ]);
      final producer = _producer(client);
      final original = await producer.generate();
      final repaired = await producer.repair(
        original,
        '${SurfaceProjectValidator.javaScriptLexicalFailurePrefix} (UTF-16 offset 0)',
      );
      final surface = repaired.actions.single['surface'] as Map;
      expect(surface['html'], sourceHtml);
      expect(surface['css'], sourceCss);
      expect(
        surface['js'],
        sourceJs.replaceFirst('let score=0;', 'let score=1;'),
      );
      expect(client.requests, hasLength(5));
    },
  );

  test(
    'repair can inspect an owned immutable source range before exact editing',
    () async {
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        jsonEncode({
          'read': {'fileId': 'skin.css', 'startByte': 0, 'maxBytes': 100},
        }),
        _patch(sourceJs, [_edit('let score=0;', 'let score=1;')]),
      ]);
      final producer = _producer(client);
      final original = await producer.generate();
      final repaired = await producer.repair(
        original,
        'surface worker first frame rejected: runtime_failed',
      );
      expect((repaired.actions.single['surface'] as Map)['css'], sourceCss);
      expect(client.requests, hasLength(6));
      expect(client.requests.last.first.content, contains('recentReadResults'));
      expect(
        client.requests.last.first.content,
        contains('"endByte":${utf8.encode(sourceCss).length}'),
      );
    },
  );

  test(
    'oversized edit candidate is rejected before replacing the persisted complete file',
    () async {
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        _patch(sourceJs, [_edit('let score=0;', 'x' * (8 * 1024 * 1024 + 1))]),
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
      expect(
        drafts.last.files.singleWhere((f) => f.plan.id == 'game.js').source,
        sourceJs,
      );
      expect(drafts.last.files.every((f) => f.complete), isTrue);
      expect(client.requests, hasLength(5));
    },
  );

  test(
    'cycling across five owned EOF reads stalls before a fourth read dispatch',
    () async {
      const helper1 = 'const helperOne=1;', helper2 = 'const helperTwo=2;';
      final plan = {
        ...sourcePlan,
        'files': [
          ...(sourcePlan['files'] as List).take(2),
          {
            'id': 'helper1.js',
            'kind': 'js',
            'purpose': 'Helper one',
            'dependsOn': [],
          },
          {
            'id': 'helper2.js',
            'kind': 'js',
            'purpose': 'Helper two',
            'dependsOn': [],
          },
          (sourcePlan['files'] as List).last,
        ],
      };
      final sources = {
        'screen.html': sourceHtml,
        'skin.css': sourceCss,
        'helper1.js': helper1,
        'helper2.js': helper2,
        'game.js': sourceJs,
      };
      final client = SourceFixtureClient([
        jsonEncode(plan),
        for (final entry in sources.entries)
          jsonEncode(boundSourceChunk(entry.key, entry.value)),
        for (var round = 0; round < 3; round++)
          for (final entry in sources.entries)
            jsonEncode({
              'read': {
                'fileId': entry.key,
                'startByte': utf8.encode(entry.value).length,
                'maxBytes': 16,
              },
            }),
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
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
            GeneratedTaskFailureCode.generationStalled,
          ),
        ),
      );
      expect(client.requests, hasLength(9));
      expect(drafts.last.stallCount, 3);
      expect(drafts.last.diagnostic?.phase, SourceDiagnosticPhase.inspection);
      expect(
        drafts.last.diagnostic?.reason,
        SourceDiagnosticReason.inspectionInvalid,
      );
      expect({
        for (final file in drafts.last.files) file.plan.id: file.source,
      }, sources);
      expect(drafts.last.files.every((file) => file.complete), isTrue);
    },
  );

  test(
    'consumed read is not counted again while retrying two rejected patches',
    () async {
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        jsonEncode({
          'read': {'fileId': 'skin.css', 'startByte': 0, 'maxBytes': 100},
        }),
        _patch(sourceJs, [_edit('absent segment', 'a')]),
        _patch(sourceJs, [_edit('absent segment', 'b')]),
        jsonEncode(
          boundSourceChunk(
            'game.js',
            sourceJs.replaceFirst('let score=0;', 'let score=1;'),
          ),
        ),
      ]);
      final producer = _producer(client);
      final original = await producer.generate();
      final repaired = await producer.repair(
        original,
        'surface worker first frame rejected: runtime_failed',
      );
      expect(
        (repaired.actions.single['surface'] as Map)['js'],
        sourceJs.replaceFirst('let score=0;', 'let score=1;'),
      );
      expect(client.requests, hasLength(8));
    },
  );
}
