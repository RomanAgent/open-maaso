import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/agent_presence_service.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/world_composer.dart';

void main() {
  setUp(() => appServices.testMode = true);
  tearDown(appServices.reset);

  TextEditingController newController() {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    return controller;
  }

  testWidgets('floating glass is opt-in and preserves the default shell', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(ChatInputBar(controller: newController(), onSend: () {})),
    );

    final morph = tester.widget<AppGlassComposerMorph>(
      find.byType(AppGlassComposerMorph),
    );
    expect(morph.floatingGlass, isFalse);
    final shell = tester.widget<AppGlassSurface>(
      find.byKey(AppGlassComposerMorph.shellKey),
    );
    expect(shell.behavior, AppGlassSurfaceBehavior.staticSurface);
    expect(find.byKey(AppGlassSurface.backdropFilterKey), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'floating $brightness shell filters only its clipped backdrop',
      (tester) async {
        await tester.pumpWidget(
          _host(
            ChatInputBar(
              controller: newController(),
              onSend: () {},
              floatingGlass: true,
            ),
            brightness: brightness,
          ),
        );

        final filter = find.byKey(AppGlassSurface.backdropFilterKey);
        expect(filter, findsOneWidget);
        expect(tester.widget(filter), isA<BackdropFilter>());
        final clips = find.ancestor(
          of: filter,
          matching: find.byType(ClipRRect),
        );
        expect(clips, findsOneWidget);
        expect(
          tester.widget<ClipRRect>(clips).borderRadius,
          BorderRadius.circular(28),
        );
        expect(tester.getSize(filter), tester.getSize(clips));
        expect(tester.getSize(filter).height, 56);
        final decoration =
            tester
                    .widget<DecoratedBox>(
                      find.descendant(
                        of: filter,
                        matching: find.byType(DecoratedBox),
                      ),
                    )
                    .decoration
                as BoxDecoration;
        expect(decoration.color!.a, greaterThan(0));
        expect(decoration.color!.a, lessThan(1));
        final palette = AppTheme.build(
          AppPalette.of(brightness, AppAccent.blue),
        );
        expect(
          decoration.color!.withValues(alpha: 1),
          palette.colorScheme.surface.withValues(alpha: 1),
        );
        // The editor and both action controls are siblings of the glass, so the
        // blur never filters the user's text or consumes their pointer events.
        expect(
          find.descendant(of: filter, matching: find.byType(TextField)),
          findsNothing,
        );
        expect(
          find.descendant(
            of: filter,
            matching: find.byType(WorldComposerSendButton),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: filter,
            matching: find.byKey(AppGlassComposerMorph.voiceControlKey),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('high contrast uses an opaque readable shell without blur', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ChatInputBar(
          controller: newController(),
          onSend: () {},
          floatingGlass: true,
        ),
        highContrast: true,
      ),
    );
    final shell = find.byKey(AppGlassComposerMorph.shellKey);
    expect(find.byKey(AppGlassSurface.backdropFilterKey), findsNothing);
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: shell,
                    matching: find.byKey(AppGlassSurface.frostedLayerKey),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(decoration.color!.a, 1);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('unsupported native underlays retain the non-sampling fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ChatInputBar(
          controller: newController(),
          onSend: () {},
          floatingGlass: true,
        ),
        backdrop: GlassBackdropKind.unityUnderlay,
      ),
    );
    expect(find.byKey(AppGlassSurface.backdropFilterKey), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(AppGlassComposerMorph.shellKey),
        matching: find.byType(AppGlassSurface),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'floating composer preserves typing keyboard send and interrupt',
    (tester) async {
      final controller = newController();
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var sends = 0;
      var interrupts = 0;
      final activities = <PresenceInputActivityKind>[];
      Widget composer({bool thinking = false}) => _host(
        ChatInputBar(
          controller: controller,
          focusNode: focus,
          onSend: () => sends++,
          onInterrupt: () => interrupts++,
          onInputActivity: activities.add,
          isThinking: thinking,
          floatingGlass: true,
        ),
      );
      await tester.pumpWidget(composer());
      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(activities, contains(PresenceInputActivityKind.typing));
      await tester.testTextInput.receiveAction(TextInputAction.send);
      expect(sends, 1);
      await tester.tap(find.byType(WorldComposerSendButton));
      expect(sends, 2);

      controller.clear();
      await tester.pumpWidget(composer(thinking: true));
      await tester.pump();
      await tester.tap(find.byType(WorldComposerSendButton));
      expect(interrupts, 1);
      expect(sends, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changing the glass treatment preserves the focused draft', (
    tester,
  ) async {
    final controller = newController();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    Widget composer({required bool floatingGlass}) => _host(
      ChatInputBar(
        controller: controller,
        focusNode: focus,
        onSend: () {},
        floatingGlass: floatingGlass,
      ),
    );
    await tester.pumpWidget(composer(floatingGlass: false));
    await tester.enterText(find.byType(TextField), 'Keep this draft');
    final editor = tester.state(find.byType(EditableText));
    await tester.pumpWidget(composer(floatingGlass: true));
    expect(tester.state(find.byType(EditableText)), same(editor));
    expect(controller.text, 'Keep this draft');
    expect(focus.hasFocus, isTrue);
    expect(find.byKey(AppGlassSurface.backdropFilterKey), findsOneWidget);
  });

  testWidgets(
    'floating composer preserves disabled controls and field config',
    (tester) async {
      final controller = newController()..text = 'Draft';
      var sends = 0;
      await tester.pumpWidget(
        _host(
          ChatInputBar(
            controller: controller,
            onSend: () => sends++,
            enabled: false,
            floatingGlass: true,
            maxLength: 120,
            textFieldKey: const ValueKey('floating-prompt'),
          ),
        ),
      );
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('floating-prompt')),
      );
      expect(field.enabled, isFalse);
      expect(field.maxLength, 120);
      expect(field.decoration!.filled, isFalse);
      final send = tester.widget<WorldComposerSendButton>(
        find.byType(WorldComposerSendButton),
      );
      expect(send.enabled, isFalse);
      expect(send.onTap, isNull);
      await tester.tap(find.byKey(const ValueKey('voice-orb')));
      expect(sends, 0);
      expect(controller.text, 'Draft');
    },
  );

  testWidgets(
    'floating composer retains one voice orb and reduced-motion endpoint',
    (tester) async {
      final controller = newController();
      var interrupts = 0;
      Widget composer({required bool voiceOnly}) => _host(
        ChatInputBar(
          controller: controller,
          onSend: () {},
          floatingGlass: true,
          voiceOnly: voiceOnly,
          isThinking: true,
          onInterrupt: () => interrupts++,
        ),
        reducedMotion: true,
      );
      await tester.pumpWidget(composer(voiceOnly: false));
      await tester.pumpWidget(composer(voiceOnly: true));
      await tester.pump();
      expect(
        tester.getSize(find.byKey(AppGlassComposerMorph.inputGroupKey)).width,
        0,
      );
      expect(find.byKey(const ValueKey('voice-orb')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('voice-orb')));
      expect(interrupts, 1);
      await tester.pumpWidget(composer(voiceOnly: false));
      await tester.pump();
      expect(
        tester.getSize(find.byKey(AppGlassComposerMorph.inputGroupKey)).width,
        greaterThan(0),
      );
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _host(
  Widget composer, {
  Brightness brightness = Brightness.light,
  bool highContrast = false,
  bool reducedMotion = false,
  GlassBackdropKind backdrop = GlassBackdropKind.flutter,
}) => MaterialApp(
  theme: AppTheme.build(AppPalette.of(brightness, AppAccent.blue)),
  home: MediaQuery(
    data: MediaQueryData(
      highContrast: highContrast,
      disableAnimations: reducedMotion,
    ),
    child: Scaffold(
      body: MaasoGlassBackdropScope(
        backdropKind: backdrop,
        renderMode: GlassRenderMode.frosted,
        child: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xFF447766))),
            Positioned(left: 16, bottom: 16, width: 400, child: composer),
          ],
        ),
      ),
    ),
  ),
);
