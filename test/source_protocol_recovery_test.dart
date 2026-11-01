import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const _request = '底部挡板接球，方块消失掉落分裂道具，清空进入下一关；全部功能保留';
const _plan = {
  'title': '打砖块',
  'summary': '挡板、砖块、多球道具和完整关卡',
  'skillInstructions': '拖动挡板接球，清空砖块进入下一关',
  'interfaces': 'board and controls are owned by the source',
  'files': [
    {'id': 'page', 'kind': 'html', 'purpose': '全部页面'},
    {'id': 'logic', 'kind': 'js', 'purpose': '全部玩法'},
  ],
  'planComplete': true,
};

ProjectSourceResponse _response(Object data) => ProjectSourceResponse(
  visibleText: jsonEncode(data),
  termination: ProjectSourceTermination.complete,
);

Map<String, Object?> _binding(List<Message> messages) {
  final match = RegExp(
    r'"fileId":"([^"]+)","baseCursor":([0-9]+),"prefixHash":"([a-f0-9]{64})"',
  ).firstMatch(messages.first.content)!;
  return {
    'fileId': match[1],
    'baseCursor': int.parse(match[2]!),
    'prefixHash': match[3],
  };
}

ProjectSourceResponse _write(List<Message> messages) => _response({
  ..._binding(messages),
  'append': _binding(messages)['fileId'] == 'page'
      ? '<main id="board">All requested screens</main>'
      : 'const allRequestedMechanics=true;',
  'done': true,
});

GeneratedGameArtifact _producer(
  _Client client,
  List<SourceWorkspaceSnapshot> drafts, {
  SourceWorkspaceSnapshot? initial,
  bool Function()? cancelled,
  GeneratedSourceResponseObserver? observer,
}) => GeneratedGameArtifact(
  client: client,
  instruction: _request,
  surfaceId: 'host-owned-game',
  zh: true,
  initialDraft: initial,
  shouldCancel: cancelled,
  onDraft: drafts.add,
  onModelResponse: observer,
);

void main() {
  test(
    'a complete malformed patch switches to one local edit with the correct DTO feedback',
    () async {
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) => _response(_plan),
        _write,
        _write,
        (_) => const ProjectSourceResponse(
          visibleText:
              '{"fileId":"logic","baseHash":"broken","edits":[{"oldText":"bad","newText":invalid}]}',
          termination: ProjectSourceTermination.complete,
        ),
        (messages) {
          expect(
            messages.first.content,
            contains('Delivery strategy: single_local_edit'),
          );
          expect(
            messages.first.content,
            contains('fileId, baseHash and edits'),
          );
          expect(
            messages.first.content,
            isNot(
              contains(
                'set done=false when more source remains; split delivery',
              ),
            ),
          );
          return _response({
            'fileId': 'logic',
            'baseHash': sourceWorkspaceDigest(
              'const allRequestedMechanics=true;',
            ),
            'edits': [
              {
                'oldText': 'const allRequestedMechanics=true;',
                'newText':
                    'const allRequestedMechanics=true;const repaired=true;',
              },
            ],
          });
        },
      ]);
      final producer = _producer(client, drafts);
      final before = await producer.generate();
      final after = await producer.repair(
        before,
        'surface worker first frame rejected: runtime_failed',
      );
      expect(
        (after.actions.single['surface'] as Map)['js'],
        'const allRequestedMechanics=true;const repaired=true;',
      );
      expect(
        drafts.every(
          (draft) =>
              !draft.files.any((file) => file.source.contains('invalid')),
        ),
        isTrue,
      );
      expect(client.requests, hasLength(5));
    },
  );

  test(
    'two complete malformed patches fall back to bound source segments while preserving the original',
    () async {
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) => _response(_plan),
        _write,
        _write,
        for (var i = 0; i < 2; i++)
          (_) => const ProjectSourceResponse(
            visibleText: 'not-json',
            termination: ProjectSourceTermination.complete,
          ),
        (messages) {
          expect(
            messages.first.content,
            contains('const allRequestedMechanics=true;'),
          );
          return _response({
            ..._binding(messages),
            'append': 'const allRequestedMechanics=true;',
            'done': false,
          });
        },
        (messages) => _response({
          ..._binding(messages),
          'append': 'const repaired=true;',
          'done': true,
        }),
      ]);
      final producer = _producer(client, drafts);
      final before = await producer.generate();
      final after = await producer.repair(
        before,
        'surface worker first frame rejected: runtime_failed',
      );
      expect(
        (after.actions.single['surface'] as Map)['js'],
        'const allRequestedMechanics=true;const repaired=true;',
      );
      expect(
        drafts.any(
          (draft) => draft.files.any(
            (file) =>
                file.plan.id == 'logic' &&
                file.source.isEmpty &&
                file.previousSource == 'const allRequestedMechanics=true;',
          ),
        ),
        isTrue,
      );
      expect(
        drafts.last.files
            .singleWhere((file) => file.plan.id == 'logic')
            .previousSource,
        'const allRequestedMechanics=true;',
      );
      expect(client.requests, hasLength(7));
    },
  );

  test(
    'source segments after malformed patches still stop after three empty responses',
    () async {
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) => _response(_plan),
        _write,
        _write,
        for (var i = 0; i < 2; i++)
          (_) => const ProjectSourceResponse(
            visibleText: 'not-json',
            termination: ProjectSourceTermination.complete,
          ),
        for (var i = 0; i < 3; i++)
          (messages) =>
              _response({..._binding(messages), 'append': '', 'done': false}),
      ]);
      final producer = _producer(client, drafts);
      final before = await producer.generate();
      await expectLater(
        producer.repair(
          before,
          'surface worker first frame rejected: runtime_failed',
        ),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (failure) => failure.code,
            'code',
            GeneratedTaskFailureCode.generationStalled,
          ),
        ),
      );
      expect(
        drafts.last.files
            .singleWhere((file) => file.plan.id == 'logic')
            .previousSource,
        'const allRequestedMechanics=true;',
      );
      expect(client.requests, hasLength(8));
    },
  );

  test(
    'an optional model-response observer receives exact visible source with the current file binding',
    () async {
      final client = _Client([(_) => _response(_plan), _write, _write]);
      final captured =
          <({SourceDiagnosticPhase phase, String? fileId, String visible})>[];
      await _producer(
        client,
        [],
        observer: ({required phase, required fileId, required response}) {
          captured.add((
            phase: phase,
            fileId: fileId,
            visible: response.visibleText,
          ));
        },
      ).generate();
      expect(captured.map((fact) => fact.fileId), [null, 'page', 'logic']);
      expect(captured.first.phase, SourceDiagnosticPhase.planning);
      expect(jsonDecode(captured.last.visible)['fileId'], 'logic');
    },
  );

  test(
    'observer failure cannot replace generation and observer cancellation still fences it',
    () async {
      final client = _Client([(_) => _response(_plan), _write, _write]);
      await _producer(
        client,
        [],
        observer: ({required phase, required fileId, required response}) =>
            throw StateError('private observer error'),
      ).generate();
      expect(client.requests, hasLength(3));
      var cancelled = false;
      final cancelledClient = _Client([(_) => _response(_plan)]);
      final drafts = <SourceWorkspaceSnapshot>[];
      await expectLater(
        _producer(
          cancelledClient,
          drafts,
          cancelled: () => cancelled,
          observer: ({required phase, required fileId, required response}) {
            cancelled = true;
          },
        ).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (failure) => failure.code,
            'code',
            GeneratedTaskFailureCode.interrupted,
          ),
        ),
      );
      expect(cancelledClient.requests, hasLength(1));
      expect(drafts, isEmpty);
    },
  );

  for (final field in ['fileId', 'baseCursor', 'prefixHash']) {
    test(
      'a rejected $field is corrected without accepting its source',
      () async {
        final drafts = <SourceWorkspaceSnapshot>[];
        final client = _Client([
          (_) => _response(_plan),
          (messages) => _response({
            ..._binding(messages),
            field: field == 'baseCursor' ? 999 : 'wrong-binding',
            'append': 'REJECTED_SOURCE_MUST_NOT_BE_SAVED',
            'done': true,
          }),
          (messages) {
            expect(messages.first.content, contains('sourceBindingInvalid'));
            return _write(messages);
          },
          _write,
        ]);
        final result = await _producer(client, drafts).generate();
        expect(client.requests, hasLength(4));
        expect(
          client.requests.every(
            (messages) => messages.last.content == _request,
          ),
          isTrue,
        );
        expect(jsonEncode(result.toJson()), isNot(contains('REJECTED_SOURCE')));
        expect(
          drafts.every(
            (draft) => !jsonEncode(draft.toJson()).contains('REJECTED_SOURCE'),
          ),
          isTrue,
        );
        expect(drafts.last.stallCount, 0);
      },
    );
  }

  test(
    'ordinary extra fields are rejected and corrected as source data',
    () async {
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) => _response(_plan),
        (messages) => _response({
          ..._binding(messages),
          'append': 'BAD',
          'done': true,
          'note': 'PRIVATE_UNVALIDATED_NOTE',
        }),
        (messages) {
          expect(messages.first.content, contains('unsupportedFields'));
          expect(
            messages.first.content,
            isNot(contains('PRIVATE_UNVALIDATED_NOTE')),
          );
          return _write(messages);
        },
        _write,
      ]);
      await _producer(client, drafts).generate();
      expect(
        drafts.every(
          (draft) =>
              !jsonEncode(draft.toJson()).contains('PRIVATE_UNVALIDATED_NOTE'),
        ),
        isTrue,
      );
    },
  );

  test(
    'ordinary plan fields can be corrected without persisting them',
    () async {
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) => _response({..._plan, 'note': 'PRIVATE_UNVALIDATED_PLAN_NOTE'}),
        (messages) {
          expect(messages.first.content, contains('unsupportedFields'));
          expect(
            messages.first.content,
            isNot(contains('PRIVATE_UNVALIDATED_PLAN_NOTE')),
          );
          return _response(_plan);
        },
        _write,
        _write,
      ]);
      await _producer(client, drafts).generate();
      expect(
        drafts.every(
          (draft) => !jsonEncode(
            draft.toJson(),
          ).contains('PRIVATE_UNVALIDATED_PLAN_NOTE'),
        ),
        isTrue,
      );
    },
  );

  test(
    'a rejected repair binding uses retained source and host facts',
    () async {
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) => _response(_plan),
        _write,
        _write,
        (_) => _response({
          'fileId': 'logic',
          'baseHash': 'wrong',
          'edits': [
            {
              'oldText': 'const allRequestedMechanics=true;',
              'newText': 'REJECTED_REPAIR',
            },
          ],
        }),
        (messages) {
          expect(messages.first.content, contains('sourceBindingInvalid'));
          expect(messages.first.content, isNot(contains('REJECTED_REPAIR')));
          return _response({
            'fileId': 'logic',
            'baseHash': sourceWorkspaceDigest(
              'const allRequestedMechanics=true;',
            ),
            'edits': [
              {
                'oldText': 'const allRequestedMechanics=true;',
                'newText': 'const allRequestedMechanics=true;const fixed=true;',
              },
            ],
          });
        },
      ]);
      final producer = _producer(client, drafts);
      final original = await producer.generate();
      final result = await producer.repair(
        original,
        'surface worker first frame rejected: runtime_failed',
      );
      expect(
        (result.actions.single['surface'] as Map)['js'],
        'const allRequestedMechanics=true;const fixed=true;',
      );
      expect(
        drafts.every(
          (draft) => !jsonEncode(draft.toJson()).contains('REJECTED_REPAIR'),
        ),
        isTrue,
      );
    },
  );

  test(
    'repair authority fields terminate before any new strategy or source write',
    () async {
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) => _response(_plan),
        _write,
        _write,
        (_) => _response({
          'fileId': 'logic',
          'baseHash': sourceWorkspaceDigest(
            'const allRequestedMechanics=true;',
          ),
          'edits': [],
          'actions': [],
        }),
      ]);
      final producer = _producer(client, drafts);
      final original = await producer.generate();
      await expectLater(
        producer.repair(
          original,
          'surface worker first frame rejected: runtime_failed',
        ),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (failure) => failure.code,
            'code',
            GeneratedTaskFailureCode.responseInvalid,
          ),
        ),
      );
      expect(client.requests, hasLength(4));
      expect(
        drafts.last.diagnostic!.reason,
        SourceDiagnosticReason.authorityRejected,
      );
      expect(
        drafts.last.files.singleWhere((file) => file.plan.id == 'logic').source,
        'const allRequestedMechanics=true;',
      );
    },
  );

  test(
    'supported embedded source compiles without unnecessary model repair',
    () async {
      // Minimal generic protocol fixture; no user-generated game source is stored here.
      const html =
          '<html><head><style>main{color:blue}</style></head><body><main id="board">Paddle and split balls</main><script>const splitBalls=true;</script></body></html>';
      const css = 'main{min-height:100vh}';
      const js = 'const paddle=true;';
      const fixedHtml = '<main id="board">Paddle and split balls</main>';
      final drafts = <SourceWorkspaceSnapshot>[];
      ProjectSourceResponse write(List<Message> messages, String text) =>
          _response({..._binding(messages), 'append': text, 'done': true});
      final client = _Client([
        (_) => _response({
          ..._plan,
          'files': [
            {'id': 'page', 'kind': 'html', 'purpose': 'All markup'},
            {'id': 'style', 'kind': 'css', 'purpose': 'All styles'},
            {
              'id': 'logic',
              'kind': 'js',
              'purpose': 'All mechanics',
              'dependsOn': ['page', 'style'],
            },
          ],
        }),
        (messages) => write(messages, html),
        (messages) => write(messages, css),
        (messages) => write(messages, js),
      ]);
      final producer = _producer(client, drafts);
      final original = await producer.generate();
      final after = original.actions.single['surface'] as Map;
      expect(after['html'], fixedHtml);
      expect(after['css'], contains(css));
      expect(after['css'], contains('main{color:blue}'));
      expect(after['js'], contains(js));
      expect(after['js'], contains('const splitBalls=true;'));
      expect(
        (after['js'] as String).indexOf(js),
        lessThan((after['js'] as String).indexOf('const splitBalls=true;')),
      );
      final sources = {
        for (final file in drafts.last.files) file.plan.id: file,
      };
      expect(sources['page']!.source, html);
      expect(sources['style']!.source, css);
      expect(sources['logic']!.source, js);
      expect(
        sources.values.every((file) => file.previousSource == null),
        isTrue,
      );
      SurfaceProjectValidator.validateForPublicGame(
        SurfaceProject.fromJson(after),
      );
      expect(client.requests, hasLength(4));
    },
  );

  test('plan dependency diagnostic reaches the correcting request', () async {
    final drafts = <SourceWorkspaceSnapshot>[];
    final broken = {
      ..._plan,
      'files': [
        {'id': 'page', 'kind': 'html', 'purpose': '全部页面'},
        {
          'id': 'logic',
          'kind': 'js',
          'purpose': '全部玩法',
          'dependsOn': ['missing-file'],
        },
      ],
    };
    final client = _Client([
      (_) => _response(broken),
      (messages) {
        expect(messages.first.content, contains('dependencyMissing'));
        expect(messages.first.content, contains('missing-file'));
        return _response({
          ..._plan,
          'files': [
            for (final file in _plan['files']! as List)
              {...file as Map, 'dependsOn': <String>[]},
          ],
        });
      },
      _write,
      _write,
    ]);
    await _producer(client, drafts).generate();
    expect(drafts.last.blueprintComplete, isTrue);
    expect(drafts.last.files.every((file) => file.complete), isTrue);
  });

  test(
    'required source kinds are explained before asking for more plan data',
    () async {
      final client = _Client([
        (_) => _response({..._plan, 'files': []}),
        (messages) {
          expect(messages.first.content, contains('requiredFilesMissing'));
          expect(messages.first.content, contains('"html","js"'));
          return _response(_plan);
        },
        _write,
        _write,
      ]);
      await _producer(client, []).generate();
    },
  );

  test(
    'empty chunks identify the current append phase and stop boundedly',
    () async {
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) => _response(_plan),
        for (var index = 0; index < 3; index++)
          (messages) {
            if (index > 0) expect(messages.first.content, contains('stalled'));
            return _response({
              ..._binding(messages),
              'append': '',
              'done': false,
            });
          },
      ]);
      await expectLater(
        _producer(client, drafts).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (failure) => failure.code,
            'code',
            GeneratedTaskFailureCode.generationStalled,
          ),
        ),
      );
      expect(drafts.last.diagnostic!.phase, SourceDiagnosticPhase.append);
      expect(drafts.last.diagnostic!.reason, SourceDiagnosticReason.stalled);
      expect(drafts.last.diagnostic!.fileId, 'page');
      expect(drafts.last.stallCount, 3);
      expect(drafts.last.files.single.source, isEmpty);
      expect(client.requests, hasLength(4));
    },
  );

  for (final field in [
    'actions',
    'manifest',
    'permissions',
    'path',
    'surfaceId',
    'surfaceKind',
    'experienceType',
    'rendering',
    'category',
    'kind',
  ]) {
    test('$field cannot become source authority through recovery', () async {
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) => _response(_plan),
        (messages) => _response({
          ..._binding(messages),
          'append': 'FORBIDDEN',
          'done': true,
          field: [],
        }),
      ]);
      await expectLater(
        _producer(client, drafts).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (failure) => failure.code,
            'code',
            GeneratedTaskFailureCode.responseInvalid,
          ),
        ),
      );
      expect(client.requests, hasLength(2));
      expect(
        drafts.last.diagnostic!.reason,
        SourceDiagnosticReason.authorityRejected,
      );
      expect(drafts.last.files.single.source, isEmpty);
    });
  }

  test(
    'cancellation before correction never dispatches the second source request',
    () async {
      var cancelled = false;
      final client = _Client([
        (_) => _response(_plan),
        (messages) {
          cancelled = true;
          return _response({
            ..._binding(messages),
            'baseCursor': 999,
            'append': 'BAD',
            'done': true,
          });
        },
      ]);
      await expectLater(
        _producer(client, [], cancelled: () => cancelled).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (failure) => failure.code,
            'code',
            GeneratedTaskFailureCode.interrupted,
          ),
        ),
      );
      expect(client.requests, hasLength(2));
    },
  );

  test(
    'an explicit retained retry gets a fresh stall budget without losing source or diagnostic',
    () async {
      final plan = SourceBlueprint.fromJson(_plan);
      final initial = SourceWorkspaceSnapshot(
        requirementSha256: sourceWorkspaceDigest(_request),
        experienceType: 'game',
        blueprint: plan,
        blueprintComplete: true,
        files: [
          SourceFileSnapshot(
            plan: plan.files.first,
            source: '<main id="board">',
          ),
        ],
        activeFileId: 'page',
        stallCount: 3,
        diagnostic: const SourceGenerationDiagnostic(
          phase: SourceDiagnosticPhase.append,
          reason: SourceDiagnosticReason.jsonIncomplete,
          fileId: 'page',
        ),
      );
      final drafts = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (messages) {
          expect(messages.first.content, contains('jsonIncomplete'));
          return _response({
            ..._binding(messages),
            'baseCursor': 999,
            'append': 'BAD',
            'done': true,
          });
        },
        (messages) => _response({
          ..._binding(messages),
          'append': 'Complete</main>',
          'done': true,
        }),
        _write,
      ]);
      final result = await _producer(
        client,
        drafts,
        initial: initial,
      ).generate();
      expect(drafts.first.stallCount, 0);
      expect(drafts.first.files.single.source, initial.files.single.source);
      expect(
        drafts.first.diagnostic!.reason,
        SourceDiagnosticReason.jsonIncomplete,
      );
      expect(
        (result.actions.single['surface'] as Map)['html'],
        '<main id="board">Complete</main>',
      );
    },
  );
}

class _Client extends LLMClient implements ProjectSourceLLMClient {
  _Client(this.responses);
  final List<ProjectSourceResponse Function(List<Message>)> responses;
  final requests = <List<Message>>[];
  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) async {
    await onAdmitted?.call();
    requests.add(List.unmodifiable(messages));
    return responses.removeAt(0)(messages);
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('not ordinary chat');
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('not legacy JSON');
}
