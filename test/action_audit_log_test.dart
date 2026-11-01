import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/action/action_audit_log.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';

void main() {
  final epoch = DateTime.utc(2026, 8, 27, 12);

  group('ActionAuditLog lifecycle contract', () {
    test('covers asked, decided, executed, and result under one audit id', () {
      final log = ActionAuditLog();
      final scenarios = <(ActionAuditStage, ActionAuditOutcome, String)>[
        (ActionAuditStage.asked, ActionAuditOutcome.proposed, 'asked'),
        (
          ActionAuditStage.decided,
          ActionAuditOutcome.allowed,
          'approval.allowed',
        ),
        (
          ActionAuditStage.executed,
          ActionAuditOutcome.started,
          'execution.started',
        ),
        (ActionAuditStage.result, ActionAuditOutcome.succeeded, 'ok'),
      ];

      for (var index = 0; index < scenarios.length; index += 1) {
        final scenario = scenarios[index];
        _append(
          log,
          stage: scenario.$1,
          outcome: scenario.$2,
          code: scenario.$3,
          occurredAt: epoch.add(Duration(seconds: index)),
        );
      }

      final entries = log.query(scope: _defaultScope);
      expect(entries.map((entry) => entry.stage), <ActionAuditStage>[
        ActionAuditStage.asked,
        ActionAuditStage.decided,
        ActionAuditStage.executed,
        ActionAuditStage.result,
      ]);
      expect(entries.map((entry) => entry.auditId).toSet(), hasLength(1));
      expect(entries.map((entry) => entry.sequence), <int>[0, 1, 2, 3]);

      final result = entries.last;
      expect(result.accountScope, 'prod|account-a');
      expect(result.agentId, 'agent-a');
      expect(result.runtimeGeneration, 7);
      expect(result.callId, 'call-a');
      expect(result.actionId, 'app_control.execute');
      expect(result.target, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(result.risk, ActionRisk.externalWrite);
      expect(result.consequencePolicy, ActionConsequencePolicy.exactTextCommit);
      expect(result.outcome, ActionAuditOutcome.succeeded);
      expect(result.code, 'ok');
      expect(result.occurredAt.isUtc, isTrue);
    });

    test('canonical argument order produces a stable digest and audit id', () {
      final log = ActionAuditLog();
      final first = _append(
        log,
        arguments: <String, Object?>{
          'z': <Object?>[
            <String, Object?>{'b': 2, 'a': 1},
          ],
          'a': <String, Object?>{'d': true, 'c': null},
        },
        occurredAt: epoch,
      );
      final second = _append(
        log,
        arguments: <String, Object?>{
          'a': <String, Object?>{'c': null, 'd': true},
          'z': <Object?>[
            <String, Object?>{'a': 1, 'b': 2},
          ],
        },
        outcome: ActionAuditOutcome.succeeded,
        code: 'ok',
        occurredAt: epoch.add(const Duration(days: 1)),
      );

      expect(first.argumentsDigest, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(second.argumentsDigest, first.argumentsDigest);
      expect(second.auditId, first.auditId);
    });

    test('every action identity binding changes the audit id', () {
      final log = ActionAuditLog();
      final base = _append(log, occurredAt: epoch);
      final changed = <ActionAuditEntry>[
        _append(log, accountScope: 'prod|account-b', occurredAt: epoch),
        _append(log, agentId: 'agent-b', occurredAt: epoch),
        _append(log, runtimeGeneration: 8, occurredAt: epoch),
        _append(log, callId: 'call-b', occurredAt: epoch),
        _append(log, actionId: 'device.move', occurredAt: epoch),
        _append(
          log,
          arguments: const <String, Object?>{'message': 'changed'},
          occurredAt: epoch,
        ),
        _append(log, target: 'page:other', occurredAt: epoch),
        _append(log, risk: ActionRisk.physicalAction, occurredAt: epoch),
        _append(
          log,
          consequencePolicy: ActionConsequencePolicy.destructive,
          occurredAt: epoch,
        ),
      ];

      expect(
        changed.map((entry) => entry.auditId),
        everyElement(isNot(base.auditId)),
      );
    });
  });

  group('ActionAuditLog privacy and retention', () {
    test('retains only the digest and bounded content-safe metadata', () {
      const secret = 'sk-super-secret-user-authored-display-text';
      final log = ActionAuditLog();
      final entry = _append(
        log,
        arguments: const <String, Object?>{
          'password': secret,
          'nested': <String, Object?>{'display': secret},
        },
        occurredAt: epoch,
      );

      final encoded = jsonEncode(entry.toJson());
      expect(encoded, isNot(contains(secret)));
      expect(entry.toJson(), isNot(contains('arguments')));
      expect(entry.toJson(), isNot(contains('display')));
      expect(entry.toJson()['argumentsDigest'], entry.argumentsDigest);
      expect(entry.auditId, matches(RegExp(r'^audit:[0-9a-f]{64}$')));
    });

    test('low-entropy argument digests are isolated between log instances', () {
      const arguments = <String, Object?>{'confirmed': false};
      final first = _append(
        ActionAuditLog(),
        arguments: arguments,
        occurredAt: epoch,
      );
      final second = _append(
        ActionAuditLog(),
        arguments: arguments,
        occurredAt: epoch,
      );

      expect(first.argumentsDigest, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(second.argumentsDigest, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(second.argumentsDigest, isNot(first.argumentsDigest));
      expect(first.target, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(second.target, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(second.target, isNot(first.target));
    });

    test('capacity is bounded and scoped query results are immutable', () {
      final log = ActionAuditLog(capacity: 2);
      final initialQuery = log.query(scope: _defaultScope);
      _append(log, callId: 'call-0', occurredAt: epoch);
      _append(log, callId: 'call-1', occurredAt: epoch);
      _append(log, callId: 'call-2', occurredAt: epoch);

      expect(initialQuery, isEmpty);
      expect(log.length, 2);
      expect(log.evictedCount, 1);
      final retained = log.query(scope: _defaultScope);
      expect(retained.map((entry) => entry.callId), <String>[
        'call-1',
        'call-2',
      ]);
      expect(retained.map((entry) => entry.sequence), <int>[1, 2]);
      expect(() => retained.add(retained.first), throwsUnsupportedError);
    });

    test('scoped queries fence account, agent, and runtime generation', () {
      final log = ActionAuditLog();
      _append(log, callId: 'call-1', occurredAt: epoch);
      final latest = _append(
        log,
        callId: 'call-2',
        actionId: 'device.move',
        occurredAt: epoch.add(const Duration(seconds: 1)),
      );
      _append(
        log,
        accountScope: 'prod|account-b',
        callId: 'call-other',
        occurredAt: epoch,
      );
      _append(
        log,
        agentId: 'agent-b',
        callId: 'call-other-agent',
        occurredAt: epoch,
      );
      _append(
        log,
        runtimeGeneration: 8,
        callId: 'call-stale',
        occurredAt: epoch,
      );

      const scope = _defaultScope;
      expect(log.query(scope: scope).map((entry) => entry.callId), <String>[
        'call-1',
        'call-2',
      ]);
      expect(
        log
            .query(
              scope: const ActionAuditScope(
                accountScope: 'prod|account-b',
                agentId: 'agent-a',
                runtimeGeneration: 7,
              ),
            )
            .map((entry) => entry.callId),
        <String>['call-other'],
      );
      expect(log.query(scope: scope, limit: 1), <ActionAuditEntry>[latest]);
      expect(
        log.query(
          scope: ActionAuditScope(
            accountScope: scope.accountScope,
            agentId: scope.agentId,
            runtimeGeneration: scope.runtimeGeneration,
            actionId: 'device.move',
            auditId: latest.auditId,
          ),
        ),
        <ActionAuditEntry>[latest],
      );
      expect(() => log.query(scope: scope).add(latest), throwsUnsupportedError);
    });
  });

  group('ActionAuditLog fail-closed validation', () {
    test('invalid fields and arguments never mutate the retained window', () {
      final log = ActionAuditLog(capacity: 1);
      final valid = _append(log, occurredAt: epoch);
      final cyclic = <Object?>[];
      cyclic.add(cyclic);

      final invalidAttempts = <void Function()>[
        () => _append(log, accountScope: ' ', occurredAt: epoch),
        () => _append(log, actionId: 'line\nbreak', occurredAt: epoch),
        () => _append(log, runtimeGeneration: -1, occurredAt: epoch),
        () => _append(log, code: 'sensitive display text', occurredAt: epoch),
        () => _append(log, occurredAt: DateTime.utc(1969)),
        () => _append(log, arguments: double.nan, occurredAt: epoch),
        () => _append(log, arguments: DateTime.utc(2026), occurredAt: epoch),
        () => _append(log, arguments: cyclic, occurredAt: epoch),
        () => _append(
          log,
          arguments: <Object?, Object?>{1: 'not-json'},
          occurredAt: epoch,
        ),
        () => _append(
          log,
          arguments: List<int>.filled(1025, 0),
          occurredAt: epoch,
        ),
      ];

      for (final attempt in invalidAttempts) {
        expect(attempt, throwsA(isA<ActionAuditValidationException>()));
        expect(log.query(scope: _defaultScope), <ActionAuditEntry>[valid]);
        expect(log.evictedCount, 0);
      }
    });

    test('validation exceptions never echo rejected sensitive values', () {
      const secret = 'secret display text that must not be logged';
      final log = ActionAuditLog();

      try {
        _append(log, code: secret, occurredAt: epoch);
        fail('invalid code must fail closed');
      } on ActionAuditValidationException catch (error) {
        expect(error.code, 'invalid_code');
        expect(error.toString(), isNot(contains(secret)));
      }
    });

    test('constructor and query bounds fail closed', () {
      expect(
        () => ActionAuditLog(capacity: 0),
        throwsA(isA<ActionAuditValidationException>()),
      );
      expect(
        () => ActionAuditLog(capacity: ActionAuditLog.maxCapacity + 1),
        throwsA(isA<ActionAuditValidationException>()),
      );

      final log = ActionAuditLog();
      _append(log, occurredAt: epoch);
      const scope = ActionAuditScope(
        accountScope: 'prod|account-a',
        agentId: 'agent-a',
        runtimeGeneration: 7,
      );
      expect(
        () => log.query(scope: scope, limit: 0),
        throwsA(isA<ActionAuditValidationException>()),
      );
      expect(
        () => log.query(
          scope: const ActionAuditScope(
            accountScope: 'prod|account-a',
            agentId: 'agent-a',
            runtimeGeneration: 7,
            auditId: 'not-an-audit-id',
          ),
        ),
        throwsA(isA<ActionAuditValidationException>()),
      );
      expect(log.length, 1);
    });

    test('timestamps are bounded and normalized to UTC', () {
      final localTime = DateTime(2026, 8, 27, 20);
      final entry = _append(ActionAuditLog(), occurredAt: localTime);

      expect(entry.occurredAt, localTime.toUtc());
      expect(entry.occurredAt.isUtc, isTrue);
      expect(
        () => _append(ActionAuditLog(), occurredAt: DateTime.utc(10000)),
        throwsA(isA<ActionAuditValidationException>()),
      );
    });
  });
}

const _defaultScope = ActionAuditScope(
  accountScope: 'prod|account-a',
  agentId: 'agent-a',
  runtimeGeneration: 7,
);

ActionAuditEntry _append(
  ActionAuditLog log, {
  ActionAuditStage stage = ActionAuditStage.asked,
  String accountScope = 'prod|account-a',
  String agentId = 'agent-a',
  int runtimeGeneration = 7,
  String callId = 'call-a',
  String actionId = 'app_control.execute',
  Object? arguments = const <String, Object?>{'message': 'hello'},
  String target = 'page:composer',
  ActionRisk risk = ActionRisk.externalWrite,
  ActionConsequencePolicy consequencePolicy =
      ActionConsequencePolicy.exactTextCommit,
  ActionAuditOutcome outcome = ActionAuditOutcome.proposed,
  String code = 'asked',
  required DateTime occurredAt,
}) => log.append(
  stage: stage,
  accountScope: accountScope,
  agentId: agentId,
  runtimeGeneration: runtimeGeneration,
  callId: callId,
  actionId: actionId,
  arguments: arguments,
  target: target,
  risk: risk,
  consequencePolicy: consequencePolicy,
  outcome: outcome,
  code: code,
  occurredAt: occurredAt,
);
