import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/glass_ui_service.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/world_composer.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.put(
      GlassUiService(supportsShaderFilters: () => true, forceFrosted: true),
    );
  });

  tearDown(appServices.reset);

  testWidgets('shared composer stays borderless unless the page opts in', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_morph()));

    expect(find.byKey(AppGlassComposerMorph.textInputBorderKey), findsNothing);
    expect(find.byKey(AppGlassComposerMorph.shellKey), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('text outline is subtle and excludes voice in $brightness', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(_morph(textInputBorder: true), brightness: brightness),
      );

      final outline = find.byKey(AppGlassComposerMorph.textInputBorderKey);
      final decoration =
          tester.widget<DecoratedBox>(outline).decoration as BoxDecoration;
      final border = decoration.border! as Border;
      expect(border.top.width, 0.5);
      expect(
        border.top.color,
        brightness == Brightness.light
            ? const Color(0xFFE5E7EB)
            : const Color(0xFF3A414C),
      );
      expect(decoration.borderRadius, BorderRadius.circular(28));
      expect(
        tester.getRect(outline),
        tester.getRect(find.byKey(AppGlassComposerMorph.inputGroupKey)),
      );
      expect(
        tester.getRect(outline).right,
        lessThan(
          tester
              .getRect(find.byKey(AppGlassComposerMorph.voiceControlKey))
              .left,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('voice mode removes the outline throughout the morph', (
    tester,
  ) async {
    final outline = find.byKey(AppGlassComposerMorph.textInputBorderKey);
    await tester.pumpWidget(_host(_morph(textInputBorder: true)));
    expect(outline, findsOneWidget);

    await tester.pumpWidget(
      _host(_morph(textInputBorder: true, voiceMode: true)),
    );
    expect(outline, findsNothing);
    await tester.pump(const Duration(milliseconds: 160));
    expect(outline, findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
    expect(outline, findsNothing);
    expect(
      tester.getSize(find.byKey(AppGlassComposerMorph.inputGroupKey)).width,
      0,
    );

    await tester.pumpWidget(_host(_morph(textInputBorder: true)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(outline, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page opt-in preserves text layout, focus, typing and send', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    var sends = 0;
    Widget composer({bool textInputBorder = false}) => ChatInputBar(
      controller: controller,
      focusNode: focus,
      floatingGlass: true,
      textInputBorder: textInputBorder,
      onSend: () => sends++,
    );

    await tester.pumpWidget(_host(composer()));
    final initialInput = tester.getRect(
      find.byKey(AppGlassComposerMorph.inputGroupKey),
    );
    final initialVoice = tester.getRect(
      find.byKey(AppGlassComposerMorph.voiceControlKey),
    );
    expect(find.byKey(AppGlassComposerMorph.textInputBorderKey), findsNothing);

    await tester.pumpWidget(_host(composer(textInputBorder: true)));
    expect(
      find.byKey(AppGlassComposerMorph.textInputBorderKey),
      findsOneWidget,
    );
    expect(
      tester.getRect(find.byKey(AppGlassComposerMorph.inputGroupKey)),
      initialInput,
    );
    expect(
      tester.getRect(find.byKey(AppGlassComposerMorph.voiceControlKey)),
      initialVoice,
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(controller.text, 'hello');
    await tester.tap(find.byType(WorldComposerSendButton));
    expect(sends, 1);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    focus.dispose();
    controller.dispose();
  });
}

Widget _host(Widget composer, {Brightness brightness = Brightness.light}) {
  return MaterialApp(
    theme: AppTheme.build(AppPalette.of(brightness, AppAccent.blue)),
    home: Scaffold(
      body: Center(child: SizedBox(width: 320, child: composer)),
    ),
  );
}

Widget _morph({bool textInputBorder = false, bool voiceMode = false}) {
  return AppGlassComposerMorph(
    voiceMode: voiceMode,
    floatingGlass: true,
    textInputBorder: textInputBorder,
    textRadius: 28,
    voiceDiameter: 56,
    editorChild: const Text('Editor'),
    submitChild: const SizedBox.square(dimension: 56),
    voiceControlBuilder: (_, _) => const SizedBox.expand(),
  );
}
