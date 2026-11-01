import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/content_engagement/application/content_consumption_controller.dart';
import 'package:maaso/src/features/content_engagement/domain/content_engagement.dart';

import 'content_engagement_test.dart' show ContentTestGateway;

class _ExpiringGateway extends ContentTestGateway {
  bool rejectPulse = true;
  bool rejectFinish = false;
  bool failFinishOnce = false;
  final finishSequences = <int>[];
  final startKeys = <String>[];

  @override
  Future<ContentConsumptionSession> start(
    ContentConsumptionTarget target,
    String requestId,
  ) {
    startKeys.add(requestId);
    return super.start(target, requestId);
  }

  @override
  Future<ContentConsumptionSession> pulse(
    String sessionId,
    int sequence,
    String event,
    int progress,
  ) async {
    if (rejectPulse) {
      pulses.add((sequence: sequence, event: event, progress: progress));
      throw const ContentEngagementException('CONTENT_SESSION_CONFLICT');
    }
    return super.pulse(sessionId, sequence, event, progress);
  }

  @override
  Future<ContentConsumptionSession> finish(
    String sessionId,
    int sequence,
  ) async {
    finishSequences.add(sequence);
    if (rejectFinish) {
      throw const ContentEngagementException('CONTENT_SESSION_CONFLICT');
    }
    if (failFinishOnce) {
      failFinishOnce = false;
      throw Exception('ambiguous network failure');
    }
    return super.finish(sessionId, sequence);
  }
}

ContentConsumptionController _controller(_ExpiringGateway gateway) =>
    ContentConsumptionController(
      gateway: gateway,
      target: const ContentConsumptionTarget(
        ContentConsumptionKind.game,
        'game',
      ),
      automaticTicks: false,
    );

void main() {
  test(
    'expired pulse closes confirmed sequence and starts a new request',
    () async {
      final gateway = _ExpiringGateway()..rejectPulse = false;
      final controller = _controller(gateway);
      await controller.setVisible(true);
      controller.recordProgress(4000);
      await controller.tick();
      gateway.rejectPulse = true;
      controller.recordProgress(9000);
      await controller.tick();
      expect(gateway.finishSequences, [2]);
      expect(gateway.finishes, 1);
      expect(controller.session, isNull);
      await controller.tick();
      expect(gateway.starts, 2);
      expect(gateway.startKeys.toSet(), hasLength(2));
      gateway.rejectPulse = false;
      await controller.tick();
      expect(gateway.pulses.last.event, 'heartbeat');
      expect(gateway.pulses.last.progress, 0);
      await controller.close();
    },
  );

  test(
    'superseded finish clears the stale lease without replaying it',
    () async {
      final gateway = _ExpiringGateway()..rejectFinish = true;
      final controller = _controller(gateway);
      await controller.setVisible(true);
      await controller.tick();
      expect(controller.session, isNull);
      expect(gateway.finishSequences, [1]);
      await controller.tick();
      expect(gateway.starts, 2);
      expect(gateway.pulses, hasLength(1));
      await controller.close();
    },
  );

  test(
    'ambiguous finish failure retains the exact close sequence for retry',
    () async {
      final gateway = _ExpiringGateway()..failFinishOnce = true;
      final controller = _controller(gateway);
      await controller.setVisible(true);
      await controller.tick();
      expect(controller.session, isNotNull);
      expect(gateway.finishSequences, [1]);
      await controller.setVisible(false);
      expect(gateway.finishSequences, [1, 1]);
      expect(controller.session, isNull);
      expect(gateway.pulses, hasLength(1));
      await controller.close();
    },
  );

  test(
    'retirement before conflict recovery never closes another account',
    () async {
      final gateway = _ExpiringGateway();
      final controller = _controller(gateway);
      await controller.setVisible(true);
      gateway.contextKey = 'environment|other';
      await controller.tick();
      await controller.close();
      expect(gateway.finishSequences, isEmpty);
      expect(gateway.pulses, isEmpty);
    },
  );
}
