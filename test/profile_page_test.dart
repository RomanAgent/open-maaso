import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/daily_token_usage_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/identity/application/profile_controller.dart';
import 'package:maaso/src/features/identity/application/profile_page_adapter.dart';
import 'package:maaso/src/features/identity/presentation/profile_page.dart';
import 'package:sembast/sembast_memory.dart';
import 'identity_test_support.dart';
import 'profile_membership_test_support.dart';

Widget profilePage(
  ProfileFixture f, {
  AgentUiControlService? control,
  double scale = 1,
  Brightness brightness = Brightness.light,
  DailyTokenUsageService? tokenUsage,
}) => ProviderScope(
  child: MaterialApp(
    theme: ThemeData(brightness: brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: child!,
    ),
    home: ProfilePage(
      controller: f.controller,
      route: '/profile',
      membershipRoute: '/membership',
      uiControl: control,
      tokenUsage: tokenUsage,
    ),
  ),
);

Future<void> revealProfileField(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(
    finder,
    180,
    scrollable: find.descendant(
      of: find.byKey(const ValueKey('profile-content-scroll')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);
  testWidgets('profile keeps daily usage and relationships without wallet UI', (
    tester,
  ) async {
    final f = ProfileFixture();
    addTearDown(f.close);
    await tester.pumpWidget(profilePage(f));
    await tester.pumpAndSettle();
    await revealProfileField(tester, 'profile-relationship-entry');
    final relationship = find.byKey(
      const ValueKey('profile-relationship-entry'),
    );
    expect(find.byKey(const ValueKey('profile-wallet-entry')), findsNothing);
    expect(find.text('Wallet'), findsNothing);
    expect(find.text('钱包'), findsNothing);
    expect(
      tester
          .getRect(find.byKey(const ValueKey('profile-daily-token-card')))
          .top,
      greaterThan(
        tester
            .getRect(find.byKey(const ValueKey('profile-membership-card')))
            .bottom,
      ),
    );
    expect(
      tester.getRect(relationship).top,
      greaterThan(
        tester
            .getRect(find.byKey(const ValueKey('profile-daily-token-card')))
            .bottom,
      ),
    );
    expect(tester.getSize(relationship).height, greaterThanOrEqualTo(48));
    expect(tester.widget<InkWell>(relationship).onTap, isNotNull);
    expect(find.text('Profile · Activity · Memories'), findsOneWidget);
    expect(f.identityGateway.writes, 0);
    expect(f.companionGateway.writes, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('retired profile keeps wallet UI absent', (tester) async {
    final f = ProfileFixture();
    addTearDown(f.close);
    await tester.pumpWidget(profilePage(f));
    await tester.pumpAndSettle();
    f.current = false;
    f.companion.onClose();
    await tester.pumpAndSettle();
    await revealProfileField(tester, 'profile-relationship-entry');
    expect(find.byKey(const ValueKey('profile-wallet-entry')), findsNothing);
    expect(find.text('Wallet'), findsNothing);
    expect(
      tester
          .widget<InkWell>(
            find.byKey(const ValueKey('profile-relationship-entry')),
          )
          .onTap,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'basic information keeps nickname without a public identity editor',
    (tester) async {
      final f = ProfileFixture();
      addTearDown(f.close);
      await tester.pumpWidget(profilePage(f));
      await tester.pumpAndSettle();
      await revealProfileField(tester, 'profile-nickname-edit');
      final nickname = find.byKey(const ValueKey('profile-nickname-edit'));
      expect(tester.widget<TextButton>(nickname).onPressed, isNotNull);
      expect(
        find.byKey(const ValueKey('profile-public-identity')),
        findsNothing,
      );
      expect(find.text('玩家与 Agent 公开身份'), findsNothing);
      expect(find.text('Player and Agent public identities'), findsNothing);
      expect(f.identityGateway.writes, 0);
      expect(f.companionGateway.writes, 0);
      f.current = false;
      f.companion.onClose();
      await tester.pumpAndSettle();
      expect(tester.widget<TextButton>(nickname).onPressed, isNull);
      expect(
        find.byKey(const ValueKey('profile-public-identity')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'real daily usage sits below membership, updates and hides on retirement',
    (tester) async {
      final f = ProfileFixture();
      addTearDown(f.close);
      final day = DateTime(2026, 10, 12, 12);
      final setup = await tester.runAsync(() async {
        final db = await databaseFactoryMemory.openDatabase('profile-usage');
        final usage = await DailyTokenUsageService(
          database: db,
          accountScopeDigest: 'account-a',
          isCurrent: () => f.current,
          now: () => day,
        ).init(observeLifecycle: false);
        return (db, usage);
      });
      final db = setup!.$1;
      final usage = setup.$2;
      addTearDown(db.close);
      addTearDown(usage.onClose);
      await tester.pumpWidget(profilePage(f, tokenUsage: usage));
      await tester.pumpAndSettle();
      final membership = tester.getRect(
        find.byKey(const ValueKey('profile-membership-card')),
      );
      final tokens = tester.getRect(
        find.byKey(const ValueKey('profile-daily-token-card')),
      );
      expect(tokens.top, greaterThan(membership.bottom));
      await tester.runAsync(
        () => usage.record(
          requestId: 'one',
          dispatchedAt: day,
          usage: const ReportedTokenUsage(input: 100, output: 40, total: 140),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('140'), findsOneWidget);
      expect(find.text('Input  100'), findsNothing);
      expect(find.text('Output  40'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('profile-daily-token-toggle')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Input  100'), findsOneWidget);
      expect(find.text('Output  40'), findsOneWidget);
      f.current = false;
      f.companion.onClose();
      await tester.pumpAndSettle();
      expect(find.text('140'), findsNothing);
      expect(find.text('Input  100'), findsNothing);
      expect(find.text('Output  40'), findsNothing);
      expect(
        find.byKey(const ValueKey('profile-daily-token-details')),
        findsNothing,
      );
      expect(find.text('This device · Unavailable'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'profile writes one explicit field and never rewrites Agent choices',
    () async {
      final f = ProfileFixture();
      addTearDown(f.close);
      await f.controller.refresh();
      expect(f.controller.prepareNickname('New name'), isTrue);
      expect(f.identityGateway.writes, 0);
      expect(await f.controller.save(), isTrue);
      expect(f.identityGateway.stored.playerName, 'New name');
      expect(f.identityGateway.stored.agentName, 'Wheat');
      expect(f.companionGateway.writes, 0);
      expect(f.controller.prepareInterests(['travel', 'books']), isTrue);
      expect(await f.controller.save(), isTrue);
      expect(f.companionGateway.value.interests, ['travel', 'books']);
      expect(f.companionGateway.value.agentGender, 'female');
      expect(f.companionGateway.value.avatarPreset, 'star');
      expect(f.identityGateway.writes, 1);
    },
  );
  test(
    'invalid or stale drafts fail closed and retain explicit input',
    () async {
      final f = ProfileFixture();
      addTearDown(f.close);
      await f.controller.refresh();
      expect(f.controller.prepareNickname('\u0001'), isFalse);
      expect(
        f.controller.prepareInterests(['private inferred detail']),
        isFalse,
      );
      expect(f.controller.prepareInterests(['music', 'music']), isFalse);
      expect(f.controller.prepareInterests(['travel']), isTrue);
      f.companionGateway.value = f.companionGateway.value.copyWith(
        version: 2,
        interests: ['books'],
      );
      await f.companion.refresh();
      expect(await f.controller.save(), isFalse);
      expect(f.controller.issue.value, 'conflict');
      expect(f.controller.draft.value!.interests, ['travel']);
      expect(f.companionGateway.writes, 0);
      f.controller.cancelEdit();
      expect(f.controller.beginEdit(ProfileEditField.avatar), isTrue);
      f.controller.setAvatarPreset('moon');
      f.current = false;
      expect(await f.controller.save(), isFalse);
      expect(f.companionGateway.writes, 0);
    },
  );
  testWidgets(
    'nickname save requires the visible human button and closes on success',
    (tester) async {
      final f = ProfileFixture();
      addTearDown(f.close);
      await tester.pumpWidget(profilePage(f));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('profile-player-name')), findsOneWidget);
      final nickname = find.byKey(const ValueKey('profile-nickname-edit'));
      expect(nickname, findsOneWidget);
      expect(tester.widget<TextButton>(nickname).onPressed, isNotNull);
      expect(find.text('Edit nickname'), findsOneWidget);
      expect(find.text('Nickname'), findsNothing);
      final avatar = tester.getRect(
        find.byKey(const ValueKey('profile-avatar-edit')),
      );
      expect(tester.getRect(nickname).left, greaterThan(avatar.right));
      expect(tester.getRect(nickname).top, lessThan(avatar.bottom));
      expect(tester.getSize(nickname).height, greaterThanOrEqualTo(48));
      await tester.tap(nickname);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('profile-nickname-input')),
        'Sky',
      );
      expect(f.identityGateway.writes, 0);
      await tester.tap(find.byKey(const ValueKey('profile-human-save')));
      await tester.pumpAndSettle();
      expect(f.identityGateway.stored.playerName, 'Sky');
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('failed profile save keeps the same editor draft for retry', (
    tester,
  ) async {
    final f = ProfileFixture();
    f.companionGateway.fail = true;
    addTearDown(f.close);
    await tester.pumpWidget(profilePage(f));
    await tester.pumpAndSettle();
    await revealProfileField(tester, 'profile-interests-edit');
    await tester.tap(find.byKey(const ValueKey('profile-interests-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profile-interest-travel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profile-human-save')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(f.controller.draft.value!.interests, contains('travel'));
    f.companionGateway.fail = false;
    await tester.tap(find.byKey(const ValueKey('profile-human-save')));
    await tester.pumpAndSettle();
    expect(f.companionGateway.value.interests, contains('travel'));
  });
  testWidgets(
    'AppControl only opens a visible draft and yields to user takeover',
    (tester) async {
      final f = ProfileFixture();
      final control = AgentUiControlService();
      addTearDown(f.close);
      addTearDown(control.onClose);
      await tester.pumpWidget(profilePage(f, control: control));
      await tester.pumpAndSettle();
      final lease = control.coordinator
          .begin(
            sessionId: 'profile-test',
            purpose: 'Prepare nickname',
            targetRoute: '/profile',
          )
          .value!;
      final adapter = control.adapters
          .resolve<ProfilePageAdapter>(route: '/profile', lease: lease)
          .value!;
      final execution = AppControlActionExecutionContext.host(
        requiresCommit: false,
        authorityIsCurrent: () => true,
        staleCode: 'stale',
      );
      expect(adapter.actionById('save'), isNull);
      expect(adapter.actionById('upload'), isNull);
      final result = await adapter.executeAppControlAction(
        lease: lease,
        actionId: ProfilePageAdapter.nicknameAction,
        arguments: {'nickname': 'Orbit'},
        executionContext: execution,
      );
      expect(result.value, {'prepared': true, 'saved': false});
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('profile-nickname-input')),
        findsOneWidget,
      );
      expect(f.identityGateway.writes, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        (await adapter.executeAppControlAction(
          lease: lease,
          actionId: ProfilePageAdapter.nicknameAction,
          arguments: {'nickname': 'Again'},
          executionContext: execution,
        )).isSuccess,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(control.adapters.length, 0);
      expect(
        (await adapter.executeAppControlAction(
          lease: lease,
          actionId: ProfilePageAdapter.interestsAction,
          arguments: {
            'interests': ['music'],
          },
          executionContext: execution,
        )).isSuccess,
        isFalse,
      );
    },
  );
  testWidgets('keyboard usage disclosure pauses Agent control', (tester) async {
    final f = ProfileFixture();
    final control = AgentUiControlService();
    addTearDown(f.close);
    addTearDown(control.onClose);
    await tester.pumpWidget(profilePage(f, control: control));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('profile-daily-token-toggle'));
    await tester.ensureVisible(toggle);
    var focusedToggle = false;
    for (var step = 0; step < 10 && !focusedToggle; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
        element,
      ) {
        focusedToggle = identical(element, tester.element(toggle));
        return !focusedToggle;
      });
    }
    expect(focusedToggle, isTrue);
    expect(
      control.coordinator
          .begin(
            sessionId: 'profile-keyboard-test',
            purpose: 'Read profile',
            targetRoute: '/profile',
          )
          .isSuccess,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('profile-daily-token-details')),
      findsOneWidget,
    );
    expect(
      control.coordinator.snapshot.phase,
      AgentUiControlPhase.pausedByUser,
    );
    expect(control.coordinator.snapshot.pauseReason, 'profile_user_control');
    expect(f.identityGateway.writes, 0);
    expect(f.companionGateway.writes, 0);
  });
  testWidgets(
    'retired account hides profile and disables an already-open save',
    (tester) async {
      final f = ProfileFixture();
      addTearDown(f.close);
      await tester.pumpWidget(profilePage(f));
      await tester.pumpAndSettle();
      await revealProfileField(tester, 'profile-nickname-edit');
      await tester.tap(find.byKey(const ValueKey('profile-nickname-edit')));
      await tester.pumpAndSettle();
      f.companion.onClose();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('profile-nickname-input')),
        findsNothing,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('profile-human-save')),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('Star'), findsNothing);
    },
  );
  for (final fixture in [
    (const Size(320, 700), 2.0, Brightness.light),
    (const Size(812, 375), 2.0, Brightness.dark),
    (const Size(1024, 768), 1.0, Brightness.light),
  ]) {
    testWidgets('profile responsive ${fixture.$1} scale ${fixture.$2}', (
      tester,
    ) async {
      tester.view.physicalSize = fixture.$1;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = ProfileFixture();
      f.identityGateway.stored = identityFixture(
        player: 'Alexandra with a long display name',
      );
      f.companionGateway.value = f.companionGateway.value.copyWith(
        interests: [
          'music',
          'gaming',
          'travel',
          'fitness',
          'books',
          'art',
          'technology',
          'food',
          'nature',
          'movies',
        ],
      );
      addTearDown(f.close);
      await tester.pumpWidget(
        profilePage(f, scale: fixture.$2, brightness: fixture.$3),
      );
      await tester.pumpAndSettle();
      await revealProfileField(tester, 'profile-daily-token-toggle');
      await tester.tap(
        find.byKey(const ValueKey('profile-daily-token-toggle')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('profile-daily-token-details')),
        findsOneWidget,
      );
      await revealProfileField(tester, 'profile-interests-edit');
      await tester.tap(find.byKey(const ValueKey('profile-interests-edit')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
