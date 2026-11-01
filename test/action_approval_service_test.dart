import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/action/action_approval_service.dart';

void main() {
  final epoch = DateTime.utc(2026, 8, 27, 12);

  group('ActionApprovalService', () {
    test('allows one exact request once and rejects replay', () {
      final service = ActionApprovalService();
      final request = _request(
        expiresAt: epoch.add(const Duration(minutes: 1)),
      );

      final pending = service.requestConfirmation(request: request, now: epoch);
      expect(pending.outcome, ActionApprovalOutcome.confirmationRequired);
      expect(pending.fingerprint, hasLength(64));

      final allowed = service.resolve(
        fingerprint: pending.fingerprint!,
        request: request,
        decision: ActionApprovalDecision.allowOnce,
        now: epoch.add(const Duration(seconds: 1)),
      );
      expect(allowed.outcome, ActionApprovalOutcome.allowedOnce);
      expect(allowed.isAllowedOnce, isTrue);

      final replay = service.resolve(
        fingerprint: pending.fingerprint!,
        request: request,
        decision: ActionApprovalDecision.allowOnce,
        now: epoch.add(const Duration(seconds: 2)),
      );
      expect(replay.outcome, ActionApprovalOutcome.unavailable);
      expect(replay.fingerprint, isNull);

      final reissued = service.requestConfirmation(
        request: request,
        now: epoch.add(const Duration(seconds: 3)),
      );
      expect(reissued.outcome, ActionApprovalOutcome.unavailable);
    });

    test('expiry fails closed at the exact TTL boundary', () {
      final service = ActionApprovalService();
      final expiresAt = epoch.add(const Duration(seconds: 30));
      final request = _request(expiresAt: expiresAt);
      final pending = service.requestConfirmation(request: request, now: epoch);

      final expired = service.resolve(
        fingerprint: pending.fingerprint!,
        request: request,
        decision: ActionApprovalDecision.allowOnce,
        now: expiresAt,
      );

      expect(expired.outcome, ActionApprovalOutcome.unavailable);
      expect(expired.isAllowedOnce, isFalse);
    });

    test('rejection and cancellation are terminal exact outcomes', () {
      for (final scenario
          in <(ActionApprovalDecision, ActionApprovalOutcome, String)>[
            (
              ActionApprovalDecision.reject,
              ActionApprovalOutcome.rejected,
              'reject-call',
            ),
            (
              ActionApprovalDecision.cancel,
              ActionApprovalOutcome.cancelled,
              'cancel-call',
            ),
          ]) {
        final service = ActionApprovalService();
        final request = _request(
          callId: scenario.$3,
          expiresAt: epoch.add(const Duration(minutes: 1)),
        );
        final pending = service.requestConfirmation(
          request: request,
          now: epoch,
        );

        final result = service.resolve(
          fingerprint: pending.fingerprint!,
          request: request,
          decision: scenario.$1,
          now: epoch.add(const Duration(seconds: 1)),
        );
        expect(result.outcome, scenario.$2);

        final replay = service.resolve(
          fingerprint: pending.fingerprint!,
          request: request,
          decision: scenario.$1,
          now: epoch.add(const Duration(seconds: 2)),
        );
        expect(replay.outcome, ActionApprovalOutcome.unavailable);
      }
    });

    test('every identity and payload mismatch consumes the authority', () {
      final scenarios = <String, ActionApprovalRequest Function(DateTime)>{
        'account': (expiresAt) =>
            _request(accountScope: 'prod|account-b', expiresAt: expiresAt),
        'agent': (expiresAt) =>
            _request(agentId: 'agent-b', expiresAt: expiresAt),
        'generation': (expiresAt) =>
            _request(runtimeGeneration: 8, expiresAt: expiresAt),
        'call': (expiresAt) => _request(callId: 'call-b', expiresAt: expiresAt),
        'action': (expiresAt) =>
            _request(actionId: 'device.move', expiresAt: expiresAt),
        'arguments': (expiresAt) => _request(
          arguments: <String, Object?>{'message': 'changed'},
          expiresAt: expiresAt,
        ),
        'target': (expiresAt) =>
            _request(target: 'device:other', expiresAt: expiresAt),
      };

      for (final entry in scenarios.entries) {
        final service = ActionApprovalService();
        final expiresAt = epoch.add(const Duration(minutes: 1));
        final exact = _request(expiresAt: expiresAt);
        final pending = service.requestConfirmation(request: exact, now: epoch);

        final mismatch = service.resolve(
          fingerprint: pending.fingerprint!,
          request: entry.value(expiresAt),
          decision: ActionApprovalDecision.allowOnce,
          now: epoch.add(const Duration(seconds: 1)),
        );
        expect(
          mismatch.outcome,
          ActionApprovalOutcome.unavailable,
          reason: '${entry.key} mismatch must fail closed',
        );

        final exactReplay = service.resolve(
          fingerprint: pending.fingerprint!,
          request: exact,
          decision: ActionApprovalDecision.allowOnce,
          now: epoch.add(const Duration(seconds: 2)),
        );
        expect(
          exactReplay.outcome,
          ActionApprovalOutcome.unavailable,
          reason: '${entry.key} mismatch must consume the authority',
        );
      }
    });

    test('canonical JSON ignores recursive object key order', () {
      final service = ActionApprovalService();
      final expiresAt = epoch.add(const Duration(minutes: 1));
      final original = _request(
        arguments: <String, Object?>{
          'z': <Object?>[
            <String, Object?>{'b': 2, 'a': 1},
          ],
          'a': <String, Object?>{'d': true, 'c': null},
        },
        expiresAt: expiresAt,
      );
      final reordered = _request(
        arguments: <String, Object?>{
          'a': <String, Object?>{'c': null, 'd': true},
          'z': <Object?>[
            <String, Object?>{'a': 1, 'b': 2},
          ],
        },
        expiresAt: expiresAt,
      );

      final pending = service.requestConfirmation(
        request: original,
        now: epoch,
      );
      final allowed = service.resolve(
        fingerprint: pending.fingerprint!,
        request: reordered,
        decision: ActionApprovalDecision.allowOnce,
        now: epoch.add(const Duration(seconds: 1)),
      );

      expect(allowed.outcome, ActionApprovalOutcome.allowedOnce);
    });

    test('non-finite and unsupported argument values are unavailable', () {
      final invalidArguments = <Object?>[
        double.nan,
        double.infinity,
        DateTime.utc(2026),
        <String>{'not-json'},
        <Object?, Object?>{1: 'non-string-key'},
      ];

      for (final arguments in invalidArguments) {
        final service = ActionApprovalService();
        final result = service.requestConfirmation(
          request: _request(
            arguments: arguments,
            expiresAt: epoch.add(const Duration(minutes: 1)),
          ),
          now: epoch,
        );
        expect(result.outcome, ActionApprovalOutcome.unavailable);
        expect(result.fingerprint, isNull);
      }
    });

    test(
      'cyclic arguments and an unavailable confirmation host fail closed',
      () {
        final cyclic = <Object?>[];
        cyclic.add(cyclic);
        final service = ActionApprovalService();

        final cyclicResult = service.requestConfirmation(
          request: _request(
            arguments: cyclic,
            expiresAt: epoch.add(const Duration(minutes: 1)),
          ),
          now: epoch,
        );
        expect(cyclicResult.outcome, ActionApprovalOutcome.unavailable);

        final unavailable = service.requestConfirmation(
          request: _request(expiresAt: epoch.add(const Duration(minutes: 1))),
          now: epoch,
          confirmationAvailable: false,
        );
        expect(unavailable.outcome, ActionApprovalOutcome.unavailable);
      },
    );

    test('argument depth, node, and string limits fail closed', () {
      Object? deeplyNested = 'leaf';
      for (var index = 0; index < 6; index++) {
        deeplyNested = <Object?>[deeplyNested];
      }
      final expiresAt = epoch.add(const Duration(minutes: 1));
      final cases = <(ActionApprovalService, Object?)>[
        (ActionApprovalService(maxArgumentDepth: 3), deeplyNested),
        (ActionApprovalService(maxArgumentNodes: 3), <Object?>[1, 2, 3, 4]),
        (ActionApprovalService(maxArgumentStringRunes: 3), 'four'),
      ];

      for (final (service, arguments) in cases) {
        final result = service.requestConfirmation(
          request: _request(arguments: arguments, expiresAt: expiresAt),
          now: epoch,
        );
        expect(result.outcome, ActionApprovalOutcome.unavailable);
        expect(result.fingerprint, isNull);
      }
    });
  });
}

ActionApprovalRequest _request({
  String accountScope = 'prod|account-a',
  String agentId = 'agent-a',
  int runtimeGeneration = 7,
  String callId = 'call-a',
  String actionId = 'app_control.execute',
  Object? arguments = const <String, Object?>{'message': 'hello'},
  String target = 'page:composer',
  required DateTime expiresAt,
}) => ActionApprovalRequest(
  accountScope: accountScope,
  agentId: agentId,
  runtimeGeneration: runtimeGeneration,
  callId: callId,
  actionId: actionId,
  arguments: arguments,
  target: target,
  expiresAt: expiresAt,
);
