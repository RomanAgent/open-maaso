import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/features/identity/application/companion_profile_service.dart';
import 'package:maaso/src/features/identity/application/companion_setup_controller.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/application/identity_setup_controller.dart';
import 'package:maaso/src/features/identity/application/identity_route_policy.dart';
import 'package:maaso/src/features/identity/data/companion_profile_store.dart';
import 'package:maaso/src/features/identity/domain/companion_profile.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';
import 'package:maaso/src/features/identity/presentation/identity_setup_page.dart';

import 'identity_test_support.dart';

class _Store implements CompanionProfileStore {
  CompanionProfile? value;
  @override
  Future<CompanionProfile?> read() async => value;
  @override
  Future<void> write(CompanionProfile profile) async => value = profile;
}

class _Gateway implements CompanionProfileGateway {
  CompanionProfile value = CompanionProfile();
  int writes = 0;
  bool fail = false;
  @override
  String requestContextKey = 'test|account';
  @override
  Future<CompanionProfile> fetch({required String expectedContextKey}) async =>
      value;
  @override
  Future<CompanionProfile> update({
    required String expectedContextKey,
    required CompanionProfile profile,
  }) async {
    writes++;
    if (fail) {
      throw const CompanionProfileException(
        CompanionProfileFailure.unavailable,
      );
    }
    return value = profile.copyWith(version: profile.version + 1);
  }
}

class _Harness {
  _Harness({bool knownNames = true, bool knownCompanion = false}) {
    names = FakeIdentityGateway(initial: knownNames ? identityFixture() : null);
    identity = IdentityService(gateway: names);
    controller = IdentitySetupController(service: identity);
    profile = CompanionProfileService(
      gateway: gateway,
      store: _Store(),
      isCurrent: () => true,
    );
    if (knownCompanion) {
      gateway.value = CompanionProfile(
        version: 3,
        avatarPreset: 'moon',
        agentGender: 'nonbinary',
        interests: ['music'],
        onboardingVersion: 1,
      );
    }
    companion = CompanionSetupController(service: profile, avatars: avatars);
  }
  final gateway = _Gateway();
  final avatars = AvatarConfigService();
  late final FakeIdentityGateway names;
  late final IdentityService identity;
  late final IdentitySetupController controller;
  late final CompanionProfileService profile;
  late final CompanionSetupController companion;
  int completed = 0;
  Future<void> mount(WidgetTester tester, {double scale = 1}) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: IdentitySetupPage(
            route: '/onboarding',
            autoComplete: true,
            controller: controller,
            companion: companion,
            onCompleted: (_) async => completed++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    companion.onClose();
    controller.onClose();
    identity.onClose();
    await profile.shutdown();
    avatars.onClose();
  }
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  test(
    'route policy waits for companion setup but keeps account pages reachable',
    () async {
      final h = _Harness();
      appServices.put<IdentityService>(h.identity);
      appServices.put<CompanionProfileService>(h.profile);
      await h.identity.load();
      expect(h.identity.onboardingCompleted, isTrue);
      expect(IdentityRoutePolicy.initialRoute(), AppRouteCatalog.onboarding);
      expect(
        IdentityRoutePolicy.redirect(AppRouteCatalog.home),
        AppRouteCatalog.onboarding,
      );
      for (final route in [
        AppRouteCatalog.profile,
        AppRouteCatalog.membership,
      ]) {
        expect(IdentityRoutePolicy.redirect(route), isNull);
      }
      expect(
        IdentityRoutePolicy.redirect('/wallet'),
        AppRouteCatalog.onboarding,
        reason: 'The retired path has no account-read setup exemption.',
      );
      await h.profile.refresh();
      expect(IdentityRoutePolicy.initialRoute(), AppRouteCatalog.onboarding);
      await h.profile.save(
        CompanionProfile(
          avatarPreset: 'star',
          agentGender: 'female',
          onboardingVersion: 1,
        ),
      );
      expect(IdentityRoutePolicy.initialRoute(), AppRouteCatalog.home);
      expect(IdentityRoutePolicy.redirect(AppRouteCatalog.gameFeed), isNull);
      h.controller.onClose();
      h.companion.onClose();
      h.avatars.onClose();
      await h.profile.shutdown();
    },
  );

  test(
    'explicit local fallback retains private access without cloud setup',
    () async {
      final gateway = FakeIdentityGateway()
        ..fetchOverride = () async =>
            throw const IdentityException(IdentityFailure.unavailable);
      final identity = appServices.put(
        IdentityService(gateway: gateway, hasLocalCompanion: () => true),
      );
      final companion = appServices.put(
        CompanionProfileService(
          gateway: _Gateway(),
          store: _Store(),
          isCurrent: () => true,
        ),
      );
      await expectLater(identity.load(), throwsA(isA<IdentityException>()));
      expect(identity.continueLocally(), isTrue);
      expect(IdentityRoutePolicy.initialRoute(), AppRouteCatalog.home);
      expect(IdentityRoutePolicy.redirect(AppRouteCatalog.home), isNull);
      expect(
        IdentityRoutePolicy.redirect(AppRouteCatalog.gameFeed),
        AppRouteCatalog.onboarding,
      );
      await companion.shutdown();
    },
  );

  testWidgets('existing identity completes only missing companion choices', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    expect(find.text('Step 3 of 6'), findsOneWidget);
    expect(h.completed, 0);
    await _tap(tester, 'companion-avatar-star');
    await _tap(tester, 'identity-guide-next');
    expect(find.text('Step 4 of 6'), findsOneWidget);
    await _tap(tester, 'companion-gender-nonbinary');
    await _tap(tester, 'identity-guide-next');
    await _tap(tester, 'companion-interest-music');
    await _tap(tester, 'companion-interest-gaming');
    await _tap(tester, 'identity-guide-next');
    expect(find.text('Step 6 of 6'), findsOneWidget);
    await _tap(tester, 'identity-save');
    expect(h.names.writes, 0);
    expect(h.gateway.writes, 1);
    expect(h.gateway.value.avatarPreset, 'star');
    expect(h.gateway.value.agentGender, 'nonbinary');
    expect(h.gateway.value.interests, ['music', 'gaming']);
    expect(h.completed, 1);
    expect(tester.takeException(), isNull);
    await h.close(tester);
  });

  testWidgets('a new user saves names before creating a companion', (
    tester,
  ) async {
    final h = _Harness(knownNames: false);
    await h.mount(tester);
    expect(find.text('Step 1 of 6'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('identity-player-name')),
      'Nova',
    );
    await _tap(tester, 'identity-guide-next');
    await tester.enterText(
      find.byKey(const ValueKey('identity-agent-name')),
      'Tina',
    );
    await _tap(tester, 'identity-guide-next');
    await _tap(tester, 'companion-avatar-leaf');
    await _tap(tester, 'identity-guide-next');
    await _tap(tester, 'companion-gender-female');
    await _tap(tester, 'identity-guide-next');
    await _tap(tester, 'identity-guide-next');
    h.gateway.fail = true;
    await _tap(tester, 'identity-save');
    expect(h.completed, 0);
    expect(h.names.writes, 1);
    expect(h.companion.draft.value!.avatarPreset, 'leaf');
    h.gateway.fail = false;
    await _tap(tester, 'identity-save');
    expect(h.completed, 1);
    expect(h.names.writes, 1);
    expect(h.gateway.value.interests, isEmpty);
    await h.close(tester);
  });

  testWidgets('a synchronized complete profile skips repeat onboarding', (
    tester,
  ) async {
    final h = _Harness(knownCompanion: true);
    await h.mount(tester);
    expect(h.completed, 1);
    expect(h.names.writes, 0);
    expect(h.gateway.writes, 0);
    expect(h.companion.draft.value!.agentGender, 'nonbinary');
    await h.close(tester);
  });

  testWidgets('avatar and gender remain reachable with large landscape text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(812, 375));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final h = _Harness();
    await h.mount(tester, scale: 2);
    await _tap(tester, 'companion-avatar-moon');
    await _tap(tester, 'identity-guide-next');
    await _tap(tester, 'companion-gender-male');
    await _tap(tester, 'identity-guide-next');
    await _tap(tester, 'companion-interest-travel');
    await _tap(tester, 'identity-guide-next');
    await _tap(tester, 'identity-save');
    expect(h.completed, 1);
    expect(tester.takeException(), isNull);
    await h.close(tester);
  });

  test('choices ignore early taps before the account profile is loaded', () {
    final h = _Harness();
    h.companion.setAvatarPreset('star');
    h.companion.setGender('female');
    h.companion.toggleInterest('music');
    expect(h.companion.draft.value, isNull);
    h.companion.onClose();
    h.controller.onClose();
    h.identity.onClose();
    h.avatars.onClose();
    return h.profile.shutdown();
  });
}
