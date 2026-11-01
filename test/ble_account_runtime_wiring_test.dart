import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'BLE activates before account services and drains behind runtime fence',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      final mountStart = source.indexOf(
        'Future<AccountRuntimeLease> _mountAccountRuntime',
      );
      final disposeStart = source.indexOf(
        'Future<void> _disposeAccountRuntime',
        mountStart,
      );
      final mountBody = source.substring(mountStart, disposeStart);
      final producerDrainStart = source.indexOf(
        'Future<void> _drainAccountRuntimeProducers',
        disposeStart,
      );
      final producerDrainEnd = source.indexOf(
        'void _registerDefaultVadServices',
        producerDrainStart,
      );
      final disposeBody = source.substring(disposeStart, producerDrainStart);
      final producerDrainBody = source.substring(
        producerDrainStart,
        producerDrainEnd,
      );

      final bleActivation = mountBody.indexOf(
        'find<YoturetoysDevice>().activateAccount(',
      );
      final llmActivation = mountBody.indexOf(
        'find<LLMConfigController>().activateAccount(mount)',
      );
      final notificationPreparation = mountBody.indexOf('prepareAccountScope(');
      final databaseOpen = mountBody.indexOf(
        'DBService().init(scope: accountScope)',
      );

      expect(bleActivation, greaterThanOrEqualTo(0));
      expect(bleActivation, lessThan(llmActivation));
      expect(bleActivation, lessThan(notificationPreparation));
      expect(bleActivation, lessThan(databaseOpen));
      expect(
        mountBody,
        contains('accountScopeKey: accountScope.storageNamespace'),
      );

      final runtimeFence = producerDrainBody.indexOf("'agent_runtime'");
      final bleDrain = producerDrainBody.indexOf("'bluetooth'");
      final drainWait = producerDrainBody.lastIndexOf(
        'await Future.wait<void>(<Future<void>>[',
      );
      final deleteServices = disposeBody.indexOf('for (final type');
      expect(runtimeFence, greaterThanOrEqualTo(0));
      expect(bleDrain, greaterThanOrEqualTo(0));
      expect(runtimeFence, lessThan(drainWait));
      expect(bleDrain, lessThan(drainWait));
      expect(deleteServices, greaterThanOrEqualTo(0));
      final fullDrain = disposeBody.indexOf(
        'await _drainAccountRuntimeProducers()',
      );
      expect(fullDrain, greaterThanOrEqualTo(0));
      expect(fullDrain, lessThan(deleteServices));
      expect(
        producerDrainBody,
        contains('projector.deactivateAccountAndDrain()'),
      );
      expect(producerDrainBody, contains('bluetoothDrain,'));
      expect(
        producerDrainBody.indexOf('if (barrier.errors.isNotEmpty)'),
        greaterThan(drainWait),
      );
    },
  );

  test('BLE skill and applet prework stays inside facade account operation', () {
    final bluetoothSkill = File(
      'lib/src/features/agent/application/skills/bluetooth_skill.dart',
    ).readAsStringSync();
    final projectorSkill = File(
      'lib/src/features/agent/application/skills/ble_yoturetoys_skill.dart',
    ).readAsStringSync();
    final projectorApplet = File(
      'lib/src/features/applets/presentation/ble_projector/ble_projector_applet.dart',
    ).readAsStringSync();

    expect(
      bluetoothSkill,
      contains('return _projector.runAccountOperation(() async {'),
    );
    expect(
      projectorSkill,
      contains('_device.runAccountOperation(() => _transferImageActive(args))'),
    );
    expect(
      projectorSkill,
      contains('_device.runAccountOperation(_sendGalleryActive)'),
    );
    expect(
      projectorApplet,
      contains('await _device.runAccountOperation(() async {'),
    );
  });
}
