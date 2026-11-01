import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/features/account_deletion/presentation/account_deletion_page.dart';
import 'package:maaso/src/features/people_safety/presentation/people_safety_page.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/presentation/privacy_page.dart';

import 'account_deletion_service_test.dart' show DeletionFixture;
import 'privacy_service_test.dart' show PrivacyFake;

const _preview = bool.fromEnvironment('MAASO_SAVE_THEME_PREVIEWS');
const _previewFont = 'MaasoV4ThemePreview';
const _boundary = Key('v4-theme-render');

Future<List<Color>> _pixels(WidgetTester tester, String name) async =>
    (await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_boundary),
      );
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final rgba = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        if (_preview) {
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          final file = File('build/verification/v4-theme/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(png.buffer.asUint8List());
        }
        return [
          for (final y in [image.height ~/ 3, image.height ~/ 2])
            Color.fromARGB(
              rgba.getUint8((y * image.width + 2) * 4 + 3),
              rgba.getUint8((y * image.width + 2) * 4),
              rgba.getUint8((y * image.width + 2) * 4 + 1),
              rgba.getUint8((y * image.width + 2) * 4 + 2),
            ),
        ];
      } finally {
        image.dispose();
      }
    }))!;

void _expectNeutral(Color color, Brightness brightness) {
  final rgb = [color.r, color.g, color.b]..sort();
  final neutralSurface = brightness == Brightness.dark
      ? MaasoFrostTokens.darkSurface
      : MaasoFrostTokens.lightSurface;
  final neutralRgb = [neutralSurface.r, neutralSurface.g, neutralSurface.b]
    ..sort();
  expect(color.a, 1, reason: 'Page backgrounds must remain opaque.');
  expect(
    rgb.last - rgb.first,
    lessThanOrEqualTo(neutralRgb.last - neutralRgb.first + 0.025),
    reason: 'The content background must not take the accent hue.',
  );
  expect(
    color.computeLuminance(),
    brightness == Brightness.light ? greaterThan(.85) : lessThan(.08),
  );
}

Future<void> _mount(
  WidgetTester tester,
  Widget page,
  Brightness brightness, {
  double scale = 1,
}) async {
  final theme = AppTheme.build(AppPalette.of(brightness, AppAccent.pink));
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: _preview
            ? theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: _previewFont),
                textButtonTheme: TextButtonThemeData(
                  style: theme.textButtonTheme.style?.copyWith(
                    textStyle: const WidgetStatePropertyAll(
                      TextStyle(fontFamily: _previewFont),
                    ),
                  ),
                ),
                outlinedButtonTheme: OutlinedButtonThemeData(
                  style: theme.outlinedButtonTheme.style?.copyWith(
                    textStyle: const WidgetStatePropertyAll(
                      TextStyle(fontFamily: _previewFont),
                    ),
                  ),
                ),
                filledButtonTheme: FilledButtonThemeData(
                  style: theme.filledButtonTheme.style?.copyWith(
                    textStyle: const WidgetStatePropertyAll(
                      TextStyle(fontFamily: _previewFont),
                    ),
                  ),
                ),
              )
            : theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: RepaintBoundary(key: _boundary, child: page),
      ),
    ),
  );
  // The deletion fixture reads its receipt from an asynchronous local store.
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  });
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!_preview) return;
    // Optional readable local previews; the font is never copied into the app.
    const fontPath = String.fromEnvironment(
      'MAASO_THEME_PREVIEW_FONT',
      defaultValue: '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
    );
    final font = ByteData.sublistView(await File(fontPath).readAsBytes());
    await (FontLoader(_previewFont)..addFont(Future.value(font))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  for (final brightness in Brightness.values) {
    for (final pageName in [
      'privacy',
      'deletion',
      'deletion-unavailable',
      'blocked-accounts',
    ]) {
      testWidgets('$pageName paints the Maaso $brightness neutral theme', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(375, 812);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late final Widget page;
        switch (pageName) {
          case 'privacy':
            final service = PrivacyService(gateway: PrivacyFake());
            addTearDown(service.onClose);
            page = PrivacyPage(service: service);
          case 'deletion':
            final fixture = DeletionFixture();
            addTearDown(fixture.service.dispose);
            page = AccountDeletionPage(service: fixture.service);
          case 'deletion-unavailable':
            page = const AccountDeletionRoutePage();
          case 'blocked-accounts':
            page = const PeopleSafetyPage(route: '/people-safety');
        }
        await _mount(tester, page, brightness);
        final colors = await _pixels(tester, '$pageName-${brightness.name}');
        for (final color in colors) {
          _expectNeutral(color, brightness);
        }
        final header = find.byType(AppSecondaryHeader);
        expect(header, findsOneWidget);
        final title = tester.widget<Text>(
          find.descendant(of: header, matching: find.byType(Text)).first,
        );
        final textLuminance = title.style!.color!.computeLuminance();
        final backgroundLuminance = colors.first.computeLuminance();
        final luminances = [textLuminance, backgroundLuminance]..sort();
        expect(
          (luminances.last + .05) / (luminances.first + .05),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          Theme.of(tester.element(header)).colorScheme.primary,
          AppAccent.pink.seed,
          reason: 'Page styling must preserve the selected user accent.',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('safety pages fit landscape with large $brightness text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(812, 375);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = DeletionFixture();
      addTearDown(fixture.service.dispose);
      for (final page in [
        AccountDeletionPage(service: fixture.service),
        const AccountDeletionRoutePage(),
        const PeopleSafetyPage(route: '/people-safety'),
      ]) {
        await _mount(tester, page, brightness, scale: 2);
        await tester.drag(find.byType(ListView).first, const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }
}
