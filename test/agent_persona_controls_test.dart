import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/models/conversation_preference.dart';
import 'package:maaso/src/core/models/proactive_conversation_topic.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/notifications/proactive_category_persona_memory.dart';
import 'package:maaso/src/core/services/conversation_preference_service.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';
import 'package:maaso/src/features/relationship/presentation/conversation_preference_controls.dart';
import 'package:maaso/src/features/relationship/presentation/proactive_conversation_controls.dart';
import 'package:maaso/src/features/relationship/presentation/relationship_hub_page.dart';
import 'package:maaso/src/features/settings/application/agent_settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _account =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  late _ChatStore chatStore;
  late _ContactStore contactStore;
  late ConversationPreferenceService chat;
  late ProactivePreferenceService contact;
  late NotificationPreferencesService notifications;
  late _CategoryStore categoryStore;
  var settingsCreated = 0;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues({});
    chatStore = _ChatStore();
    contactStore = _ContactStore();
    chat = appServices.put(
      await ConversationPreferenceService(
        store: chatStore,
        accountScopeDigest: _account,
      ).init(),
    );
    contact = appServices.put(
      await ProactivePreferenceService(
        store: contactStore,
        accountScopeDigest: _account,
        generation: 1,
      ).init(),
    );
    categoryStore = _CategoryStore();
    notifications = appServices.put(
      await NotificationPreferencesService().init(),
    );
    await notifications.bindPersonaMemory(categoryStore);
    settingsCreated = 0;
    appServices.lazyPut<AgentSettingsController>(() {
      settingsCreated++;
      throw StateError('The persona must not initialize settings');
    });
  });
  tearDown(appServices.reset);

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(375, 812),
    double scale = 1,
    Locale locale = const Locale('zh'),
    Brightness brightness = Brightness.light,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    AppLocalization.updateLocale(locale);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(brightness: brightness),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: const RelationshipHubPage(
            initialSection: RelationshipHubSection.profile,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('relationship-agent-persona')),
      160,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'fresh accounts can choose companionship without invented memories',
    (tester) async {
      await mount(tester);
      final master = find.widgetWithText(SwitchListTile, '主动找我聊天');
      await tester.ensureVisible(master);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(master).value, isFalse);
      expect(tester.widget<SwitchListTile>(master).onChanged, isNotNull);
      expect(chatStore.writes, 0);
      expect(contactStore.writes, 0);
      expect(categoryStore.writes, 0);
      expect(contact.effectiveSnapshot.consentRecorded, isFalse);
      expect(contact.effectiveSnapshot.foregroundAllowed, isFalse);
      expect(contact.effectiveSnapshot.osOutreachAllowed, isFalse);
    },
  );

  testWidgets(
    'unavailable companionship stays visible with disabled controls',
    (tester) async {
      await tester.runAsync(() async {
        await appServices.delete<ProactivePreferenceService>(force: true);
        contactStore.failRead = true;
        contact = appServices.put(
          await ProactivePreferenceService(
            store: contactStore,
            accountScopeDigest: _account,
            generation: 2,
          ).init(),
        );
      });
      await mount(tester);
      final master = find.widgetWithText(SwitchListTile, '主动找我聊天');
      await tester.ensureVisible(master);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(master).value, isFalse);
      expect(tester.widget<SwitchListTile>(master).onChanged, isNull);
      expect(find.text('主动陪伴偏好暂不可用，目前保持关闭。请重新打开页面后重试。'), findsOneWidget);
      expect(contactStore.writes, 0);
      expect(categoryStore.writes, 0);
    },
  );

  testWidgets(
    'My Agent persona opens both existing preferences without rewriting choices',
    (tester) async {
      await tester.runAsync(() async {
        await chat.setHumorStyle(ConversationHumorStyle.lightBanter);
        await chat.setPreferredAddress('小林');
        await chat.setBanterBoundaries({'gaming': BanterDisposition.accepted});
        await contact.setContactScope(ProactiveConversationScope.everyday);
        await contact.setDailyBudget(2);
        await contact.setQuietHours(start: 21 * 60, end: 8 * 60);
        await contact.setHardMuted(true);
        await notifications.setGreetingsEnabled(false);
      });
      final writesBefore = (chatStore.writes, contactStore.writes);

      await mount(tester);
      expect(find.byType(ConversationPreferenceControls), findsOneWidget);
      expect(find.byType(ProactiveConversationControls), findsOneWidget);
      await tester.ensureVisible(find.text('小林'));
      expect(find.text('适度互损'), findsOneWidget);
      await tester.ensureVisible(find.text('21:00–08:00'));
      expect(find.text('21:00–08:00'), findsOneWidget);
      expect(contact.effectiveSnapshot.dailyBudget, 2);
      expect(
        contact.effectiveSnapshot.contactScope,
        ProactiveConversationScope.everyday,
      );
      expect(contact.effectiveSnapshot.hardMuted, isTrue);
      expect(notifications.state.value.greetingsEnabled, isFalse);
      expect((chatStore.writes, contactStore.writes), writesBefore);
      expect(settingsCreated, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'persona contact has one master switch and preserves notification permission and reminders',
    (tester) async {
      await tester.runAsync(() async {
        await contact.setHardMuted(true);
        await contact.setDailyBudget(2);
        await notifications.setScheduledTasksEnabled(false);
      });
      await mount(tester);
      final master = find.widgetWithText(SwitchListTile, '主动找我聊天');
      await tester.ensureVisible(master);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(master).value, isFalse);
      expect(
        find.text('settings.notifications_pause_proactive'.tr),
        findsNothing,
      );
      await tester.tap(master);
      await _settle(tester);
      expect(contact.effectiveSnapshot.hardMuted, isFalse);
      expect(contact.effectiveSnapshot.foregroundAllowed, isTrue);
      expect(contact.effectiveSnapshot.dailyBudget, 2);
      await tester.tap(master);
      await _settle(tester);
      expect(contact.effectiveSnapshot.hardMuted, isTrue);

      final greetings = find.widgetWithText(
        SwitchListTile,
        'settings.notifications_greetings'.tr,
      );
      await tester.ensureVisible(greetings);
      await tester.pumpAndSettle();
      await tester.tap(greetings);
      await _settle(tester);
      expect(notifications.state.value.greetingsEnabled, isFalse);
      expect(notifications.state.value.canNotify, isFalse);
      expect(notifications.state.value.scheduledTasksEnabled, isFalse);
      expect(settingsCreated, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('stale category controls cannot write the next account', (
    tester,
  ) async {
    await tester.runAsync(() => contact.setDailyBudget(2));
    await mount(tester);
    final greetings = find.widgetWithText(
      SwitchListTile,
      'settings.notifications_greetings'.tr,
    );
    await tester.ensureVisible(greetings);
    await tester.pumpAndSettle();
    final callback = tester.widget<SwitchListTile>(greetings).onChanged!;
    final nextAccount = _CategoryStore('b' * 64);
    await tester.runAsync(() => notifications.bindPersonaMemory(nextAccount));
    callback(false);
    await _settle(tester);
    expect(nextAccount.writes, 0);
    expect(notifications.state.value.greetingsEnabled, isTrue);
    expect(find.text('设置未保存，请重试。'), findsOneWidget);
  });

  testWidgets(
    'category bind failure disables its controls without changing consent',
    (tester) async {
      await tester.runAsync(() => contact.setDailyBudget(2));
      categoryStore.failRead = true;
      await tester.runAsync(
        () => notifications.bindPersonaMemory(categoryStore),
      );
      await mount(tester);
      final greetings = find.widgetWithText(
        SwitchListTile,
        'settings.notifications_greetings'.tr,
      );
      await tester.ensureVisible(greetings);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(greetings).onChanged, isNull);
      expect(notifications.state.value.canNotify, isFalse);
      expect(categoryStore.writes, 0);
      expect(find.text('主动问候偏好暂不可用，请重新打开页面后重试。'), findsOneWidget);
    },
  );

  testWidgets(
    'failed persona write leaves the saved category visible and reports failure',
    (tester) async {
      await tester.runAsync(() => contact.setDailyBudget(2));
      categoryStore.failWrite = true;
      await mount(tester);
      final greetings = find.widgetWithText(
        SwitchListTile,
        'settings.notifications_greetings'.tr,
      );
      await tester.ensureVisible(greetings);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(greetings).onChanged, isNotNull);
      await tester.tap(greetings);
      await _settle(tester);
      expect(notifications.state.value.greetingsEnabled, isTrue);
      expect(categoryStore.row, isNull);
      expect(find.text('设置未保存，请重试。'), findsOneWidget);
      expect(notifications.state.value.canNotify, isFalse);
    },
  );

  for (final layout in [
    (const Size(320, 667), const Locale('en'), Brightness.light),
    (const Size(375, 812), const Locale('zh'), Brightness.dark),
    (const Size(812, 375), const Locale('en'), Brightness.dark),
  ]) {
    testWidgets(
      'persona controls fit large text ${layout.$1} ${layout.$2} ${layout.$3}',
      (tester) async {
        await mount(
          tester,
          size: layout.$1,
          locale: layout.$2,
          brightness: layout.$3,
          scale: 2,
        );
        await tester.ensureVisible(find.byType(ProactiveConversationControls));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('persona-contact-quiet-hours')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  await tester.pumpAndSettle();
}

class _ChatStore implements ConversationPreferenceStore {
  Map<String, Object?>? row;
  int writes = 0;
  @override
  Future<Map<String, Object?>?> read() async => row;
  @override
  Future<void> write(ConversationPreferenceSnapshot value) async {
    writes++;
    row = value.toStorageJson();
  }
}

class _ContactStore implements ProactivePreferenceStore {
  Map<String, Object?>? row;
  int writes = 0;
  bool failRead = false;
  @override
  Future<Map<String, Object?>?> read() async {
    if (failRead) throw StateError('read failed');
    return row;
  }

  @override
  Future<void> write(ProactivePreferenceSnapshot value) async {
    writes++;
    row = value.toStorageJson();
  }
}

class _CategoryStore implements ProactiveCategoryPersonaMemoryStore {
  _CategoryStore([this.accountScopeDigest = _account]);
  @override
  final String accountScopeDigest;
  ProactiveCategoryPersonaMemory? row;
  int writes = 0;
  bool failRead = false;
  bool failWrite = false;
  @override
  Future<ProactiveCategoryPersonaMemory?> read() async {
    if (failRead) throw StateError('read failed');
    return row;
  }

  @override
  Future<void> write(ProactiveCategoryPersonaMemory value) async {
    if (failWrite) throw StateError('write failed');
    writes++;
    row = value;
  }
}
