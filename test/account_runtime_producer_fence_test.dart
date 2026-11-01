import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/account_runtime_producer_fence.dart';

void main() {
  test(
    'starts synchronously and deduplicates watchdog and teardown drain',
    () async {
      final controller = AccountRuntimeProducerFenceController();
      final gate = Completer<void>();
      var starts = 0;
      final handle = controller.install(() {
        starts++;
        return gate.future;
      });

      final watchdogDrain = controller.fenceAndDrain();
      final teardownDrain = handle.fenceAndDrain();

      expect(starts, 1);
      expect(identical(watchdogDrain, teardownDrain), isTrue);
      gate.complete();
      await teardownDrain;
      await handle.complete();
      expect(starts, 1);
      expect(controller.hasActiveMount, isFalse);
    },
  );

  test(
    'failed drain is retained for a retry without overlapping starts',
    () async {
      final controller = AccountRuntimeProducerFenceController();
      var starts = 0;
      final handle = controller.install(() async {
        starts++;
        if (starts == 1) throw StateError('drain failed');
      });

      await expectLater(controller.fenceAndDrain(), throwsStateError);
      expect(controller.hasActiveMount, isTrue);

      await handle.complete();
      expect(starts, 2);
      expect(controller.hasActiveMount, isFalse);
    },
  );
}
