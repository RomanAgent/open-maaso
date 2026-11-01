import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('new material values remain tied to the design anchor', () {
    final anchor =
        jsonDecode(
              File(
                'design-system/maaso-soft-frost/tokens.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final material = anchor['material'] as Map<String, dynamic>;
    expect(
      material['blurredInputFillAlpha'],
      MaasoFrostTokens.blurredInputFillAlpha,
    );
    expect(
      material['blurredCapsuleFillAlpha'],
      MaasoFrostTokens.blurredCapsuleFillAlpha,
    );
    expect(material['messageFillAlpha'], MaasoFrostTokens.messageFillAlpha);
    expect(
      material['messageUserFillAlpha'],
      MaasoFrostTokens.messageUserFillAlpha,
    );
  });

  testWidgets('fixed Flutter input diffuses the backdrop without opaque fill', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const AppFrostedInputBackground(cornerRadius: 28),
        backdrop: GlassBackdropKind.flutter,
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find.byKey(AppGlassSurface.frostedLayerKey),
                )
                .decoration
            as BoxDecoration;
    expect(decoration.color!.a, closeTo(.64, .005));
    expect(decoration.border, isNull);
    expect(find.byType(UiKitView), findsNothing);
  });

  testWidgets(
    'native frost does not consume input and is disposed in voice mode',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var sends = 0;
      Widget composer(bool voice) => _host(
        AppGlassComposerMorph(
          floatingGlass: true,
          voiceMode: voice,
          textRadius: 28,
          voiceDiameter: 56,
          editorChild: TextField(controller: controller),
          submitChild: IconButton(
            onPressed: () => sends++,
            icon: const Icon(Icons.send),
          ),
          voiceControlBuilder: (context, progress) => const SizedBox.expand(),
        ),
      );
      await tester.pumpWidget(composer(false));
      await tester.pumpAndSettle();
      expect(find.byType(UiKitView), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      final view = tester.widget<UiKitView>(find.byType(UiKitView));
      expect(view.viewType, AppFrostedInputBackground.nativeViewType);
      expect(view.creationParams, {'dark': false, 'cornerRadius': 28.0});
      expect(
        find.ancestor(
          of: find.byType(UiKitView),
          matching: find.byType(IgnorePointer),
        ),
        findsWidgets,
      );
      await tester.enterText(find.byType(TextField), '磨砂输入');
      await tester.tap(find.byIcon(Icons.send));
      expect(sends, 1);
      expect(controller.text, '磨砂输入');
      await tester.pumpWidget(composer(true));
      await tester.pumpAndSettle();
      expect(find.byType(UiKitView), findsNothing);
      expect(calls.where((call) => call.method == 'create'), hasLength(1));
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
      await tester.pumpWidget(composer(false));
      await tester.pumpAndSettle();
      expect(find.byType(UiKitView), findsOneWidget);
      expect(controller.text, '磨砂输入');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.method == 'dispose'), hasLength(2));
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('high contrast and scroll content never create native blur', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final highContrast in [true, false]) {
      const input = SizedBox(
        height: 56,
        child: AppFrostedInputBackground(cornerRadius: 28),
      );
      await tester.pumpWidget(
        _host(
          highContrast ? input : const SingleChildScrollView(child: input),
          highContrast: highContrast,
        ),
      );
      expect(find.byType(UiKitView), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      if (highContrast) {
        final decoration =
            tester
                    .widget<DecoratedBox>(
                      find.byKey(AppGlassSurface.frostedLayerKey),
                    )
                    .decoration
                as BoxDecoration;
        expect(decoration.color!.a, 1);
      }
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'message frost keeps translucent white and high contrast fallback',
    (tester) async {
      for (final highContrast in [false, true]) {
        await tester.pumpWidget(
          _host(
            const AppGlassSurface(
              role: AppGlassSurfaceRole.message,
              blur: true,
              child: Text('回复'),
            ),
            highContrast: highContrast,
          ),
        );
        final decoration =
            tester
                    .widget<DecoratedBox>(
                      find.byKey(AppGlassSurface.frostedLayerKey),
                    )
                    .decoration
                as BoxDecoration;
        expect(decoration.color!.a, closeTo(highContrast ? 1 : .82, .005));
        expect(decoration.border, isNull);
        expect(find.byType(UiKitView), findsNothing);
        expect(find.byType(BackdropFilter), findsNothing);
      }
    },
  );
}

Widget _host(
  Widget child, {
  GlassBackdropKind backdrop = GlassBackdropKind.unityUnderlay,
  bool highContrast = false,
}) {
  return MaterialApp(
    theme: AppTheme.build(AppPalette.of(Brightness.light, AppAccent.blue)),
    home: MediaQuery(
      data: MediaQueryData(highContrast: highContrast),
      child: Scaffold(
        body: Center(
          child: MaasoGlassBackdropScope(
            backdropKind: backdrop,
            renderMode: GlassRenderMode.frosted,
            child: SizedBox(width: 350, height: 56, child: child),
          ),
        ),
      ),
    ),
  );
}
