import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'issued performance permit separates dispatch timeout from actual body lease',
    () async {
      final now = DateTime.utc(2026, 10, 16, 4);
      final sink = _PermitSink();
      final arbiter = await _bound(sink, () => now);
      addTearDown(arbiter.onClose);
      final command = AvatarBodyGestureCommand(
        'speech',
        energy: 'gentle',
        intensity: .4,
        emotion: 'calm',
      );
      final semanticJson = jsonEncode(command.toCanonicalJson());
      final receipt = await arbiter.acquire(_request(command));
      expect(receipt.disposition, AvatarCommandReceiptDisposition.dispatched);
      final operation = sink.operations.single;
      final permit = sink.permits.single;
      expect(operation.validUntil, now.add(const Duration(milliseconds: 3500)));
      expect(
        permit.deadlineEpochMs,
        now.add(const Duration(milliseconds: 500)).millisecondsSinceEpoch,
      );
      final rendererPayload =
          jsonDecode(permit.payloadJson) as Map<String, dynamic>;
      expect(rendererPayload, {
        ...command.toCanonicalJson(),
        'leaseExpiresAtEpochMs': now
            .add(const Duration(milliseconds: 3500))
            .millisecondsSinceEpoch,
      });
      expect(rendererPayload, hasLength(6));
      expect(command.toCanonicalJson(), hasLength(5));
      expect(jsonEncode(command.toCanonicalJson()), semanticJson);
      expect(
        permit.payloadSha256,
        sha256.convert(utf8.encode(permit.payloadJson)).toString(),
      );
      expect(permit.desiredFingerprint, receipt.fingerprint);
      expect(operation.desiredFingerprint, receipt.fingerprint);
    },
  );

  test(
    'preempted performance restoration cannot extend the original lease',
    () async {
      final start = DateTime.utc(2026, 10, 16, 4);
      var now = start;
      final sink = _PermitSink();
      final arbiter = await _bound(sink, () => now);
      addTearDown(arbiter.onClose);
      final command = AvatarBodyGestureCommand(
        'listen',
        energy: 'gentle',
        intensity: .3,
        emotion: 'comforting',
      );
      final first = await arbiter.acquire(
        _request(command, source: AvatarCommandSource.idle),
      );
      now = start.add(const Duration(milliseconds: 100));
      await arbiter.acquire(
        _request(
          AvatarBodyGestureCommand('wave'),
          source: AvatarCommandSource.explicitUser,
          ttl: const Duration(milliseconds: 600),
        ),
      );
      now = start.add(const Duration(milliseconds: 1000));
      await arbiter.expireLeases();
      final styled = sink.permits
          .where(
            (p) => (jsonDecode(p.payloadJson) as Map).containsKey('energy'),
          )
          .toList();
      expect(styled, hasLength(2));
      for (final permit in styled) {
        final payload = jsonDecode(permit.payloadJson) as Map;
        expect(
          payload['leaseExpiresAtEpochMs'],
          start.add(const Duration(milliseconds: 3500)).millisecondsSinceEpoch,
        );
        expect(permit.desiredFingerprint, first.fingerprint);
      }
      expect(
        styled.first.payloadSha256,
        styled.last.payloadSha256,
        reason: 'restoration retains the same absolute, digest-bound expiry',
      );
      now = start.add(const Duration(milliseconds: 3501));
      await arbiter.expireLeases();
      expect(sink.permits.last.clearsChannel, isTrue);
      expect(jsonDecode(sink.permits.last.payloadJson), {
        'channel': 'bodyGesture',
        'clear': true,
      });
    },
  );

  test(
    'legacy body and work permits retain their exact canonical payload bytes',
    () async {
      final now = DateTime.utc(2026, 10, 16, 4);
      final sink = _PermitSink();
      final arbiter = await _bound(sink, () => now);
      addTearDown(arbiter.onClose);
      final commands = <AvatarBodyGestureCommand>[
        AvatarBodyGestureCommand('wave'),
        AvatarBodyGestureCommand(
          'work_desk',
          workSessionId: 'a' * 64,
          workPhase: AvatarBackgroundTaskWorkPhase.start,
        ),
      ];
      for (final (index, command) in commands.indexed) {
        await arbiter.acquire(_request(command, generation: index + 1));
        expect(
          sink.permits.last.payloadJson,
          jsonEncode(command.toCanonicalJson()),
        );
        expect(
          jsonDecode(sink.permits.last.payloadJson),
          isNot(contains('leaseExpiresAtEpochMs')),
        );
      }
    },
  );

  test(
    'nonpositive performance lease expiry fails before issuing any renderer permit',
    () async {
      final now = DateTime.fromMillisecondsSinceEpoch(-10000, isUtc: true);
      final sink = _PermitSink();
      final arbiter = await _bound(sink, () => now);
      addTearDown(arbiter.onClose);
      final command = AvatarBodyGestureCommand(
        'speech',
        energy: 'gentle',
        intensity: .4,
        emotion: 'calm',
      );
      await expectLater(
        arbiter.acquire(_request(command)),
        throwsArgumentError,
      );
      expect(sink.operations, isEmpty);
      expect(sink.permits, isEmpty);
    },
  );
}

Future<AvatarCommandArbiter> _bound(
  _PermitSink sink,
  AvatarCommandClock clock,
) async {
  final arbiter = AvatarCommandArbiter(
    accountGeneration: 9,
    dispatchSink: sink,
    clock: clock,
    dispatchTimeout: const Duration(milliseconds: 500),
  );
  await arbiter.bindRenderer(
    accountGeneration: 9,
    rendererGeneration: 4,
    ready: true,
    capabilities: AvatarCommandCapabilities(
      supportedChannels: AvatarCommandChannel.values.toSet(),
      supportedBodyGestures: {'speech', 'listen', 'wave', 'work_desk'},
    ),
  );
  return arbiter;
}

AvatarCommandLeaseRequest _request(
  AvatarBodyGestureCommand command, {
  int generation = 1,
  AvatarCommandSource source = AvatarCommandSource.explicitAgent,
  Duration ttl = const Duration(milliseconds: 3500),
}) => AvatarCommandLeaseRequest(
  accountGeneration: 9,
  rendererGeneration: 4,
  commandGeneration: generation,
  leaseId: 'body-${source.name}-$generation',
  source: source,
  command: command,
  ttl: ttl,
);

final class _PermitSink implements AvatarCommandDispatchSink {
  final operations = <AvatarCommandDispatchOperation>[];
  final permits = <AvatarRendererMutationPermit>[];
  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) async {
    operations.add(operation);
    final permit = operation.issueRendererMutationPermit();
    if (permit == null) throw StateError('stale_performance_permit');
    permits.add(permit);
    final receipt = operation.acceptRendererReceipt(permit);
    if (receipt == null) throw StateError('missing_performance_ack');
    return receipt;
  }

  @override
  Future<AvatarRendererResetReceipt> resetOrDispose(
    AvatarRendererResetOperation operation,
  ) async {
    final receipt = operation.resetOrDisposeIfCurrent(() {});
    if (receipt == null) throw StateError('stale_performance_reset');
    return receipt;
  }
}
