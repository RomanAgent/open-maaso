import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const _requirement =
    'Implement every requested screen, detailed rules and art, without reducing the game.';
const _blueprint = {
  'title': '完整游戏',
  'summary': '全部源码等待实际验证',
  'skillInstructions': 'Play and restart',
  'interfaces': 'page has board; logic owns game state',
  'files': [
    {'id': 'page', 'kind': 'html', 'purpose': 'All requested screens'},
    {
      'id': 'logic',
      'kind': 'js',
      'purpose': 'Every requested mechanic',
      'dependsOn': ['page'],
    },
  ],
  'done': true,
};
ProjectSourceResponse _complete(Object data) => ProjectSourceResponse(
  visibleText: jsonEncode(data),
  termination: ProjectSourceTermination.complete,
);
Map<String, Object?> _bindings(List<Message> messages) {
  final prompt = messages.first.content;
  final m = RegExp(
    r'"fileId":"([^"]+)","baseCursor":([0-9]+),"prefixHash":"([a-f0-9]{64})"',
  ).firstMatch(prompt)!;
  return {'fileId': m[1]!, 'baseCursor': int.parse(m[2]!), 'prefixHash': m[3]!};
}

ProjectSourceResponse _chunk(
  List<Message> messages,
  String append, {
  bool done = true,
}) => _complete({..._bindings(messages), 'append': append, 'done': done});

void main() {
  test('equal source segments at advancing bindings are retained', () async {
    const repeated = '<p>Repeated tile</p>';
    final instructions = '完整操作方式' * 600;
    final client = _Client([
      (_) => _complete({..._blueprint, 'skillInstructions': instructions}),
      (m) => _chunk(m, repeated, done: false),
      (m) => _chunk(m, repeated, done: false),
      (m) => _chunk(m, repeated),
      (m) => _chunk(m, 'const complete=true;'),
    ]);
    final result = await _producer(client).generate();
    final surface = result.actions.single['surface'] as Map;
    expect(surface['html'], repeated * 3);
    expect(surface['skillInstructions'], instructions);
    expect(client.requests, hasLength(5));
    expect(client.sourceTimeouts, everyElement(isNull));
  });
  test(
    'a paged finite plan retains accepted definitions and generates every module',
    () async {
      final first = {
        ..._blueprint,
        'files': [(_blueprint['files'] as List).first],
        'done': false,
      };
      final second = {
        ..._blueprint,
        'files': [(_blueprint['files'] as List).last],
        'done': true,
      };
      final client = _Client([
        (_) => _complete(first),
        (_) => _complete(second),
        (m) => _chunk(m, '<main></main>'),
        (m) => _chunk(m, 'const allRequirements=true;'),
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      await _producer(client, onDraft: drafts.add).generate();
      expect(client.requests, hasLength(4));
      expect(
        drafts.any(
          (s) => !s.blueprintComplete && s.blueprint?.files.length == 1,
        ),
        isTrue,
      );
      expect(drafts.last.blueprint!.files.map((f) => f.id), ['page', 'logic']);
    },
  );
  test(
    'an incomplete repair resumes without dropping the prior completed source',
    () async {
      final plan = SourceBlueprint.fromJson(_blueprint);
      final initial = SourceWorkspaceSnapshot(
        requirementSha256: sourceWorkspaceDigest(_requirement),
        experienceType: 'game',
        blueprint: plan,
        blueprintComplete: true,
        files: [
          SourceFileSnapshot(
            plan: plan.files.first,
            source: '<main></main>',
            complete: true,
          ),
          SourceFileSnapshot(
            plan: plan.files.last,
            source: 'const fixed=',
            previousSource: 'const old=true;',
            repairDiagnostic:
                'surface worker first frame rejected: runtime_failed',
          ),
        ],
      );
      final client = _Client([(m) => _chunk(m, 'true;')]);
      final result = await _producer(client, initial: initial).generate();
      expect(client.requests, hasLength(1));
      expect(client.requests.single.first.content, contains('const old=true;'));
      expect(
        (result.actions.single['surface'] as Map)['js'],
        'const fixed=true;',
      );
    },
  );
  test(
    'utility workspace preserves a bounded configure manifest through source generation',
    () async {
      final manifest = {
        'schemaVersion': 2,
        'events': <Object>[],
        'instructions': 'Set the local counter value',
        'actions': [
          {
            'name': 'configure',
            'schema': {
              'type': 'object',
              'properties': {
                'value': {'type': 'integer', 'minimum': 0, 'maximum': 10},
              },
              'required': ['value'],
              'additionalProperties': false,
            },
            'risk': 'localMutation',
            'consequencePolicy': 'reversible',
          },
        ],
      };
      final blueprint = {..._blueprint, 'manifest': manifest};
      final client = _Client([
        (_) => _complete(blueprint),
        (m) => _chunk(m, '<main><p id="value">0</p></main>'),
        (m) => _chunk(
          m,
          "Surface.onAgent('configure',data=>{document.getElementById('value').textContent=String(data.value);});",
        ),
      ]);
      final result = await GeneratedGameArtifact(
        client: client,
        instruction: 'Implement the complete requested local counter applet',
        surfaceId: 'host-utility-id',
        zh: true,
        experienceType: SurfaceExperienceType.utility,
      ).generate();
      final project = SurfaceProject.fromJson(
        result.actions.single['surface'] as Map,
      );
      expect(project.experienceType, SurfaceExperienceType.utility);
      expect(project.manifest.action('configure'), isNotNull);
      expect(project.manifest.diagnoseContract(), isEmpty);
      SurfaceProjectValidator.validateForPublicApplet(project);
      expect(client.requests, hasLength(3));
    },
  );
  test(
    'a utility action cannot declare external write or public authority',
    () async {
      final client = _Client([
        (_) => _complete({
          ..._blueprint,
          'manifest': {
            'schemaVersion': 2,
            'events': [],
            'actions': [
              {
                'name': 'configure',
                'schema': {
                  'type': 'object',
                  'properties': {},
                  'required': [],
                  'additionalProperties': false,
                },
                'risk': 'externalWrite',
                'consequencePolicy': 'exactTextCommit',
              },
            ],
          },
        }),
      ]);
      await expectLater(
        GeneratedGameArtifact(
          client: client,
          instruction: 'Complete this applet',
          surfaceId: 'host-utility-id',
          zh: true,
          experienceType: SurfaceExperienceType.utility,
        ).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (e) => e.code,
            'code',
            GeneratedTaskFailureCode.responseInvalid,
          ),
        ),
      );
      expect(client.requests, hasLength(1));
    },
  );
  test(
    'more than six chunks retain full requirements and all completed files',
    () async {
      final client = _Client([
        (_) => _complete(_blueprint),
        (m) => _chunk(m, '<main>', done: false),
        (m) => _chunk(m, '<canvas id="board"></canvas>', done: false),
        (m) => _chunk(m, '</main>'),
        (m) => _chunk(m, 'const game={};', done: false),
        (m) => _chunk(m, 'function start(){', done: false),
        (m) => _chunk(m, 'game.started=true;', done: false),
        (m) => _chunk(m, '}\nstart();'),
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      final phases = <GeneratedTaskCheckpoint>[];
      final result = await _producer(
        client,
        onDraft: drafts.add,
        phases: phases,
      ).generate();
      expect(client.requests, hasLength(8));
      expect(
        client.requests.every((r) => r.last.content == _requirement),
        isTrue,
      );
      expect(
        client.requests.map((r) => r.first.content).join('\n'),
        isNot(contains('COMPACT DRAFT MODE')),
      );
      expect(result.actions, hasLength(1));
      final surface = result.actions.single['surface'] as Map;
      expect(surface['html'], '<main><canvas id="board"></canvas></main>');
      expect(
        surface['js'],
        'const game={};function start(){game.started=true;}\nstart();',
      );
      expect((surface['manifest'] as Map)['actions'], isEmpty);
      expect(
        phases.where((p) => p == GeneratedTaskCheckpoint.sourceFileComplete),
        hasLength(2),
      );
      expect(drafts.last.files.every((f) => f.complete), isTrue);
    },
  );
  test(
    'known length preserves decoded source prefix and continues the same file',
    () async {
      final client = _Client([
        (_) => _complete(_blueprint),
        (m) => _chunk(m, '<main><canvas id="board"></canvas></main>'),
        (m) {
          final b = _bindings(m);
          return ProjectSourceResponse(
            visibleText:
                '{"fileId":"${b['fileId']}","baseCursor":${b['baseCursor']},"prefixHash":"${b['prefixHash']}","append":"const label=\\"星\\uD83D\\uD',
            termination: ProjectSourceTermination.knownLength,
          );
        },
        (m) => _chunk(m, '😀";'),
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      final result = await _producer(client, onDraft: drafts.add).generate();
      expect(
        (result.actions.single['surface'] as Map)['js'],
        'const label="星😀";',
      );
      final partial = drafts.firstWhere(
        (s) => s.files.any(
          (f) => f.plan.id == 'logic' && f.source.isNotEmpty && !f.complete,
        ),
      );
      expect(
        partial.files.firstWhere((f) => f.plan.id == 'logic').source,
        'const label="星',
      );
      expect(
        _bindings(client.requests.last)['baseCursor'],
        utf8.encode('const label="星').length,
      );
    },
  );
  test('network uncertainty preserves draft and is not retried', () async {
    final error = TimeoutException('unknown dispatch');
    final client = _Client([
      (_) => _complete(_blueprint),
      (m) => _chunk(m, '<main></main>'),
      (m) => _chunk(m, 'function play(){', done: false),
      (_) => throw error,
    ]);
    final drafts = <SourceWorkspaceSnapshot>[];
    await expectLater(
      _producer(client, onDraft: drafts.add).generate(),
      throwsA(same(error)),
    );
    expect(client.requests, hasLength(4));
    expect(
      drafts.last.files.firstWhere((f) => f.plan.id == 'page').complete,
      isTrue,
    );
    expect(
      drafts.last.files.firstWhere((f) => f.plan.id == 'logic').source,
      'function play(){',
    );
  });
  test(
    'linked retry restores the exact unfinished prefix without regenerating completed pages',
    () async {
      final plan = SourceBlueprint.fromJson(_blueprint);
      final initial = SourceWorkspaceSnapshot(
        requirementSha256: sourceWorkspaceDigest(_requirement),
        experienceType: 'game',
        blueprint: plan,
        blueprintComplete: true,
        files: [
          SourceFileSnapshot(
            plan: plan.files.first,
            source: '<main></main>',
            complete: true,
          ),
          SourceFileSnapshot(plan: plan.files.last, source: 'function play(){'),
        ],
      );
      final client = _Client([(m) => _chunk(m, '}\nplay();')]);
      final result = await _producer(client, initial: initial).generate();
      expect(client.requests, hasLength(1));
      expect(
        _bindings(client.requests.single)['baseCursor'],
        utf8.encode('function play(){').length,
      );
      expect(
        (result.actions.single['surface'] as Map)['html'],
        '<main></main>',
      );
      expect(
        (result.actions.single['surface'] as Map)['js'],
        'function play(){}\nplay();',
      );
    },
  );
  test(
    'empty responses without EOF stall after three no-progress turns',
    () async {
      final client = _Client([
        (_) => _complete(_blueprint),
        for (var i = 0; i < 3; i++) (m) => _chunk(m, '', done: false),
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      await expectLater(
        _producer(client, onDraft: drafts.add).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (e) => e.code,
            'code',
            GeneratedTaskFailureCode.generationStalled,
          ),
        ),
      );
      expect(client.requests, hasLength(4));
      expect(drafts.last.stallCount, 3);
      expect(drafts.last.files.single.complete, isFalse);
    },
  );
  test('a different requirement cannot reuse a checkpoint', () async {
    final client = _Client([]);
    final initial = SourceWorkspaceSnapshot(
      requirementSha256: sourceWorkspaceDigest('other requirement'),
      experienceType: 'game',
    );
    await expectLater(
      _producer(client, initial: initial).generate(),
      throwsA(isA<GeneratedTaskFailure>()),
    );
    expect(client.requests, isEmpty);
  });
  for (final mutation in ['fileId', 'baseCursor', 'prefixHash', 'actions']) {
    test('invalid $mutation never applies rejected bytes', () async {
      final authorityChange = mutation == 'actions';
      final client = _Client([
        (_) => _complete(_blueprint),
        for (var index = 0; index < (authorityChange ? 1 : 3); index++)
          (m) {
            final b = {
              ..._bindings(m),
              'append': '<main></main>',
              'done': true,
            };
            b[mutation] = switch (mutation) {
              'fileId' => 'foreign',
              'baseCursor' => 42,
              'prefixHash' => 'foreign',
              _ => [],
            };
            return _complete(b);
          },
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      await expectLater(
        _producer(client, onDraft: drafts.add).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (e) => e.code,
            'code',
            authorityChange
                ? GeneratedTaskFailureCode.responseInvalid
                : GeneratedTaskFailureCode.generationStalled,
          ),
        ),
      );
      expect(client.requests, hasLength(authorityChange ? 2 : 4));
      expect(
        drafts.every(
          (draft) => draft.files.every((file) => file.source.isEmpty),
        ),
        isTrue,
      );
    });
  }
  test(
    'a scope change before source admission sends no stale source request',
    () async {
      var current = true;
      final client = _Client([(_) => _complete(_blueprint)])
        ..beforeAdmission = (n) {
          if (n == 1) current = false;
        };
      await expectLater(
        _producer(client, shouldCancel: () => !current).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (e) => e.code,
            'code',
            GeneratedTaskFailureCode.interrupted,
          ),
        ),
      );
      expect(client.requests, hasLength(1));
    },
  );
  test(
    'repair failure keeps the prior completed source alongside the new prefix',
    () async {
      final error = const LLMResponseIntegrityException.publicFailure(
        'modelAuthentication',
      );
      final client = _Client([
        (_) => _complete(_blueprint),
        (m) => _chunk(m, '<main></main>'),
        (m) => _chunk(m, 'const original=true;'),
        (m) {
          expect(
            m.first.content,
            contains('smallest complete set of exact edits'),
          );
          expect(
            m.first.content,
            contains(sourceWorkspaceDigest('const original=true;')),
          );
          // The model explicitly chooses a full rewrite. Its first segment is
          // bound to an empty replacement, not the complete current file.
          return _complete({
            'fileId': 'logic',
            'baseCursor': 0,
            'prefixHash': sourceWorkspaceDigest(''),
            'append': 'const replacement=',
            'done': false,
          });
        },
        (_) => throw error,
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      final producer = _producer(client, onDraft: drafts.add);
      final original = await producer.generate();
      await expectLater(
        producer.repair(
          original,
          'surface worker first frame rejected: runtime_failed',
        ),
        throwsA(same(error)),
      );
      final file = drafts.last.files.firstWhere((f) => f.plan.id == 'logic');
      expect(file.previousSource, 'const original=true;');
      expect(file.source, 'const replacement=');
      expect(file.complete, isFalse);
      expect(
        (original.actions.single['surface'] as Map)['js'],
        'const original=true;',
      );
    },
  );
}

GeneratedGameArtifact _producer(
  _Client client, {
  SourceWorkspaceSnapshot? initial,
  FutureOr<void> Function(SourceWorkspaceSnapshot)? onDraft,
  List<GeneratedTaskCheckpoint>? phases,
  bool Function()? shouldCancel,
}) => GeneratedGameArtifact(
  client: client,
  instruction: _requirement,
  surfaceId: 'host-only-id',
  zh: true,
  initialDraft: initial,
  onDraft: onDraft,
  shouldCancel: shouldCancel,
  onCheckpoint: (p, {publicSummary}) => phases?.add(p),
);
typedef _Reply = ProjectSourceResponse Function(List<Message>);

class _Client extends LLMClient implements ProjectSourceLLMClient {
  _Client(this.outputs);
  final List<_Reply> outputs;
  final requests = <List<Message>>[];
  final sourceTimeouts = <Duration?>[];
  void Function(int)? beforeAdmission;
  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) async {
    beforeAdmission?.call(requests.length);
    await onAdmitted?.call();
    requests.add(List<Message>.unmodifiable(messages));
    sourceTimeouts.add(timeout);
    return outputs.removeAt(0)(messages);
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async =>
      throw StateError('not source');
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async =>
      throw UnimplementedError();
}
