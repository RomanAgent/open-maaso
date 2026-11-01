import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/tasks/source_execution_checkpoint.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';

void main() {
  SourceWorkspaceSnapshot draft() => SourceWorkspaceSnapshot(
    requirementSha256: sourceWorkspaceDigest('make a game'),
    experienceType: 'game',
  );

  SourceExecutionCheckpoint request(SourceWorkspaceSnapshot snapshot) =>
      SourceExecutionCheckpoint(
        operation: 'plan',
        workspaceDigest: snapshot.executionDigest,
        rulesDigest: sourceWorkspaceDigest('current policy'),
        systemPrompt: 'Return the remaining plan as JSON.',
        userPrompt: 'make a game',
        phase: 'planning',
        displayBytes: 32768,
        state: {'recentReads': <Object?>[]},
      );

  test('legacy source draft stays readable without inventing a request', () {
    final old = draft().toJson();
    expect(old['schemaVersion'], 1);
    final restored = SourceWorkspaceSnapshot.fromJson(old);
    expect(restored.executionCheckpoint, isNull);
    expect(restored.toJson(), old);
  });

  test('checkpoint round trip retains exact prompt and source identity', () {
    final initial = draft();
    final pending = request(initial);
    final saved = initial.withExecutionCheckpoint(pending).toJson();
    expect(saved['schemaVersion'], 2);
    final restored = SourceWorkspaceSnapshot.fromJson(
      jsonDecode(jsonEncode(saved)),
    );
    expect(restored.executionCheckpoint!.toJson(), pending.toJson());
    expect(restored.executionDigest, initial.executionDigest);
    expect(restored.withExecutionCheckpoint(null).toJson(), initial.toJson());
  });

  test('request context cannot mutate through a shared map reference', () {
    final pending = request(draft());
    final digest = pending.requestDigest;
    (pending.state['recentReads'] as List).add({'fileId': 'other'});
    expect(pending.state['recentReads'], isEmpty);
    expect(pending.requestDigest, digest);
  });

  test('changed prompt or missing checkpoint field rejects stored data', () {
    final pending = request(draft());
    expect(
      () => SourceExecutionCheckpoint.fromJson({
        ...pending.toJson(),
        'systemPrompt': 'different request',
      }),
      throwsFormatException,
    );
    final missing = pending.toJson()..remove('fileId');
    missing['unknown'] = null;
    expect(
      () => SourceExecutionCheckpoint.fromJson(missing),
      throwsFormatException,
    );
  });

  test('new schema cannot silently fall back after losing its checkpoint', () {
    expect(
      () => SourceWorkspaceSnapshot.fromJson({
        ...draft().toJson(),
        'schemaVersion': 2,
      }),
      throwsA(isA<SourceWorkspaceProtocolException>()),
    );
  });

  test('checkpoint has a separate bounded storage envelope', () {
    expect(
      () => SourceExecutionCheckpoint(
        operation: 'plan',
        workspaceDigest: draft().executionDigest,
        rulesDigest: sourceWorkspaceDigest('policy'),
        systemPrompt: 'a' * SourceExecutionCheckpoint.maxBytes,
        userPrompt: 'game',
        phase: 'planning',
        displayBytes: 32768,
        state: const {},
      ),
      throwsFormatException,
    );
  });
}
