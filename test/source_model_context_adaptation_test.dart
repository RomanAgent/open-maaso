import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/hosted_llm_failure.dart';
import 'package:maaso/src/core/services/privacy_guarded_llm_client.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const _requirement = '实现全部关卡、分裂道具、触摸与键盘控制，以及用户指定的每个细节；不要简化。';
const _contextRejection = LLMResponseIntegrityException.publicFailure(
  'modelContextLimit',
);

SourceWorkspaceSnapshot _draft({String prefix = 'const allFeatures='}) {
  final page = SourceFilePlan(
    id: 'page',
    kind: SourceFileKind.html,
    purpose: 'Every requested screen',
  );
  final style = SourceFilePlan(
    id: 'style',
    kind: SourceFileKind.css,
    purpose: 'Every requested visual detail',
  );
  final logic = SourceFilePlan(
    id: 'logic',
    kind: SourceFileKind.js,
    purpose: 'Every requested rule',
    dependsOn: ['page', 'style'],
  );
  return SourceWorkspaceSnapshot(
    requirementSha256: sourceWorkspaceDigest(_requirement),
    experienceType: 'game',
    blueprintComplete: true,
    blueprint: SourceBlueprint(
      title: 'Full game',
      summary: 'All original features',
      skillInstructions: 'Play every level',
      interfaces: 'Retain all original page, style and logic contracts',
      files: [page, style, logic],
    ),
    files: [
      SourceFileSnapshot(
        plan: page,
        source: '<main>${'界' * 7000}</main>',
        complete: true,
      ),
      SourceFileSnapshot(
        plan: style,
        source: '/*${'x' * 14000}*/main{color:blue}',
        complete: true,
      ),
      SourceFileSnapshot(plan: logic, source: prefix),
    ],
  );
}

Map<String, dynamic> _display(List<Message> messages) {
  const marker = 'Host-owned source display (immutable data): ';
  final prompt = messages.first.content;
  return jsonDecode(prompt.substring(prompt.indexOf(marker) + marker.length))
      as Map<String, dynamic>;
}

int _displayBytes(List<Message> messages) {
  final display = _display(messages);
  final sources = [
    display['current'] as Map,
    ...(display['dependencies'] as List? ?? []).cast<Map>(),
  ];
  return sources.fold<int>(
    0,
    (sum, source) =>
        sum +
        (source['ranges'] as List).fold<int>(
          0,
          (bytes, range) => bytes + utf8.encode(range['text'] as String).length,
        ),
  );
}

ProjectSourceResponse _response(Object value) => ProjectSourceResponse(
  visibleText: jsonEncode(value),
  termination: ProjectSourceTermination.complete,
);

ProjectSourceResponse _chunk(List<Message> messages) {
  final binding = RegExp(
    r'"fileId":"([^"]+)","baseCursor":([0-9]+),"prefixHash":"([a-f0-9]{64})"',
  ).firstMatch(messages.first.content)!;
  return _response({
    'fileId': binding[1],
    'baseCursor': int.parse(binding[2]!),
    'prefixHash': binding[3],
    'append': 'true;',
    'done': true,
  });
}

class _Client extends LLMClient implements ProjectSourceLLMClient {
  _Client(this.respond);
  final FutureOr<ProjectSourceResponse> Function(List<Message>, int) respond;
  final requests = <List<Message>>[];
  final timeouts = <Duration?>[];
  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) async {
    await onAdmitted?.call();
    requests.add(List.unmodifiable(messages));
    timeouts.add(timeout);
    return await respond(messages, requests.length);
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('must remain project source mode');
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('must preserve roles and full requirement');
}

GeneratedGameArtifact _producer(
  LLMClient client, {
  SourceWorkspaceSnapshot? draft,
  bool Function()? shouldCancel,
  FutureOr<void> Function(SourceWorkspaceSnapshot)? onDraft,
}) => GeneratedGameArtifact(
  client: client,
  instruction: _requirement,
  surfaceId: 'owned-game',
  zh: true,
  initialDraft: draft ?? _draft(),
  shouldCancel: shouldCancel,
  onDraft: onDraft,
);

void main() {
  for (final rejection in [
    _contextRejection,
    const HostedLLMFailure(HostedLLMFailureKind.contextLimit),
  ]) {
    test(
      '${rejection.runtimeType} shrinks display only and retains exact bindings, requirement and every source byte',
      () async {
        final initial = _draft();
        final original = jsonEncode(initial.toJson());
        final saved = <SourceWorkspaceSnapshot>[];
        final client = _Client((messages, _) {
          expect(messages.last.role, 'user');
          expect(messages.last.content, _requirement);
          final current = _display(messages)['current'] as Map;
          expect(current['sha256'], initial.files.last.prefixHash);
          expect(current['fullBytes'], initial.files.last.cursor);
          expect(
            messages.first.content,
            contains('"baseCursor":${initial.files.last.cursor}'),
          );
          expect(
            messages.first.content,
            contains('"prefixHash":"${initial.files.last.prefixHash}"'),
          );
          if (_displayBytes(messages) > 4096) throw rejection;
          return _chunk(messages);
        });
        final result = await _producer(
          client,
          draft: initial,
          onDraft: saved.add,
        ).generate();
        expect(client.requests.length, greaterThan(1));
        final sizes = client.requests.map(_displayBytes).toList();
        for (var index = 1; index < sizes.length; index++) {
          expect(sizes[index], lessThan(sizes[index - 1]));
        }
        final surface = result.actions.single['surface'] as Map;
        expect(surface['html'], initial.files[0].source);
        expect(surface['css'], initial.files[1].source);
        expect(surface['js'], '${initial.files.last.source}true;');
        expect(jsonEncode(initial.toJson()), original);
        expect(saved.last.requirementSha256, initial.requirementSha256);
        expect(saved.last.blueprint!.toJson(), initial.blueprint!.toJson());
        expect(saved.last.files[0].source, initial.files[0].source);
        expect(saved.last.files[1].source, initial.files[1].source);
        expect(saved, hasLength(2)); // Activation and the accepted append only.
        expect(client.timeouts, everyElement(isNull));
      },
    );
  }

  test(
    'an inspection survives context retry without duplicate registration',
    () async {
      const marker = 'OWNED_MIDDLE_CONTRACT';
      final prefix =
          '/*${'x' * 40000}$marker${'y' * 40000}*/const allFeatures=';
      final saved = <SourceWorkspaceSnapshot>[];
      var rejected = false;
      final client = _Client((messages, call) {
        if (call == 1) {
          expect(messages.first.content, isNot(contains(marker)));
          return _response({
            'read': {'fileId': 'logic', 'startByte': 40002, 'maxBytes': 4096},
          });
        }
        expect(messages.first.content, contains(marker));
        final read = _display(messages)['readResult'] as Map;
        expect(read['sha256'], sourceWorkspaceDigest(prefix));
        expect(read['fileId'], 'logic');
        if (!rejected) {
          rejected = true;
          throw _contextRejection;
        }
        return _chunk(messages);
      });
      final result = await _producer(
        client,
        draft: _draft(prefix: prefix),
        onDraft: saved.add,
      ).generate();
      expect(client.requests, hasLength(3));
      expect((result.actions.single['surface'] as Map)['js'], '${prefix}true;');
      expect(saved, hasLength(2));
    },
  );

  test(
    'capacity exhaustion reaches zero display and preserves recoverable source',
    () async {
      final initial = _draft();
      final saved = <SourceWorkspaceSnapshot>[];
      final client = _Client((_, _) => throw _contextRejection);
      await expectLater(
        _producer(client, draft: initial, onDraft: saved.add).generate(),
        throwsA(same(_contextRejection)),
      );
      expect(_displayBytes(client.requests.last), 0);
      expect(client.requests.length, lessThan(20));
      expect(
        saved.last.diagnostic!.reason,
        SourceDiagnosticReason.contextTooLarge,
      );
      expect(saved.last.files.last.source, initial.files.last.source);
      expect(saved.last.files.last.prefixHash, initial.files.last.prefixHash);
      expect(saved.last.requirementSha256, initial.requirementSha256);
      expect(
        client.requests.map((m) => m.last.content),
        everyElement(_requirement),
      );
    },
  );

  test(
    'planning without optional source never repeats a rejected request',
    () async {
      final client = _Client((_, _) => throw _contextRejection);
      await expectLater(
        GeneratedGameArtifact(
          client: client,
          instruction: _requirement,
          surfaceId: 'owned-game',
          zh: true,
        ).generate(),
        throwsA(same(_contextRejection)),
      );
      expect(client.requests, hasLength(1));
    },
  );

  test(
    'cancellation after context rejection forbids another dispatch',
    () async {
      var cancelled = false;
      final client = _Client((_, _) {
        cancelled = true;
        throw _contextRejection;
      });
      await expectLater(
        _producer(client, shouldCancel: () => cancelled).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (error) => error.code,
            'code',
            GeneratedTaskFailureCode.interrupted,
          ),
        ),
      );
      expect(client.requests, hasLength(1));
    },
  );

  test('privacy is checked again before every adaptive dispatch', () async {
    var permissionChecks = 0;
    final denied = StateError('permission revoked');
    final client = _Client((_, _) => throw _contextRejection);
    final guarded = privacyGuardedLLMClient(client, () async {
      permissionChecks++;
      if (permissionChecks > 2) throw denied;
    });
    await expectLater(_producer(guarded).generate(), throwsA(same(denied)));
    expect(client.requests, hasLength(1));
    expect(permissionChecks, 3);
  });

  for (final failure in <Object>[
    const HostedLLMFailure(HostedLLMFailureKind.authentication),
    const HostedLLMFailure(HostedLLMFailureKind.quota),
    const HostedLLMFailure(HostedLLMFailureKind.consent),
    const HostedLLMFailure(HostedLLMFailureKind.membership),
    const LLMResponseIntegrityException.publicFailure('modelStreamInterrupted'),
    const LLMResponseIntegrityException.publicFailure('modelAuthentication'),
    const LLMResponseIntegrityException.publicFailure('modelQuotaExceeded'),
    const LLMResponseIntegrityException.publicFailure('modelSafetyBlocked'),
    const LLMResponseIntegrityException.publicFailure('modelRateLimited'),
    const LLMResponseIntegrityException.publicFailure('modelUnavailable'),
    const LLMResponseIntegrityException.invalidResponse(),
    LLMResponseIntegrityException.outputTruncated(
      facts: LLMOutputFacts.fromBounded(completionTokens: 100),
    ),
    StateError('modelContextLimit'),
    TimeoutException('unknown dispatch outcome'),
  ]) {
    test(
      'terminal ${failure.runtimeType}:$failure never adaptively retries',
      () async {
        final client = _Client((_, _) => throw failure);
        await expectLater(_producer(client).generate(), throwsA(same(failure)));
        expect(client.requests, hasLength(1));
      },
    );
  }
}
