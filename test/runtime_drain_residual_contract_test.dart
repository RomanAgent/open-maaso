import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Home secondary work remains inside account operations', () {
    final source = File(
      'lib/src/features/home/application/home_controller.dart',
    ).readAsStringSync();

    expect(
      source,
      contains(
        'Future<void> loadDock() => '
        '_registry.runAccountOperation(_loadDockActive)',
      ),
    );
    expect(source, isNot(contains('_checkForNewWidget')));
    expect(
      source,
      contains(
        'await appServices.find<SkillTrainingObserver>().observeConversation',
      ),
    );
    expect(
      RegExp(r'await _loadDockActive\(\);').allMatches(source).length,
      greaterThanOrEqualTo(3),
    );
    expect(source, contains('await _loadDockActive();'));
  });

  test('all voice producers and strict TTS stop start before the drain wait', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final runtimeSource = File(
      'lib/src/features/agent/application/agent_runtime.dart',
    ).readAsStringSync();
    final bootSource = File(
      'lib/src/features/agent/application/controllers/agent_boot_controller.dart',
    ).readAsStringSync();

    expect(runtimeSource, contains('if (_retiring || _disposed)'));
    expect(bootSource, contains('void _speakNeural(String text)'));
    expect(bootSource, contains('if (_retiring) return;'));
    expect(bootSource, contains('Future<void> _speakSystem(String text)'));
    expect(bootSource, contains('_inFlightSystemSpeech.add(tracked)'));
    expect(bootSource, contains('Future<void> deactivateAndDrain()'));

    final accountDrain = mainSource.substring(
      mainSource.indexOf('Future<void> _drainAccountRuntimeProducers'),
      mainSource.indexOf('void _registerDefaultVadServices'),
    );
    final runtimeDrain = accountDrain.indexOf("'agent_runtime'");
    final firstDrainWait = accountDrain.lastIndexOf(
      'await Future.wait<void>(<Future<void>>[',
    );
    final strictStop = accountDrain.indexOf('MaasoTtsPlugin.stopAllStrict');
    expect(runtimeDrain, greaterThanOrEqualTo(0));
    expect(firstDrainWait, greaterThan(runtimeDrain));
    expect(strictStop, greaterThan(runtimeDrain));
    expect(strictStop, lessThan(firstDrainWait));
    expect(mainSource, contains("'agent_pipeline'"));
    expect(mainSource, contains("'agent_boot'"));
    expect(mainSource, contains("'emotion_camera'"));
  });

  test('post-frame account boot is admitted through the registry barrier', () {
    final source = File('lib/main.dart').readAsStringSync();
    final scheduleStart = source.indexOf(
      'void _scheduleAccountPostFrameBootTasks',
    );
    final runStart = source.indexOf(
      'Future<void> _runAccountPostFrameBootTasks',
      scheduleStart,
    );
    final scheduleBody = source.substring(scheduleStart, runStart);

    expect(scheduleBody, contains('runtimeRegistry.runAccountOperation'));
    expect(
      scheduleBody,
      matches(
        RegExp(
          r'_runAccountPostFrameBootTasks\(\s*mount,\s*ownerIsCurrent: ownerIsCurrent,?\s*\)',
        ),
      ),
    );
    expect(scheduleBody, contains('isAccountCurrent: ownerIsCurrent'));
  });
}
