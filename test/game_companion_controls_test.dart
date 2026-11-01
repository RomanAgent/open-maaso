import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/voice_input_retirement.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/features/agent/application/companion/companion_browsing_context_service.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/widgets_hub/application/game_companion_context.dart';
import 'package:maaso/src/features/widgets_hub/application/game_perception_coordinator.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_companion.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_companion_controls.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/agent_sound_platforms.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(installAgentSoundPlatforms);
  final services = <GameVoiceCompanionService>[];
  late bool previousSound;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    services.clear();
    previousSound = MaasoTtsPlugin.soundEnabled.value;
    SharedPreferences.setMockInitialValues({});
    await MaasoTtsPlugin.loadSoundPreference();
    await MaasoTtsPlugin.stopAllStrict();
    MaasoTtsPlugin.soundEnabled.value = true;
    voiceInputRetirementCoordinator.clearVoiceSessionIntent();
  });
  tearDown(() async {
    await appServices.reset();
    for (final service in services) {
      if (!service.isClosed) service.closeLifecycle();
    }
    await MaasoTtsPlugin.setSoundEnabled(previousSound);
    voiceInputRetirementCoordinator.clearVoiceSessionIntent();
    AppLocalization.updateLocale(const Locale('en'));
  });

  GameVoiceCompanionService register({
    bool capture = true,
    bool replace = false,
  }) {
    final context = appServices.put(CompanionBrowsingContextService());
    final service = GameVoiceCompanionService(
      browsingContext: context,
      commentary: (_, {required isCurrent, required onRevoked}) async => false,
    );
    services.add(service);
    appServices.put<GameVoiceCompanionService>(
      service,
      overrideAbstract: replace,
    );
    service.openSession(
      scopeKey: AppletLocalOwnership.currentScopeKey(),
      playerId: 'game',
      title: 'Current game',
      summary: 'A freely authored game',
      isCurrent: () => true,
      captureScreenshot: capture ? () async => null : null,
      isCaptureSupported: () => capture,
    );
    return service;
  }

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(430, 932),
    double scale = 1,
    Locale locale = const Locale('en'),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
    AppLocalization.updateLocale(locale);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: AppTheme.build(AppPalette.of(Brightness.light, AppAccent.blue)),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const Scaffold(
          body: Center(child: GameCompanionControlsButton()),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('game-companion-controls')));
    await tester.pumpAndSettle();
    expect(find.byType(GameCompanionControlsSheet), findsOneWidget);
  }

  Finder toggle(String key) => find.widgetWithText(SwitchListTile, key.tr);
  Finder choice(String key) => find.widgetWithText(ChoiceChip, key.tr);
  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(320, 700),
    const Size(430, 932),
    const Size(844, 390),
  ]) {
    for (final locale in [const Locale('en'), const Locale('zh')]) {
      testWidgets(
        'controls fit ${size.width}x${size.height} at text scale 2 (${locale.languageCode})',
        (tester) async {
          register();
          await mount(tester, size: size, scale: 2, locale: locale);
          await tester.ensureVisible(choice('game_companion.hints.smallHints'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(toggle('game_companion.vision'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final sheet = tester.getRect(find.byType(GameCompanionControlsSheet));
          expect(sheet.left, greaterThanOrEqualTo(0));
          expect(sheet.right, lessThanOrEqualTo(size.width));
        },
      );
    }
  }

  testWidgets(
    'microphone, spoken replies, frequency and hints remain independent',
    (tester) async {
      final service = register();
      await mount(tester);
      await tap(tester, toggle('game_companion.microphone'));
      expect(service.microphoneRequested, isTrue);
      expect(MaasoTtsPlugin.soundEnabled.value, isTrue);
      final soundChange = tester
          .widget<SwitchListTile>(toggle('game_companion.sound'))
          .onChanged!;
      soundChange(false);
      await tester.pumpAndSettle();
      expect(service.spokenRepliesEnabled, isFalse);
      expect(MaasoTtsPlugin.soundEnabled.value, isTrue);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          MaasoTtsPlugin.soundPreferenceKey,
        ),
        isNull,
      );
      expect(service.microphoneRequested, isTrue);
      await tap(tester, choice('game_companion.frequency.chatty'));
      await tap(tester, choice('game_companion.hints.askFirst'));
      expect(
        service.preferences.talkativeness,
        GameCompanionTalkativeness.chatty,
      );
      expect(service.preferences.hintPolicy, GameCompanionHintPolicy.askFirst);
      await tap(tester, toggle('game_companion.vision'));
      expect(service.visualEnabled, isTrue);
      await tap(tester, toggle('game_companion.enabled'));
      expect(service.preferences.enabled, isFalse);
      expect(service.microphoneRequested, isTrue);
      expect(service.spokenRepliesEnabled, isFalse);
      expect(MaasoTtsPlugin.soundEnabled.value, isTrue);
      expect(
        tester
            .widget<SwitchListTile>(toggle('game_companion.microphone'))
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<ChoiceChip>(choice('game_companion.frequency.chatty'))
            .onSelected,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('game voice defaults on without changing ordinary chat mute', (
    tester,
  ) async {
    await tester.runAsync(() => MaasoTtsPlugin.setSoundEnabled(false));
    final service = register();
    await mount(tester);
    expect(
      tester.widget<SwitchListTile>(toggle('game_companion.sound')).value,
      isTrue,
    );
    expect(service.currentSession!.spokenRepliesEnabled, isTrue);
    await tap(tester, toggle('game_companion.sound'));
    expect(service.spokenRepliesEnabled, isFalse);
    await tap(tester, toggle('game_companion.sound'));
    expect(service.spokenRepliesEnabled, isTrue);
    expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        MaasoTtsPlugin.soundPreferenceKey,
      ),
      isFalse,
    );
  });

  testWidgets(
    'unsupported visual capture does not disable ordinary companionship',
    (tester) async {
      final service = register(capture: false);
      await mount(tester);
      final visual = tester.widget<SwitchListTile>(
        toggle('game_companion.vision'),
      );
      expect(visual.onChanged, isNull);
      expect(find.text('game_companion.vision_unsupported'.tr), findsOneWidget);
      expect(service.visualEnabled, isFalse);
      expect(
        tester
            .widget<SwitchListTile>(toggle('game_companion.microphone'))
            .onChanged,
        isNotNull,
      );
      await tap(tester, choice('game_companion.frequency.quiet'));
      expect(
        service.preferences.talkativeness,
        GameCompanionTalkativeness.quiet,
      );
      expect(service.preferences.enabled, isTrue);
    },
  );

  testWidgets(
    'captured choices preserve newer settings before the sheet rebuilds',
    (tester) async {
      final service = register();
      await mount(tester);
      final frequency = tester
          .widget<ChoiceChip>(choice('game_companion.frequency.chatty'))
          .onSelected!;
      final hints = tester
          .widget<ChoiceChip>(choice('game_companion.hints.smallHints'))
          .onSelected!;
      frequency(true);
      hints(true);
      await tester.pumpAndSettle();
      expect(
        service.preferences.talkativeness,
        GameCompanionTalkativeness.chatty,
      );
      expect(
        service.preferences.hintPolicy,
        GameCompanionHintPolicy.smallHints,
      );
    },
  );

  for (final locale in [const Locale('en'), const Locale('zh')]) {
    testWidgets(
      '${locale.languageCode}: membership is advertised without assuming premium access',
      (tester) async {
        register();
        await mount(tester, locale: locale);
        expect(find.text('game_companion.vision_hint'.tr), findsOneWidget);
        expect(
          find.text('game_companion.vision_status.membershipRequired'.tr),
          findsNothing,
        );
        expect(
          find.text('game_companion.vision_status.premiumRequired'.tr),
          findsNothing,
        );
        expect(
          tester
              .widget<SwitchListTile>(toggle('game_companion.vision'))
              .onChanged,
          isNotNull,
          reason:
              'Only the server decides entitlement; the client does not guess a tier.',
        );
      },
    );
    for (final status in [
      GamePerceptionStatus.membershipRequired,
      GamePerceptionStatus.premiumRequired,
    ]) {
      testWidgets(
        '${locale.languageCode}: ${status.name} reflects server denial and keeps chat available',
        (tester) async {
          final service = register();
          service.setVisualEnabled(true);
          service.currentSession!.updatePerceptionStatus(status);
          await mount(
            tester,
            locale: locale,
            size: const Size(320, 700),
            scale: 2,
          );
          final message = find.text(
            'game_companion.vision_status.${status.name}'.tr,
          );
          expect(message, findsOneWidget);
          await tester.ensureVisible(message);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(service.preferences.enabled, isTrue);
          expect(
            tester
                .widget<SwitchListTile>(toggle('game_companion.microphone'))
                .onChanged,
            isNotNull,
          );
          expect(
            tester
                .widget<SwitchListTile>(toggle('game_companion.sound'))
                .onChanged,
            isNotNull,
          );
          expect(
            tester
                .widget<SwitchListTile>(toggle('game_companion.vision'))
                .onChanged,
            isNotNull,
            reason:
                'Users can turn visual understanding off and on to revalidate after upgrading.',
          );
          service.currentSession!.updatePerceptionStatus(
            GamePerceptionStatus.observing,
          );
          await tester.pumpAndSettle();
          expect(message, findsNothing);
        },
      );
    }
  }

  testWidgets(
    'old account callbacks cannot mutate either the replacement or global sound',
    (tester) async {
      final previous = register();
      await mount(tester);
      final enabled = tester
          .widget<SwitchListTile>(toggle('game_companion.enabled'))
          .onChanged!;
      final microphone = tester
          .widget<SwitchListTile>(toggle('game_companion.microphone'))
          .onChanged!;
      final sound = tester
          .widget<SwitchListTile>(toggle('game_companion.sound'))
          .onChanged!;
      final vision = tester
          .widget<SwitchListTile>(toggle('game_companion.vision'))
          .onChanged!;
      final frequency = tester
          .widget<ChoiceChip>(choice('game_companion.frequency.chatty'))
          .onSelected!;
      final hints = tester
          .widget<ChoiceChip>(choice('game_companion.hints.smallHints'))
          .onSelected!;
      final next = register(replace: true);
      enabled(false);
      microphone(true);
      sound(false);
      vision(true);
      frequency(true);
      hints(true);
      await tester.pumpAndSettle();
      expect(next.preferences.enabled, isTrue);
      expect(
        next.preferences.talkativeness,
        GameCompanionTalkativeness.balanced,
      );
      expect(next.preferences.hintPolicy, GameCompanionHintPolicy.onRequest);
      expect(next.microphoneRequested, isNull);
      expect(next.visualEnabled, isFalse);
      expect(previous.preferences.enabled, isTrue);
      expect(previous.preferences.revision, 0);
      expect(previous.microphoneRequested, isNull);
      expect(previous.visualEnabled, isFalse);
      expect(MaasoTtsPlugin.soundEnabled.value, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
