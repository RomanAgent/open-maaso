import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/context_stats_service.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:maaso/src/features/settings/presentation/settings_context_panel.dart';

const _toggleKey = ValueKey('settings-context-toggle');
const _usageKey = ValueKey('settings-context-usage');
const _panelKey = ValueKey('settings-context-panel');

void main() {
  setUp(() async {
    await appServices.reset();
    AppLocalization.updateLocale(const Locale('en'));
  });

  tearDown(() async {
    AppLocalization.updateLocale(const Locale('en'));
    await appServices.reset();
  });

  testWidgets('does not instantiate a missing or lazy stats service', (
    tester,
  ) async {
    await _mount(tester);
    expect(find.byKey(_panelKey), findsNothing);

    var created = 0;
    appServices.lazyPut<ContextStatsService>(() {
      created++;
      return ContextStatsService();
    });
    await tester.pump();
    await tester.pump();
    expect(created, 0);
    expect(find.byKey(_panelKey), findsNothing);
  });

  testWidgets('empty state does not present demonstration model or usage', (
    tester,
  ) async {
    appServices.put(ContextStatsService());
    await _mount(tester);

    expect(find.text('settings.context_no_conversations'.tr), findsOneWidget);
    expect(find.text('settings.context_first_conversation'.tr), findsOneWidget);
    expect(
      tester.widget<LinearProgressIndicator>(find.byKey(_usageKey)).value,
      0,
    );
    await tester.tap(find.byKey(_toggleKey));
    await tester.pump();

    expect(find.text('settings.context_note'.tr), findsOneWidget);
    expect(find.text('settings.model'.tr), findsNothing);
    expect(find.textContaining('128k'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'collapsed panel observes real usage and exposes readable details',
    (tester) async {
      final service = appServices.put(ContextStatsService());
      final semantics = tester.ensureSemantics();
      await _mount(tester);
      service.record(
        modelName: 'qwen-long-account-model',
        systemPromptChars: 3500,
        userInputChars: 7000,
        responseChars: 1750,
      );
      await tester.pump();

      expect(find.text('3.5k / 1.0M'), findsOneWidget);
      expect(find.text('qwen-long-account-model'), findsNothing);
      expect(find.text('settings.context_note'.tr), findsNothing);
      expect(
        tester.widget<LinearProgressIndicator>(find.byKey(_usageKey)).value,
        closeTo(.0035, .000001),
      );
      final collapsed = _toggleSemantics(tester);
      expect(collapsed.flagsCollection.isButton, isTrue);
      expect(collapsed.flagsCollection.isExpanded.toBoolOrNull(), isFalse);
      expect(collapsed.value, '3.5k / 1.0M');
      expect(
        tester.getSize(find.byKey(_toggleKey)).height,
        greaterThanOrEqualTo(48),
      );

      await tester.tap(find.byKey(_toggleKey));
      await tester.pump();
      expect(
        _toggleSemantics(tester).flagsCollection.isExpanded.toBoolOrNull(),
        isTrue,
      );
      expect(find.text('qwen-long-account-model'), findsOneWidget);
      expect(find.text('1.0k'), findsOneWidget);
      expect(find.text('2.0k'), findsOneWidget);
      expect(find.text('500'), findsOneWidget);
      expect(find.text('settings.context_note'.tr), findsOneWidget);

      await tester.tap(find.byKey(_toggleKey));
      await tester.pump();
      expect(find.text('settings.context_note'.tr), findsNothing);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('account replacement drops old values and resets disclosure', (
    tester,
  ) async {
    final previous = appServices.put(ContextStatsService());
    previous.record(
      modelName: 'previous-account-model',
      systemPromptChars: 350,
      userInputChars: 700,
      responseChars: 1050,
    );
    await _mount(tester);
    await tester.tap(find.byKey(_toggleKey));
    await tester.pump();
    expect(find.text('previous-account-model'), findsOneWidget);

    await appServices.delete<ContextStatsService>();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_panelKey), findsNothing);

    final current = appServices.put(ContextStatsService());
    await tester.pump();
    await tester.pump();
    expect(find.text('settings.context_no_conversations'.tr), findsOneWidget);
    expect(find.text('settings.context_note'.tr), findsNothing);
    expect(find.text('previous-account-model'), findsNothing);

    previous.record(
      modelName: 'stale-account-event',
      systemPromptChars: 99999,
      userInputChars: 99999,
      responseChars: 99999,
    );
    current.record(
      modelName: 'current-account-model',
      systemPromptChars: 35,
      userInputChars: 70,
      responseChars: 105,
    );
    await tester.pump();
    expect(find.text('60 / 128k'), findsOneWidget);
    await tester.tap(find.byKey(_toggleKey));
    await tester.pump();
    expect(find.text('current-account-model'), findsOneWidget);
    expect(find.text('stale-account-event'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'over-budget usage stays bounded without hiding actual estimate',
    (tester) async {
      final service = appServices.put(ContextStatsService());
      service.snapshot.value = ContextSnapshot(
        modelName: 'small-window-model',
        modelContextWindow: 100,
        systemPromptChars: 700,
        userInputChars: 350,
        responseChars: 350,
        turnCount: 5,
        updatedAt: DateTime.now().subtract(const Duration(minutes: 3)),
      );
      await _mount(tester, width: 320);

      expect(find.text('400 / 100'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      expect(
        tester.widget<LinearProgressIndicator>(find.byKey(_usageKey)).value,
        1,
      );
      expect(
        find.text(
          'settings.context_turn'.trParams({
            'turn': '5',
            'age': 'settings.context_age_minutes'.trParams({'count': '3'}),
          }),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final locale in ['en', 'zh']) {
      testWidgets('$locale $brightness: narrow large text remains readable', (
        tester,
      ) async {
        AppLocalization.updateLocale(Locale(locale));
        final service = appServices.put(ContextStatsService());
        service.record(
          modelName: 'qwen-long-custom-context-model-with-long-name',
          systemPromptChars: 35000,
          userInputChars: 17500,
          responseChars: 14000,
        );
        await _mount(tester, width: 320, scale: 2, brightness: brightness);
        await tester.tap(find.byKey(_toggleKey));
        await tester.pump();
        expect(find.text('settings.context_note'.tr), findsOneWidget);
        expect(tester.takeException(), isNull);
        final panel = tester.widget<Material>(find.byKey(_panelKey));
        expect(
          panel.color,
          MaasoGlassTheme.fromPalette(
            AppPalette.of(brightness, AppAccent.blue),
          ).muted,
        );
      });
    }
  }

  testWidgets('landscape and reduced motion support keyboard disclosure', (
    tester,
  ) async {
    appServices.put(ContextStatsService());
    await _mount(tester, width: 768, height: 375, reduceMotion: true);
    final toggle = find.byKey(_toggleKey);
    await tester.tap(toggle);
    await tester.pump();
    expect(find.text('settings.context_note'.tr), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('settings.context_note'.tr), findsNothing);
    final inkWell = tester.widget<InkWell>(toggle);
    expect(inkWell.splashFactory, NoSplash.splashFactory);
    expect(tester.takeException(), isNull);
  });
}

SemanticsData _toggleSemantics(WidgetTester tester) {
  final semantics = find.ancestor(
    of: find.byKey(_toggleKey),
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label == 'settings.context_title'.tr,
    ),
  );
  return tester.getSemantics(semantics.first).getSemanticsData();
}

Future<void> _mount(
  WidgetTester tester, {
  double width = 375,
  double height = 812,
  double scale = 1,
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(AppPalette.of(Brightness.light, AppAccent.blue)),
      darkTheme: AppTheme.build(AppPalette.of(Brightness.dark, AppAccent.blue)),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduceMotion,
        ),
        child: child!,
      ),
      home: const Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(20),
            child: SettingsContextPanel(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
