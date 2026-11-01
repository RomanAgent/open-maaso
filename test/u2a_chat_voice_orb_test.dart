import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('u2a chat maps existing state into the shared glass voice orb', () {
    final source = File(
      'lib/src/core/widgets/chat_input_bar.dart',
    ).readAsStringSync();
    final page = File(
      'lib/src/features/chat/presentation/u2a_chat_page.dart',
    ).readAsStringSync();
    final composer = File(
      'lib/src/features/chat/presentation/media/u2a_chat_composer.dart',
    ).readAsStringSync();

    expect(source, contains('this.isThinking = false'));
    expect(source, contains('final bool isThinking;'));
    expect(source, contains('AppGlassVoiceToggle('));
    expect(source, contains('resolveVoiceOrbPhase('));
    expect(source, contains('playbackActive: _agentSpeaking'));
    expect(source, contains('awaitingFinal: _nativeAsrAwaitingFinal'));
    expect(source, contains('isThinking: widget.isThinking'));
    expect(source, contains('AppGlassComposerMorph('));
    expect(source, contains('editorChild:'));
    expect(source, contains('submitChild: _buildSubmitButton()'));
    expect(source, contains('voiceControlBuilder:'));
    expect(source, contains('voiceDiameter: 56'));
    expect(source, isNot(contains('WorldComposerIconButton(')));
    expect(source, isNot(contains('class _ComposerModeSwitcher')));
    expect(source, isNot(contains('class _VoiceListeningOrb')));
    expect(source, isNot(contains('class _VoiceOrbPainter')));
    expect(source, isNot(contains('_paintSiriWaveform')));
    expect(source, isNot(contains('Icons.mic_rounded')));

    expect(page, contains('U2aChatComposer(controller: controller)'));
    expect(composer, contains('core/widgets/chat_input_bar.dart'));
    expect(composer, contains('isThinking: c.busy'));
    expect(composer, contains('onInterrupt: c.interruptCurrent'));
  });
}
