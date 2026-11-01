import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Scheduled quarantine gates account graph construction', () {
    final source = File('lib/main.dart').readAsStringSync();
    final mountStart = source.indexOf(
      'Future<AccountRuntimeLease> _mountAccountRuntime',
    );
    final prepare = source.indexOf(
      'find<ScheduledTaskService>().prepareAccountScope',
      mountStart,
    );
    final companionActivation = source.indexOf(
      'find<CompanionVoiceSessionBoundary>().activateAccount',
      mountStart,
    );
    final databaseMount = source.indexOf('DBService().init', mountStart);

    expect(mountStart, greaterThanOrEqualTo(0));
    expect(prepare, greaterThan(mountStart));
    expect(companionActivation, greaterThan(prepare));
    expect(databaseMount, greaterThan(prepare));
  });
}
