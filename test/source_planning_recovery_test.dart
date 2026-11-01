import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const _request = '完整实现用户请求，不缩减需求；本测试只检验规划协议';
Map<String, Object?> _fixture(String name) =>
    (jsonDecode(
              File('test/fixtures/source_plans/$name.json').readAsStringSync(),
            )
            as Map)
        .cast<String, Object?>();
SourceWorkspaceSnapshot _initial(Map<String, Object?> blueprint) =>
    SourceWorkspaceSnapshot(
      requirementSha256: sourceWorkspaceDigest(_request),
      experienceType: 'game',
      blueprint: SourceBlueprint.fromJson(blueprint),
      blueprintComplete: false,
    );
ProjectSourceResponse _response(Object data, {bool length = false}) =>
    ProjectSourceResponse(
      visibleText: jsonEncode(data),
      termination: length
          ? ProjectSourceTermination.knownLength
          : ProjectSourceTermination.complete,
    );
ProjectSourceResponse _source(List<Message> messages) {
  final match = RegExp(
    r'"fileId":"([^"]+)","baseCursor":([0-9]+),"prefixHash":"([a-f0-9]{64})"',
  ).firstMatch(messages.first.content)!;
  return _response({
    'fileId': match[1],
    'baseCursor': int.parse(match[2]!),
    'prefixHash': match[3],
    'append': match[1]!.contains('style')
        ? 'main{min-height:100vh}'
        : match[1]!.contains('game')
        ? 'const fixture=true;'
        : '<main>Fixture</main>',
    'done': true,
  });
}

GeneratedGameArtifact _producer(
  _Client client, {
  SourceWorkspaceSnapshot? initial,
  required List<SourceWorkspaceSnapshot> saved,
}) => GeneratedGameArtifact(
  client: client,
  instruction: _request,
  surfaceId: 'host-planning-test',
  zh: true,
  initialDraft: initial,
  onDraft: saved.add,
);

void main() {
  for (final name in ['pvz', 'contra']) {
    test(
      '$name actual three-file blueprint resumes from a files-only plan EOF page',
      () async {
        final original = _fixture(name);
        final saved = <SourceWorkspaceSnapshot>[];
        final client = _Client([
          (_) => _response({'files': [], 'planComplete': true}),
          _source,
          _source,
          _source,
        ]);
        await _producer(
          client,
          initial: _initial(original),
          saved: saved,
        ).generate();
        expect(client.messages, hasLength(4));
        expect(
          client.messages.first.first.content,
          contains('do not copy or restate'),
        );
        final completedPlan = saved.firstWhere(
          (snapshot) => snapshot.blueprintComplete,
        );
        expect(
          completedPlan.files,
          isEmpty,
          reason: 'Plan EOF is not source or game completion',
        );
        expect(completedPlan.blueprint!.toJson(), original);
        expect(
          completedPlan.diagnostic!.reason,
          SourceDiagnosticReason.planCompleted,
        );
      },
    );

    test(
      '$name complete closed known-length plan can end planning, while source length cannot end a file',
      () async {
        final original = _fixture(name);
        final saved = <SourceWorkspaceSnapshot>[];
        final client = _Client([
          (_) => _response({...original, 'done': true}, length: true),
          _source,
          _source,
          _source,
        ]);
        await _producer(client, saved: saved).generate();
        expect(client.messages, hasLength(4));
        final plan = saved.firstWhere((snapshot) => snapshot.blueprintComplete);
        expect(plan.diagnostic!.knownLength, isTrue);
        expect(plan.diagnostic!.closedJson, isTrue);
        expect(plan.diagnostic!.explicitPlanEOF, isTrue);
        expect(plan.files, isEmpty);
        final file = SourceFileSnapshot(plan: plan.blueprint!.files.first);
        final raw = jsonEncode({
          'fileId': file.plan.id,
          'baseCursor': 0,
          'prefixHash': file.prefixHash,
          'append': 'complete code',
          'done': true,
        });
        expect(
          SourceChunk.decode(raw, knownLength: true, file: file).done,
          isFalse,
        );
      },
    );
  }

  test(
    'full compatible continuation may reword ordinary metadata and purpose without replacing host-retained content',
    () async {
      final original = _fixture('pvz');
      final altered = {
        ...original,
        'title': '更完整的新标题',
        'summary': '改写的摘要',
        'skillInstructions': '改写说明',
        'interfaces': '改写接口描述',
        'files': (original['files'] as List)
            .map(
              (row) => {
                ...(row as Map).cast<String, Object?>(),
                'purpose': 'Same file, reworded purpose',
              },
            )
            .toList(),
        'done': true,
      };
      final saved = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) => _response(altered),
        _source,
        _source,
        _source,
      ]);
      await _producer(
        client,
        initial: _initial(original),
        saved: saved,
      ).generate();
      expect(
        saved
            .firstWhere((snapshot) => snapshot.blueprintComplete)
            .blueprint!
            .toJson(),
        original,
      );
      expect(client.messages, hasLength(4));
    },
  );

  test(
    'metadata absent from the first closed EOF page is preserved as a partial plan and supplemented automatically',
    () async {
      final original = _fixture('contra');
      final saved = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) => _response({'files': original['files'], 'done': true}),
        (messages) {
          expect(
            messages.first.content,
            contains('Still missing metadata fields'),
          );
          return _response({...original, 'files': [], 'planComplete': true});
        },
        _source,
        _source,
        _source,
      ]);
      await _producer(client, saved: saved).generate();
      expect(saved.first.blueprintComplete, isFalse);
      expect(
        saved.first.diagnostic!.reason,
        SourceDiagnosticReason.missingMetadata,
      );
      expect(saved.first.files, isEmpty);
      expect(
        saved
            .firstWhere((snapshot) => snapshot.blueprintComplete)
            .blueprint!
            .toJson(),
        original,
      );
      expect(client.messages, hasLength(5));
    },
  );

  test(
    'whitespace-only metadata can be supplemented with full strings without trimming valid content',
    () async {
      final original = _fixture('pvz');
      final whitespace = {
        ...original,
        'title': ' ',
        'summary': '\n',
        'skillInstructions': '\t',
        'interfaces': '  ',
      };
      final filled = {
        ...original,
        'title': '  完整标题原文  ',
        'files': [],
        'planComplete': true,
      };
      final saved = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) => _response({...whitespace, 'done': true}),
        (_) => _response(filled),
        _source,
        _source,
        _source,
      ]);
      await _producer(client, saved: saved).generate();
      expect(saved.first.blueprintComplete, isFalse);
      final complete = saved.firstWhere(
        (snapshot) => snapshot.blueprintComplete,
      );
      expect(complete.blueprint!.title, '  完整标题原文  ');
      expect(complete.blueprint!.summary, original['summary']);
      expect(
        complete.blueprint!.skillInstructions,
        original['skillInstructions'],
      );
      expect(complete.blueprint!.interfaces, original['interfaces']);
    },
  );

  test(
    'cyclic dependency corrections are rejected before any source and retain the earlier valid plan',
    () async {
      final original = _fixture('contra');
      final cyclic = (original['files'] as List)
          .map((row) => (row as Map).cast<String, Object?>())
          .toList();
      cyclic[2] = {
        ...cyclic[2],
        'dependsOn': ['index.html'],
      };
      final saved = <SourceWorkspaceSnapshot>[];
      final client = _Client(
        List.generate(
          3,
          (_) =>
              (_) => _response({'files': cyclic, 'planComplete': true}),
        ),
      );
      await expectLater(
        _producer(client, initial: _initial(original), saved: saved).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (error) => error.code,
            'code',
            GeneratedTaskFailureCode.generationStalled,
          ),
        ),
      );
      expect(client.messages, hasLength(3));
      expect(saved.last.blueprint!.toJson(), original);
      expect(saved.last.files, isEmpty);
      expect(
        saved.last.diagnostic!.reason,
        SourceDiagnosticReason.dependencyCycle,
      );
    },
  );

  test(
    'a revoked owner never persists provider-failure diagnostics after cancellation',
    () async {
      var cancelled = false;
      final saved = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) {
          cancelled = true;
          throw const LLMResponseIntegrityException.invalidResponse();
        },
      ]);
      final producer = GeneratedGameArtifact(
        client: client,
        instruction: _request,
        surfaceId: 'owned-test',
        zh: true,
        initialDraft: _initial(_fixture('pvz')),
        onDraft: saved.add,
        shouldCancel: () => cancelled,
      );
      await expectLater(
        producer.generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (error) => error.code,
            'code',
            GeneratedTaskFailureCode.interrupted,
          ),
        ),
      );
      expect(saved, isEmpty);
      expect(client.messages, hasLength(1));
    },
  );

  test(
    'dependencies can be corrected before source begins, but file kind and authority remain fixed',
    () async {
      final original = _fixture('contra');
      final files = List<Map<String, Object?>>.from(
        (original['files'] as List).map(
          (row) => (row as Map).cast<String, Object?>(),
        ),
      );
      files.first = {
        ...files.first,
        'dependsOn': ['missing-before-correction'],
      };
      final saved = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        (_) => _response({'files': original['files'], 'planComplete': true}),
        _source,
        _source,
        _source,
      ]);
      await _producer(
        client,
        initial: _initial({...original, 'files': files}),
        saved: saved,
      ).generate();
      expect(
        saved
            .firstWhere((snapshot) => snapshot.blueprintComplete)
            .blueprint!
            .toJson(),
        original,
      );
      for (final invalid in [
        {
          'files': [
            {...files.first, 'kind': 'js'},
          ],
          'planComplete': true,
        },
        {
          'files': [],
          'planComplete': true,
          'manifest': {'events': [], 'actions': []},
        },
      ]) {
        final rejected = <SourceWorkspaceSnapshot>[];
        final bad = _Client([(_) => _response(invalid)]);
        await expectLater(
          _producer(
            bad,
            initial: _initial(original),
            saved: rejected,
          ).generate(),
          throwsA(isA<GeneratedTaskFailure>()),
        );
        expect(bad.messages, hasLength(1));
        expect(rejected.last.blueprint!.toJson(), original);
        expect(
          rejected.last.diagnostic!.reason,
          invalid.containsKey('manifest')
              ? SourceDiagnosticReason.authorityRejected
              : SourceDiagnosticReason.identityChanged,
        );
      }
    },
  );

  test(
    'an unclosed length plan is not finalized and can use a closed EOF delta next',
    () async {
      final original = _fixture('pvz');
      final saved = <SourceWorkspaceSnapshot>[];
      final raw = jsonEncode({...original, 'done': true});
      final client = _Client([
        (_) => ProjectSourceResponse(
          visibleText: raw.substring(0, raw.length - 1),
          termination: ProjectSourceTermination.knownLength,
        ),
        (_) => _response({'files': [], 'done': true}),
        _source,
        _source,
        _source,
      ]);
      await _producer(client, saved: saved).generate();
      expect(saved.first.blueprintComplete, isFalse);
      expect(saved.first.diagnostic!.closedJson, isFalse);
      expect(client.messages, hasLength(5));
    },
  );

  test(
    'precise closed diagnostics distinguish fields and provider integrity without retaining payloads',
    () async {
      final initial = _initial(_fixture('pvz'));
      final saved = <SourceWorkspaceSnapshot>[];
      final client = _Client([
        for (var index = 0; index < 3; index++)
          (messages) {
            if (index > 0) {
              expect(messages.first.content, contains('unsupportedFields'));
              expect(messages.first.content, isNot(contains('NEVER_PERSIST')));
            }
            return _response({
              'files': [],
              'planComplete': true,
              'PRIVATE_KEY_OR_THOUGHT': 'NEVER_PERSIST',
            });
          },
      ]);
      await expectLater(
        _producer(client, initial: initial, saved: saved).generate(),
        throwsA(isA<GeneratedTaskFailure>()),
      );
      expect(saved.last.diagnostic!.phase, SourceDiagnosticPhase.planning);
      expect(
        saved.last.diagnostic!.reason,
        SourceDiagnosticReason.unsupportedFields,
      );
      expect(jsonEncode(saved.last.toJson()), isNot(contains('NEVER_PERSIST')));
      expect(
        jsonEncode(saved.last.toJson()),
        isNot(contains('PRIVATE_KEY_OR_THOUGHT')),
      );
      final providerSaved = <SourceWorkspaceSnapshot>[];
      final provider = _Client([
        (_) => throw const LLMResponseIntegrityException.invalidResponse(),
      ]);
      await expectLater(
        _producer(provider, initial: initial, saved: providerSaved).generate(),
        throwsA(isA<LLMResponseIntegrityException>()),
      );
      expect(
        providerSaved.last.diagnostic!.reason,
        SourceDiagnosticReason.providerResponseInvalid,
      );
      expect(
        SourceWorkspaceSnapshot.fromJson(
          providerSaved.last.toJson(),
        ).diagnostic!.toJson(),
        providerSaved.last.diagnostic!.toJson(),
      );
      final corrupted = {
        ...providerSaved.last.toJson(),
        'diagnostic': {
          'phase': 'planning',
          'reason': 'rawProviderBody',
          'raw': 'secret',
        },
      };
      expect(
        () => SourceWorkspaceSnapshot.fromJson(corrupted),
        throwsA(isA<SourceWorkspaceProtocolException>()),
      );
    },
  );
}

class _Client extends LLMClient implements ProjectSourceLLMClient {
  _Client(this.responses);
  final List<ProjectSourceResponse Function(List<Message>)> responses;
  final messages = <List<Message>>[];
  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> request, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) async {
    await onAdmitted?.call();
    messages.add(List.unmodifiable(request));
    return responses.removeAt(0)(request);
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('not source');
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('not legacy JSON');
}
