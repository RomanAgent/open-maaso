import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('account mount wires approval dependencies before agent runtime', () {
    final source = File('lib/main.dart').readAsStringSync();
    final mountStart = source.indexOf(
      'Future<AccountRuntimeLease> _mountAccountRuntime',
    );
    final mountEnd = source.indexOf(
      'final class _MountedAccountRuntime',
      mountStart,
    );

    expect(mountStart, greaterThanOrEqualTo(0));
    expect(mountEnd, greaterThan(mountStart));

    final mountBody = source.substring(mountStart, mountEnd);
    final runtimeRegistry = mountBody.indexOf(
      'final runtimeRegistry = putOwned(',
    );

    expect(runtimeRegistry, greaterThanOrEqualTo(0));

    const registrationAnchors = <String, String>{
      'approval service': 'putOwned(ActionApprovalService());',
      'lazy audit log': 'lazyOwned<ActionAuditLog>(ActionAuditLog.new);',
      'approval Host interface': 'putOwned<ActionApprovalHost>(',
      'command executor interface': 'putOwned<AppControlHostCommandExecutor>(',
    };

    for (final entry in registrationAnchors.entries) {
      final registration = mountBody.indexOf(entry.value);
      expect(
        registration,
        greaterThanOrEqualTo(0),
        reason: '${entry.key} must be owned by _mountAccountRuntime',
      );
      expect(
        registration,
        lessThan(runtimeRegistry),
        reason: '${entry.key} must be registered before AgentRuntimeRegistry',
      );
      expect(
        source.indexOf(entry.value),
        mountStart + registration,
        reason: '${entry.key} must not be registered outside the account mount',
      );
      expect(
        source.lastIndexOf(entry.value),
        mountStart + registration,
        reason: '${entry.key} must have exactly one production registration',
      );
    }

    expect(
      mountBody,
      contains('putOwned<ActionApprovalHost>(MaterialActionApprovalHost());'),
    );

    final executorRegistration = mountBody.indexOf(
      'putOwned<AppControlHostCommandExecutor>(',
    );
    final executorRegistrationEnd = mountBody.indexOf(
      ');',
      executorRegistration,
    );
    expect(executorRegistrationEnd, greaterThan(executorRegistration));
    expect(executorRegistrationEnd, lessThan(runtimeRegistry));
    final executorRegistrationBody = mountBody.substring(
      executorRegistration,
      executorRegistrationEnd,
    );

    expect(mountBody, isNot(contains('AgentCommunityPostHostCommandExecutor')));
    expect(
      mountBody,
      contains(
        'final memoryLedgerHostCommandExecutor = putOwned(\n'
        '      MemoryLedgerHostCommandExecutor(),\n'
        '    );',
      ),
    );
    expect(
      executorRegistrationBody,
      allOf(
        contains('AppControlHostCommandRouter'),
        isNot(contains('communityPostHostCommandExecutor,')),
        contains('memoryLedgerHostCommandExecutor,'),
      ),
    );
  });

  test('account drain starts and awaits approval Host after runtime fence', () {
    final source = File('lib/main.dart').readAsStringSync();
    final drainStart = source.indexOf(
      'Future<void> _drainAccountRuntimeProducers',
    );
    final drainEnd = source.indexOf(
      'void _registerDefaultVadServices',
      drainStart,
    );

    expect(drainStart, greaterThanOrEqualTo(0));
    expect(drainEnd, greaterThan(drainStart));

    final drainBody = source.substring(drainStart, drainEnd);
    final runtimeDrain = drainBody.indexOf('final runtimeDrain = barrier.run(');
    final approvalHostDrain = drainBody.indexOf(
      'final approvalHostDrain = barrier.run(',
    );

    expect(runtimeDrain, greaterThanOrEqualTo(0));
    expect(approvalHostDrain, greaterThan(runtimeDrain));

    final nextDrain = drainBody.indexOf(
      'final bluetoothDrain = barrier.run(',
      approvalHostDrain,
    );
    expect(nextDrain, greaterThan(approvalHostDrain));
    expect(
      drainBody.substring(approvalHostDrain, nextDrain),
      contains('appServices.maybeFind<ActionApprovalHost>()'),
    );

    final waitStart = drainBody.lastIndexOf(
      'await Future.wait<void>(<Future<void>>[',
    );
    final waitEnd = drainBody.indexOf('], eagerError: false);', waitStart);

    expect(waitStart, greaterThan(approvalHostDrain));
    expect(waitEnd, greaterThan(waitStart));

    final waitBody = drainBody.substring(waitStart, waitEnd);
    expect(waitBody, contains('runtimeDrain,'));
    expect(waitBody, contains('approvalHostDrain,'));
    expect(
      waitBody.indexOf('approvalHostDrain,'),
      greaterThan(waitBody.indexOf('runtimeDrain,')),
    );
  });
}
