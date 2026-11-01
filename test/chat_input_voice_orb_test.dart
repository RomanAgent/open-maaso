import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_controls.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/ui/world_composer.dart';

void main() {
  test('home chat input keeps text actions and uses the shared glass orb', () {
    final source = File(
      'lib/src/core/widgets/chat_input_bar.dart',
    ).readAsStringSync();
    _expectVoiceOrbComposer(source);

    expect(source, contains('playbackActive: _agentSpeaking'));
    expect(source, contains('awaitingFinal: _nativeAsrAwaitingFinal'));
    expect(source, contains('isThinking: widget.isThinking'));
    _expectTransparentTextEditor(
      _classBody(
        source,
        'class _TextRow',
        '// ─────────────────────────── Voice mode',
      ),
    );
  });

  test('home chat input unfocuses when tapping outside the text field', () {
    final source = File(
      'lib/src/core/widgets/chat_input_bar.dart',
    ).readAsStringSync();

    expect(source, contains('onTapOutside:'));
    expect(source, contains('FocusManager.instance.primaryFocus?.unfocus()'));
  });

  testWidgets('shared chat input forwards reusable field configuration', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInputBar(
            controller: controller,
            onSend: () {},
            enabled: false,
            maxLength: 120,
            focusNode: focusNode,
            textFieldKey: const Key('shared-agent-prompt-input'),
          ),
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    final send = tester.widget<WorldComposerSendButton>(
      find.byType(WorldComposerSendButton),
    );
    expect(field.enabled, isFalse);
    expect(field.maxLength, 120);
    expect(field.focusNode, same(focusNode));
    expect(field.key, const Key('shared-agent-prompt-input'));
    expect(field.decoration?.counterText, '');
    expect(send.enabled, isFalse);
  });

  testWidgets('shared composer send button uses black frost', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInputBar(controller: controller, onSend: () {}),
        ),
      ),
    );

    final button = tester.widget<AppGlassIconButton>(
      find.descendant(
        of: find.byType(WorldComposerSendButton),
        matching: find.byType(AppGlassIconButton),
      ),
    );
    expect(
      button.color,
      MaasoFrostTokens.composerAction.withValues(
        alpha: MaasoFrostTokens.capsuleFillAlpha,
      ),
    );
    expect(button.foregroundColor, Colors.white);
    _expectBlackSubmitFrost(tester);
  });

  testWidgets('stop and draft send share black frost and keep their actions', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var sends = 0;
    var interrupts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInputBar(
            controller: controller,
            isThinking: true,
            onSend: () => sends++,
            onInterrupt: () => interrupts++,
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    _expectBlackSubmitFrost(tester);
    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pump();
    expect(interrupts, 1);
    expect(sends, 0);

    await tester.enterText(find.byType(TextField), '继续聊天');
    await tester.pump();
    expect(find.byIcon(Icons.stop_rounded), findsNothing);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    _expectBlackSubmitFrost(tester);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    expect(interrupts, 1);
    expect(sends, 1);
  });

  testWidgets('busy active voice orb directly interrupts the current turn', (
    tester,
  ) async {
    final controller = TextEditingController();
    var sends = 0;
    var interrupts = 0;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInputBar(
            controller: controller,
            onSend: () => sends += 1,
            voiceOnly: true,
            isThinking: true,
            onInterrupt: () => interrupts += 1,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('voice-orb')));
    await tester.pump();

    expect(interrupts, 1);
    expect(sends, 0);
  });
}

void _expectBlackSubmitFrost(WidgetTester tester) {
  final submit = find.byType(WorldComposerSendButton);
  final decoration =
      tester
              .widget<DecoratedBox>(
                find.descendant(
                  of: submit,
                  matching: find.byKey(AppGlassSurface.frostedLayerKey),
                ),
              )
              .decoration
          as BoxDecoration;
  expect(
    decoration.color,
    MaasoFrostTokens.composerAction.withValues(
      alpha: MaasoFrostTokens.capsuleFillAlpha,
    ),
  );
  expect(decoration.border, isNull);
  expect(
    find.descendant(of: submit, matching: find.byType(BackdropFilter)),
    findsNothing,
  );
  expect(tester.getSize(submit), const Size(56, 56));
  expect(
    tester
        .widget<Icon>(find.descendant(of: submit, matching: find.byType(Icon)))
        .color,
    Colors.white,
  );
}

void _expectVoiceOrbComposer(String source) {
  final textRow = _classBody(
    source,
    'class _TextRow',
    '// ─────────────────────────── Voice mode',
  );
  final voiceMode = _classBody(
    source,
    'class _VoiceOrbMode',
    'String _voiceOrbSemanticLabel',
  );

  expect(textRow, isNot(contains('WorldComposerSendButton')));
  expect(textRow, isNot(contains('WorldComposerIconButton')));
  expect(textRow, isNot(contains('Icons.mic_none_rounded')));

  expect(source, isNot(contains('_composerWidthFor(')));
  expect(source, contains('AppGlassComposerMorph('));
  expect(source, contains('editorChild:'));
  expect(source, contains('submitChild: _buildSubmitButton()'));
  expect(source, contains('voiceControlBuilder:'));
  expect(source, contains('voiceDiameter: 56'));
  expect(source, contains('WorldComposerSendButton'));
  expect(source, isNot(contains('class _ComposerModeSwitcher')));
  expect(source, contains('class _VoiceOrbMode'));
  expect(voiceMode, contains('AppGlassVoiceToggle'));
  expect(voiceMode, isNot(contains('Icons.keyboard_alt_rounded')));
  expect(source, contains('resolveVoiceOrbPhase('));
  expect(source, isNot(contains('class _VoiceListeningOrb')));
  expect(source, isNot(contains('class _VoiceOrbPainter')));
  expect(source, isNot(contains('_paintSiriGlassCore')));
  expect(source, isNot(contains('_paintSiriGlow')));
  expect(source, isNot(contains('_paintSiriWaveform')));
  expect(source, isNot(contains('Icons.mic_rounded')));
  expect(source, isNot(contains('AdventureChrome.ink')));
  expect(
    source,
    isNot(
      contains('ColorConstant.skyColor,\n          ColorConstant.primaryColor'),
    ),
  );
}

void _expectTransparentTextEditor(String textRow) {
  expect(textRow, contains('filled: false'));
  expect(textRow, contains('fillColor: Colors.transparent'));
  expect(textRow, contains('border: InputBorder.none'));
  expect(textRow, contains('enabledBorder: InputBorder.none'));
  expect(textRow, contains('focusedBorder: InputBorder.none'));
  expect(textRow, contains('disabledBorder: InputBorder.none'));
  expect(textRow, contains('errorBorder: InputBorder.none'));
  expect(textRow, contains('focusedErrorBorder: InputBorder.none'));
  expect(textRow, isNot(contains('AppGlassField(')));
}

String _classBody(String source, String start, String end) {
  final from = source.indexOf(start);
  final to = source.indexOf(end, from + start.length);
  expect(from, greaterThanOrEqualTo(0), reason: start);
  expect(to, greaterThan(from), reason: end);
  return source.substring(from, to);
}
