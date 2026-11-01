import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_boot_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (call) async => null,
        );
  });

  test('concurrent boot shutdown callers share the strict stop', () async {
    final stopStarted = Completer<void>();
    final releaseStop = Completer<void>();
    var stopCalls = 0;
    final controller = AgentBootController(
      fallbackStop: () async {
        stopCalls += 1;
        if (!stopStarted.isCompleted) stopStarted.complete();
        await releaseStop.future;
      },
    );
    addTearDown(controller.onClose);

    final first = controller.deactivateAndDrain();
    final second = controller.deactivateAndDrain();
    expect(identical(first, second), isTrue);
    await stopStarted.future;
    expect(stopCalls, 1);

    releaseStop.complete();
    await Future.wait<void>(<Future<void>>[first, second]);
    expect(stopCalls, 1);
  });

  test('failed boot TTS stop is propagated and retryable', () async {
    final firstError = StateError('system_tts_stop_failed');
    var stopCalls = 0;
    final controller = AgentBootController(
      fallbackStop: () async {
        stopCalls += 1;
        if (stopCalls == 1) throw firstError;
      },
    );
    addTearDown(controller.onClose);

    await expectLater(
      controller.deactivateAndDrain(),
      throwsA(same(firstError)),
    );
    await controller.deactivateAndDrain();
    expect(stopCalls, 2);
  });
}
