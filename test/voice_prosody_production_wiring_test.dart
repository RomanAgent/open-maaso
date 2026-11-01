import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('account runtime owns consent and lazy prosody analyzer lifecycle', () {
    final source = File('lib/main.dart').readAsStringSync();
    final database = source.indexOf('final mountedDatabase =');
    final flags = source.indexOf('final featureFlags =');
    final preference = source.indexOf('final voiceProsodyPreference =');
    final service = source.indexOf('VoiceProsodyService(');

    expect(database, greaterThanOrEqualTo(0));
    expect(flags, greaterThan(database));
    expect(preference, greaterThan(flags));
    expect(service, greaterThan(preference));
    expect(
      source,
      contains('explicitOptIn: () => voiceProsodyPreference.effectiveEnabled'),
    );
    expect(
      source,
      contains('analyzerFactory: () async => LocalDspVoiceProsodyAnalyzer()'),
    );
    expect(source, contains("'voice_prosody'"));
    expect(source, contains('VoiceProsodyService>()?.retireAndDrain()'));
    expect(
      source,
      contains(
        'VoiceProsodyPreferenceService>()\n        ?.deactivateAndDrain()',
      ),
    );
  });

  test('both VAD segment surfaces pass the optional account service', () {
    for (final path in <String>[
      'lib/src/core/widgets/chat_input_bar.dart',
      'lib/src/features/chat/presentation/widgets/chat_input_bar.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('appServices.maybeFind<VoiceProsodyService>()'));
      expect(source, contains('final voiceProsody = _voiceProsody;'));
      expect(source, contains('voiceProsody: voiceProsody'));
      expect(source, contains('!identical(_voiceProsody, voiceProsody)'));
      expect(source, contains('_claimProsodyForNextTurn()'));
      expect(source, contains('_discardProsodyUtterance()'));
    }
  });

  test('turn metadata is consumed locally and never added to cloud prompt', () {
    final home = File(
      'lib/src/features/home/application/home_controller.dart',
    ).readAsStringSync();
    final runtime = File(
      'lib/src/features/agent/application/agent_runtime.dart',
    ).readAsStringSync();

    expect(home, contains('consumeClaimedForNextTurn()'));
    expect(home, contains("'voice.prosody.turn_metadata'"));
    expect(home, isNot(contains('speechTurnMetadata:')));
    expect(runtime, isNot(contains('maaso_voice_prosody_hint')));
    expect(runtime, isNot(contains('SpeechTurnMetadata')));
  });

  test('prosody preference UI remains inside desktop-only advanced page', () {
    final source = File(
      'lib/src/features/settings/presentation/agent_settings_page.dart',
    ).readAsStringSync();
    final unsupportedGate = source.indexOf(
      'if (!_platformCapabilities.supportsAdvancedAiSettings)',
    );
    final advancedPage = source.indexOf('class _AdvancedFeaturesPage');
    final prosodySection = source.indexOf('class _VoiceProsodySection');

    expect(unsupportedGate, greaterThanOrEqualTo(0));
    expect(advancedPage, greaterThan(unsupportedGate));
    expect(prosodySection, greaterThan(advancedPage));
  });
}
