import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_transient.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_notice_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/glass_render_policy.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';

void main() {
  tearDown(appNavigation.dismissTopSnackBar);

  testWidgets(
    'generic top notice uses bounded frost and a readable foreground',
    (tester) async {
      await tester.pumpWidget(
        _NoticeTestApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => appNavigation.showSnackBar(
                  message: 'Readable feedback',
                  backgroundColor: Colors.black38,
                  colorText: Colors.white,
                  boxShadows: const <BoxShadow>[],
                  icon: const Icon(Icons.info_outline, color: Colors.white),
                ),
                child: const Text('Show generic notice'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Show generic notice'));
      await tester.pump();
      await tester.pump(kThemeAnimationDuration);

      final notice = find.byKey(const ValueKey<String>('app-top-notice'));
      final decoration = _noticeDecoration(tester, notice);
      expect(
        decoration.color,
        MaasoFrostTokens.lightSurface.withValues(
          alpha: MaasoFrostTokens.overlayFillAlpha,
        ),
      );
      expect(decoration.border, isNull);
      expect(
        find.descendant(of: notice, matching: find.byType(BackdropFilter)),
        findsOneWidget,
      );
      final opacity = tester.widget<AnimatedOpacity>(
        find.ancestor(of: notice, matching: find.byType(AnimatedOpacity)),
      );
      expect(opacity.opacity, 1);
      expect(
        find.descendant(of: notice, matching: find.byType(Material)),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('app-top-notice-icon')),
        findsOneWidget,
      );

      final textFinder = find.text('Readable feedback');
      final text = tester.widget<Text>(textFinder);
      final effectiveStyle = DefaultTextStyle.of(
        tester.element(textFinder),
      ).style.merge(text.style);
      expect(effectiveStyle.color, MaasoFrostTokens.lightTextPrimary);
      expect(effectiveStyle.decoration, isNot(TextDecoration.underline));
      expect(effectiveStyle.decorationColor, isNot(const Color(0xFFFFFF00)));
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('glass notice is readable in $brightness', (tester) async {
      final dark = brightness == Brightness.dark;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => Stack(
            fit: StackFit.expand,
            children: <Widget>[
              child ?? const SizedBox.shrink(),
              const AppTopNoticeHost(),
            ],
          ),
          home: Scaffold(
            body: FilledButton(
              onPressed: () => showAppGlassNotice(
                title: 'Publishing failed',
                message: 'Please check your connection and try again.',
                icon: Icons.info_outline,
              ),
              child: const Text('Show glass notice'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Show glass notice'));
      await tester.pump();
      await tester.pump(kThemeAnimationDuration);

      final notice = find.byKey(const ValueKey<String>('app-top-notice'));
      final decoration = _noticeDecoration(tester, notice);
      final surface = dark
          ? MaasoFrostTokens.darkSurface
          : MaasoFrostTokens.lightSurface;
      expect(
        decoration.color,
        surface.withValues(alpha: MaasoFrostTokens.overlayFillAlpha),
      );
      final titleFinder = find.text('Publishing failed');
      final title = tester.widget<Text>(titleFinder);
      final effectiveTitleStyle = DefaultTextStyle.of(
        tester.element(titleFinder),
      ).style.merge(title.style);
      expect(
        effectiveTitleStyle.color,
        dark
            ? MaasoFrostTokens.darkTextPrimary
            : MaasoFrostTokens.lightTextPrimary,
      );
      expect(effectiveTitleStyle.decoration, isNot(TextDecoration.underline));
      final message = tester.widget<Text>(
        find.text('Please check your connection and try again.'),
      );
      expect(
        message.style?.color,
        dark
            ? MaasoFrostTokens.darkTextSecondary
            : MaasoFrostTokens.lightTextSecondary,
      );
      for (final backdrop in <Color>[Colors.white, Colors.black]) {
        final renderedFill = Color.alphaBlend(decoration.color!, backdrop);
        expect(
          _contrast(effectiveTitleStyle.color!, renderedFill),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrast(message.style!.color!, renderedFill),
          greaterThanOrEqualTo(4.5),
        );
      }
    });
  }

  testWidgets('ScaffoldMessenger fallback uses the same frosted surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () =>
                  appNavigation.showSnackBar(message: 'Fallback feedback'),
              child: const Text('Show fallback notice'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show fallback notice'));
    await tester.pump();

    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.backgroundColor, Colors.transparent);
    expect(snackBar.elevation, 0);
    final notice = find.byType(AppGlassNoticeSurface);
    expect(notice, findsOneWidget);
    expect(_noticeDecoration(tester, notice).color?.a, lessThan(1));
    expect(find.byType(BackdropFilter), findsNothing);
    final fallbackText = tester.widget<Text>(find.text('Fallback feedback'));
    expect(fallbackText.style?.color, MaasoFrostTokens.lightTextPrimary);
    expect(fallbackText.style?.decoration, TextDecoration.none);
  });

  for (final brightness in Brightness.values) {
    testWidgets('plain messenger content is readable in $brightness', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MaasoGlassBackdropScope(
            backdropKind: GlassBackdropKind.flutter,
            renderMode: GlassRenderMode.frosted,
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  appGlassSnackBar(content: const Text('Setting not saved')),
                ),
                child: const Text('Show local notice'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show local notice'));
      await tester.pumpAndSettle();
      final notice = find.byType(AppGlassNoticeSurface);
      final text = find.text('Setting not saved');
      final style = DefaultTextStyle.of(tester.element(text)).style;
      final fill = _noticeDecoration(tester, notice).color!;
      for (final backdrop in <Color>[Colors.white, Colors.black]) {
        expect(
          _contrast(style.color!, Color.alphaBlend(fill, backdrop)),
          greaterThanOrEqualTo(4.5),
        );
      }
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('high contrast notice uses an opaque accessible fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(highContrast: true),
          child: MaasoGlassBackdropScope(
            backdropKind: GlassBackdropKind.flutter,
            renderMode: GlassRenderMode.frosted,
            child: child!,
          ),
        ),
        home: const Scaffold(
          body: AppGlassNoticeSurface(child: Text('Readable high contrast')),
        ),
      ),
    );
    final notice = find.byType(AppGlassNoticeSurface);
    expect(_noticeDecoration(tester, notice).color?.a, 1);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('Readable high contrast'), findsOneWidget);
  });

  testWidgets('native view notice keeps frost without Flutter sampling', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MaasoGlassBackdropScope(
            backdropKind: GlassBackdropKind.platformView,
            renderMode: GlassRenderMode.frosted,
            child: AppGlassNoticeSurface(child: Text('Native feedback')),
          ),
        ),
      ),
    );
    final notice = find.byType(AppGlassNoticeSurface);
    expect(
      _noticeDecoration(tester, notice).color?.a,
      closeTo(MaasoFrostTokens.overlayFillAlpha, .005),
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('top notice stays above a root modal bottom sheet', (
    tester,
  ) async {
    await tester.pumpWidget(
      _NoticeTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  useRootNavigator: true,
                  builder: (sheetContext) => SizedBox(
                    key: const ValueKey<String>('test-bottom-sheet'),
                    height: 220,
                    child: Center(
                      child: FilledButton(
                        onPressed: () => showAppGlassNotice(
                          title: 'Publishing not supported',
                          message: 'This game is local only.',
                        ),
                        child: const Text('Show notice'),
                      ),
                    ),
                  ),
                ),
                child: const Text('Open sheet'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open sheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show notice'));
    await tester.pump();
    await tester.pump(kThemeAnimationDuration);

    final notice = find.byKey(const ValueKey<String>('app-top-notice'));
    final sheet = find.byKey(const ValueKey<String>('test-bottom-sheet'));
    expect(notice, findsOneWidget);
    expect(sheet, findsOneWidget);
    expect(
      tester.getBottomLeft(notice).dy,
      lessThan(tester.getTopLeft(sheet).dy),
    );
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('latest top notice replaces the previous timer', (tester) async {
    await tester.pumpWidget(
      _NoticeTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: <Widget>[
                FilledButton(
                  onPressed: () => appNavigation.showSnackBar(
                    message: 'First',
                    duration: const Duration(milliseconds: 100),
                  ),
                  child: const Text('First notice'),
                ),
                FilledButton(
                  onPressed: () => appNavigation.showSnackBar(
                    message: 'Second',
                    duration: const Duration(seconds: 1),
                  ),
                  child: const Text('Second notice'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('First notice'));
    await tester.pump();
    await tester.tap(find.text('Second notice'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('reduced motion fast notice paints one frame', (tester) async {
    await tester.pumpWidget(
      _NoticeTestApp(
        disableAnimations: true,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => appNavigation.showSnackBar(
                message: 'Immediate feedback',
                duration: Duration.zero,
              ),
              child: const Text('Show fast notice'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show fast notice'));
    await tester.pump();

    expect(find.text('Immediate feedback'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('app-top-notice')),
      findsOneWidget,
    );
  });

  testWidgets('top notice fits a small phone with large text', (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _NoticeTestApp(
        textScaler: const TextScaler.linear(2),
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => appNavigation.showSnackBar(
                title: 'Publishing needs attention',
                message: 'Check this game and try publishing it again.',
              ),
              child: const Text('Show accessible notice'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show accessible notice'));
    await tester.pump();
    await tester.pump(kThemeAnimationDuration);

    final notice = find.byKey(const ValueKey<String>('app-top-notice'));
    expect(notice, findsOneWidget);
    expect(tester.getRect(notice).right, lessThanOrEqualTo(375));
    expect(
      find.bySemanticsLabel(
        'Publishing needs attention\nCheck this game and try publishing it again.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}

class _NoticeTestApp extends StatelessWidget {
  const _NoticeTestApp({
    required this.home,
    this.disableAnimations = false,
    this.textScaler,
  });

  final Widget home;
  final bool disableAnimations;
  final TextScaler? textScaler;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      builder: (context, child) {
        final media = MediaQuery.of(context).copyWith(
          disableAnimations: disableAnimations,
          textScaler: textScaler,
        );
        return MediaQuery(
          data: media,
          child: MaasoGlassBackdropScope(
            backdropKind: GlassBackdropKind.flutter,
            renderMode: GlassRenderMode.frosted,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                child ?? const SizedBox.shrink(),
                const AppTopNoticeHost(),
              ],
            ),
          ),
        );
      },
      home: home,
    );
  }
}

BoxDecoration _noticeDecoration(WidgetTester tester, Finder notice) =>
    tester
            .widget<DecoratedBox>(
              find.descendant(
                of: notice,
                matching: find.byKey(AppGlassSurface.frostedLayerKey),
              ),
            )
            .decoration
        as BoxDecoration;

double _contrast(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  return first > second
      ? (first + .05) / (second + .05)
      : (second + .05) / (first + .05);
}
