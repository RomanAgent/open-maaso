import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/account_runtime_instance_lease.dart';

void main() {
  test('in-process gate allows only one mounted account runtime', () async {
    final firstGate = InProcessAccountRuntimeInstanceLeaseGate();
    final secondGate = InProcessAccountRuntimeInstanceLeaseGate();
    final first = await firstGate.acquire();
    try {
      await expectLater(
        secondGate.acquire(),
        throwsA(isA<AccountRuntimeInstanceUnavailable>()),
      );
    } finally {
      await first.release();
    }

    final second = await secondGate.acquire();
    await second.release();
  });

  test(
    'lease remains held until the application explicitly releases it',
    () async {
      final firstGate = InProcessAccountRuntimeInstanceLeaseGate();
      final secondGate = InProcessAccountRuntimeInstanceLeaseGate();
      final instanceLease = await firstGate.acquire();

      await expectLater(
        secondGate.acquire(),
        throwsA(isA<AccountRuntimeInstanceUnavailable>()),
      );

      await instanceLease.release();
      final replacement = await secondGate.acquire();
      await replacement.release();
    },
  );
}
