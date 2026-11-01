import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/source_execution_checkpoint.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';

import 'support/project_source_fixture.dart';

void main() {
  test(
    'a policy upgrade rebuilds only the pending prompt and retains its source read and cursor',
    () async {
      const instruction = 'Create the complete scoring game.';
      const prefix = 'let score=';
      const obsoletePrompt = 'OBSOLETE_AUTHORING_POLICY_MUST_NOT_BE_REPLAYED';
      const transient = LLMResponseIntegrityException.publicFailure(
        'modelUnavailable',
        retryable: true,
      );
      final client = SourceFixtureClient([
        jsonEncode(sourcePlan),
        jsonEncode(boundSourceChunk('screen.html', sourceHtml)),
        jsonEncode(boundSourceChunk('skin.css', sourceCss)),
        jsonEncode(boundSourceChunk('game.js', prefix, done: false)),
        jsonEncode({
          'read': {'fileId': 'screen.html', 'startByte': 0, 'maxBytes': 64},
        }),
        for (var i = 0; i < 6; i++) transient,
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      await expectLater(
        GeneratedGameArtifact(
          client: client,
          instruction: instruction,
          surfaceId: 'owned-policy-upgrade-game',
          zh: false,
          retryDelay: (_) async {},
          onDraft: drafts.add,
        ).generate(),
        throwsA(same(transient)),
      );
      expect(client.requests, hasLength(11));
      final lastDraft = drafts.last;
      final pending = lastDraft.executionCheckpoint!;
      expect(pending.requestPending, isTrue);
      expect(pending.operation, 'write');
      expect(pending.phase, 'inspection');
      final oldDisplay = _sourceDisplay(pending.systemPrompt);
      expect(oldDisplay['readResult'], isNotNull);

      // Simulate a well-formed checkpoint produced by an earlier App policy,
      // rather than tampering with the request without updating its digest.
      final oldPolicy = SourceExecutionCheckpoint(
        operation: pending.operation,
        workspaceDigest: pending.workspaceDigest,
        rulesDigest: sourceWorkspaceDigest('previous-authoring-policy'),
        systemPrompt: obsoletePrompt,
        userPrompt: pending.userPrompt,
        phase: pending.phase,
        displayBytes: pending.displayBytes,
        state: pending.state,
        fileId: pending.fileId,
        requestPending: pending.requestPending,
      );
      final restored = SourceWorkspaceSnapshot.fromJson(
        jsonDecode(
          jsonEncode(lastDraft.withExecutionCheckpoint(oldPolicy).toJson()),
        ),
      );
      final continuation = SourceFixtureClient([
        jsonEncode(
          boundSourceChunk(
            'game.js',
            sourceJs.substring(prefix.length),
            prefix: prefix,
          ),
        ),
      ]);
      final resumedDrafts = <SourceWorkspaceSnapshot>[];
      final result = await GeneratedGameArtifact(
        client: continuation,
        instruction: instruction,
        surfaceId: 'owned-policy-upgrade-game',
        zh: false,
        initialDraft: restored,
        retryDelay: (_) async {},
        onDraft: resumedDrafts.add,
      ).generate();

      expect(continuation.requests, hasLength(1));
      expect(continuation.ordinaryCalls, 0);
      final request = continuation.requests.single;
      expect(request.last.content, instruction);
      final system = request.first.content;
      expect(system, isNot(contains(obsoletePrompt)));
      expect(
        system,
        contains(
          "Implement the user's complete requested full-screen Web game.",
        ),
      );
      expect(system, contains('"baseCursor":${utf8.encode(prefix).length}'));
      expect(
        system,
        contains('"prefixHash":"${sourceWorkspaceDigest(prefix)}"'),
      );
      final display = _sourceDisplay(system);
      expect(display['readResult'], oldDisplay['readResult']);
      expect(display['current'], oldDisplay['current']);
      expect(resumedDrafts.last.executionCheckpoint, isNull);
      final surface = result.actions.single['surface'] as Map;
      expect(surface['html'], sourceHtml);
      expect(surface['css'], sourceCss);
      expect(surface['js'], sourceJs);
    },
  );
}

Map<String, dynamic> _sourceDisplay(String prompt) {
  const marker = '\nHost-owned source display (immutable data): ';
  final start = prompt.lastIndexOf(marker);
  expect(start, greaterThanOrEqualTo(0));
  return jsonDecode(prompt.substring(start + marker.length))
      as Map<String, dynamic>;
}
