@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/account_runtime_instance_lease.dart';

void main() {
  test('Web Lock is held for the complete lease lifetime', () async {
    final firstGate = createDefaultAccountRuntimeInstanceLeaseGate();
    final secondGate = createDefaultAccountRuntimeInstanceLeaseGate();
    final first = await firstGate.acquire();
    addTearDown(first.release);

    await expectLater(
      secondGate.acquire(),
      throwsA(isA<AccountRuntimeInstanceUnavailable>()),
    );

    await first.release();
    final second = await secondGate.acquire();
    await second.release();
  });
}
