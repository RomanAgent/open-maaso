import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_transport.dart';
import 'package:maaso/src/features/auth/application/login_controller.dart';
import 'package:maaso/src/features/auth/application/login_doorway_coordinator.dart';
import 'package:maaso/src/features/auth/presentation/login_page.dart';

const _captureKey = ValueKey<String>('login-backdrop-capture');
const _nativeBackdrop = Color(0xFF080808);

void main() {
  late _PresentationLifecycle lifecycle;
  late LoginController login;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('en', 'US'));
    appServices.put<SecureStorageService>(_MemoryStorage());
    final environment = appServices.put(AppEnvironmentService());
    await environment.init();
    final auth = appServices.put(AuthSessionService());
    lifecycle = _PresentationLifecycle(auth: auth, environment: environment);
    appServices.put<AccountSessionLifecycleService>(lifecycle);
    login = appServices.put(LoginController());
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await appServices.reset();
  });

  for (final platform in [
    TargetPlatform.iOS,
    TargetPlatform.android,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    testWidgets(
      '${platform.name} offline doorway keeps login usable without a renderer',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        await _pumpLogin(tester);
        expect(
          find.byKey(const ValueKey('login-doorway-artwork')),
          findsOneWidget,
        );
        expect(find.byType(UnityAvatarView), findsNothing);
        expect(find.byType(TextField), findsNWidgets(2));
        expect(
          tester
              .widget<AutofillGroup>(find.byType(AutofillGroup))
              .onDisposeAction,
          AutofillContextAction.cancel,
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey('login-doorway-artwork')))
              .height,
          closeTo(852 * .48, .1),
        );
        expect(find.text('Privacy & permissions'), findsOneWidget);
        await _disposePage(tester);
      },
    );
    testWidgets(
      '${platform.name} renderer readiness never exposes an account avatar in login',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final wire = _AvatarWire();
        final unity = appServices.put(UnityAvatarRuntime(transport: wire));
        appServices.put(ActiveAvatarRuntime()..register(unity));
        await _pumpLogin(tester);
        login.email.text = 'kept@example.com';
        unity.isReady.value = true;
        lifecycle.phase.value = AccountSessionLifecyclePhase.mounted;
        await tester.pump();
        expect(find.byType(UnityAvatarView), findsNothing);
        expect(wire.calls, isEmpty);
        lifecycle.phase.value = AccountSessionLifecyclePhase.faulted;
        await tester.pump();
        expect(find.byType(UnityAvatarView), findsNothing);
        expect(login.email.text, 'kept@example.com');
        expect(login.canRetryCredentialCleanup.value, isTrue);
        await tester.ensureVisible(find.text('Retry'));
        expect(find.text('Retry').hitTestable(), findsOneWidget);
        await _disposePage(tester);
      },
    );
    testWidgets('${platform.name} shares the mobile login controls and fade', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      await _pumpLogin(tester);
      await tester.enterText(find.byType(TextField).first, 'kept@example.com');
      await tester.enterText(find.byType(TextField).last, 'kept-password');
      await tester.tap(find.byTooltip('auth.show_password'.tr));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField).last).obscureText,
        isFalse,
      );
      final form = find.byKey(const ValueKey('login-form-exit'));
      final button = find.byType(FilledButton);
      final idleButtonRect = tester.getRect(button);
      final posterRect = tester.getRect(
        find.byKey(const ValueKey('login-doorway-artwork')),
      );
      login.isLoading.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester.getCenter(button).dy,
        closeTo(tester.getRect(form).center.dy, 2),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('login-email-visibility')),
            )
            .opacity,
        0,
      );
      expect(find.text('Privacy & permissions').hitTestable(), findsNothing);
      expect(
        tester.getRect(find.byKey(const ValueKey('login-doorway-artwork'))),
        posterRect,
      );
      login.isLoading.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getRect(button), idleButtonRect);
      expect(login.email.text, 'kept@example.com');
      expect(login.password.text, 'kept-password');
      await tester.tap(find.text('auth.switch_to_signup'.tr));
      await tester.pump();
      expect(find.byType(TextField), findsNWidgets(3));
      expect(find.byTooltip('auth.send_code'.tr), findsOneWidget);
      expect(find.text('Privacy & permissions').hitTestable(), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(tester.takeException(), isNull);
      await _disposePage(tester);
    });
  }
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
      '$brightness recovery error remains readable below the doorway',
      (tester) async {
        lifecycle.phase.value = AccountSessionLifecyclePhase.faulted;
        await _pumpLogin(tester, brightness: brightness);
        final message = tester.widget<Text>(
          find.text('common.request_failed'.tr),
        );
        final feedback = tester.widget<DecoratedBox>(
          find.byKey(const ValueKey('login-feedback-background')),
        );
        expect(
          _contrast(
            message.style!.color!,
            (feedback.decoration as BoxDecoration).color!,
          ),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          await _backgroundPixel(tester),
          AppPalette.of(brightness, AppAccent.blue).background,
        );
        await _disposePage(tester);
      },
    );
  }
  testWidgets(
    'doorway preserves registration, sign in and privacy navigation',
    (tester) async {
      await _pumpLogin(tester);
      await tester.ensureVisible(find.text('auth.switch_to_signup'.tr));
      await tester.tap(find.text('auth.switch_to_signup'.tr));
      await tester.pump();
      expect(login.isSignupMode.value, isTrue);
      expect(find.byType(TextField), findsNWidgets(3));
      await tester.ensureVisible(find.text('auth.switch_to_login'.tr));
      await tester.tap(find.text('auth.switch_to_login'.tr));
      await tester.pump();
      expect(login.isSignupMode.value, isFalse);
      expect(find.byType(TextField), findsNWidgets(2));
      await tester.ensureVisible(find.text('Privacy & permissions'));
      await tester.tap(find.text('Privacy & permissions'));
      await tester.pumpAndSettle();
      expect(find.text('Privacy destination'), findsOneWidget);
      await _disposePage(tester);
    },
  );
  testWidgets(
    'unrecoverable credential failure still requires sign in without false cleanup retry',
    (tester) async {
      lifecycle.error.value = AuthCredentialCleanupFailure(
        cause: AuthCredentialReauthenticationRequired(),
        causeStackTrace: StackTrace.current,
        environment: MaasoEnvironment.test,
        operationEpoch: 0,
      );
      lifecycle.phase.value = AccountSessionLifecyclePhase.faulted;
      await _pumpLogin(tester);
      expect(
        find.text('auth.session_reauthentication_required'.tr),
        findsOneWidget,
      );
      expect(login.canRetryCredentialCleanup.value, isFalse);
      expect(find.text('Retry'), findsNothing);
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.byType(UnityAvatarView), findsNothing);
      await _disposePage(tester);
    },
  );
  for (final size in [const Size(375, 667), const Size(812, 375)]) {
    testWidgets('form and recovery controls stay on one page at $size', (
      tester,
    ) async {
      lifecycle.phase.value = AccountSessionLifecyclePhase.faulted;
      await _pumpLogin(tester, size: size, textScale: 2);
      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(find.text('Retry').hitTestable(), findsOneWidget);
      expect(find.text('Privacy & permissions').hitTestable(), findsOneWidget);
      await _disposePage(tester);
    });
  }
  testWidgets('keyboard preserves doorway scale and raises only the form', (
    tester,
  ) async {
    await _pumpLogin(tester);
    login.email.text = 'kept@example.com';
    login.password.text = 'kept-password';
    final artwork = find.byKey(const ValueKey('login-doorway-artwork'));
    final form = find.byKey(const ValueKey('login-form-exit'));
    final before = tester.getRect(artwork);
    final formBefore = tester.getRect(form);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    expect(tester.getRect(artwork), before);
    expect(tester.getRect(form).top, lessThan(formBefore.top));
    expect(tester.getRect(form).bottom, closeTo(852 - 320, .1));
    expect(login.email.text, 'kept@example.com');
    expect(login.password.text, 'kept-password');
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(find.text('auth.log_in'.tr).hitTestable(), findsOneWidget);
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pump();
    expect(tester.getRect(artwork), before);
    expect(tester.getRect(form), formBefore);
    await _disposePage(tester);
  });
  testWidgets('registration and keyboard remain on one fixed page', (
    tester,
  ) async {
    await _pumpLogin(tester, size: const Size(375, 667), textScale: 2);
    await tester.tap(find.text('auth.switch_to_signup'.tr));
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(find.byType(TextField), findsNWidgets(3));
    expect(find.text('auth.create_account'.tr).hitTestable(), findsOneWidget);
    expect(find.text('Privacy & permissions').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _disposePage(tester);
  });

  testWidgets(
    'login hides its fixed form title while the one loading button moves to panel center',
    (tester) async {
      await _pumpLogin(tester);
      final artwork = find.byKey(const ValueKey('login-doorway-artwork'));
      final form = find.byKey(const ValueKey('login-form-exit'));
      final title = find.descendant(
        of: form,
        matching: find.text('auth.sign_in'.tr),
      );
      final artworkBefore = tester.getRect(artwork);
      final formBefore = tester.getRect(form);
      final titleBefore = tester.getRect(title);
      final button = find.byType(FilledButton);
      final buttonBefore = tester.getCenter(button);
      await tester.drag(artwork, const Offset(0, -220));
      await tester.pump();
      expect(tester.getRect(artwork), artworkBefore);
      expect(tester.getRect(form), formBefore);
      login.isLoading.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 210));
      final halfway = tester.getCenter(button).dy;
      expect(
        halfway,
        greaterThan(math.min(buttonBefore.dy, formBefore.center.dy)),
      );
      expect(
        halfway,
        lessThan(math.max(buttonBefore.dy, formBefore.center.dy)),
      );
      await tester.pump(const Duration(milliseconds: 290));
      expect(find.byKey(const ValueKey('login-form-loading')), findsNothing);
      expect(tester.getRect(title), titleBefore);
      expect(tester.getCenter(button).dy, closeTo(formBefore.center.dy, 2));
      for (final key in [
        'login-header-visibility',
        'login-email-visibility',
        'login-password-visibility',
        'login-feedback-visibility',
        'login-switch-visibility',
        'login-privacy-visibility',
      ]) {
        expect(tester.widget<Opacity>(find.byKey(ValueKey(key))).opacity, 0);
      }
      expect(find.text('auth.sign_in'.tr).hitTestable(), findsNothing);
      expect(find.text('auth.doorway.subtitle'.tr).hitTestable(), findsNothing);
      expect(
        tester
            .widget<ExcludeSemantics>(
              find
                  .ancestor(
                    of: find.byKey(const ValueKey('login-header-visibility')),
                    matching: find.byType(ExcludeSemantics),
                  )
                  .first,
            )
            .excluding,
        isTrue,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        find.descendant(
          of: button,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      final cover = login.beforeAuthenticatedNavigation!();
      await tester.pump();
      await cover;
      expect(tester.getRect(form), formBefore);
      expect(tester.getRect(artwork), artworkBefore);
      expect(tester.widget<AnimatedSlide>(form).offset, Offset.zero);
      login.isLoading.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 210));
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('login-header-visibility')),
            )
            .opacity,
        greaterThan(
          tester
              .widget<Opacity>(
                find.byKey(const ValueKey('login-email-visibility')),
              )
              .opacity,
        ),
      );
      expect(find.text('Privacy & permissions').hitTestable(), findsNothing);
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('login-email-visibility')),
            )
            .opacity,
        greaterThan(
          tester
              .widget<Opacity>(
                find.byKey(const ValueKey('login-privacy-visibility')),
              )
              .opacity,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getCenter(button).dy, closeTo(buttonBefore.dy, 2));
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('login-header-visibility')),
            )
            .opacity,
        1,
      );
      expect(find.text('auth.sign_in'.tr).hitTestable(), findsOneWidget);
      expect(find.text('Privacy & permissions').hitTestable(), findsOneWidget);
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('login-privacy-visibility')),
            )
            .opacity,
        1,
      );
      expect(tester.getRect(title), titleBefore);
      expect(find.byType(SingleChildScrollView), findsNothing);
      await _disposePage(tester);
    },
  );

  testWidgets(
    'failed login restores fields for retry with keyboard and no overflow',
    (tester) async {
      await _pumpLogin(tester, size: const Size(375, 667), textScale: 1.3);
      login.email.text = 'kept@example.com';
      login.password.text = 'kept-password';
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      login.isLoading.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(tester.takeException(), isNull);

      login.error.value = 'Incorrect password';
      login.isLoading.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(login.email.text, 'kept@example.com');
      expect(login.password.text, 'kept-password');
      expect(find.text('Incorrect password'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(TextField), findsNWidgets(2));
      expect(tester.takeException(), isNull);

      login.isLoading.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      login.isLoading.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(login.email.text, 'kept@example.com');
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(tester.takeException(), isNull);
      await _disposePage(tester);
    },
  );

  testWidgets('keyboard dismissal does not jump the loading button', (
    tester,
  ) async {
    await _pumpLogin(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.pump();
    final button = find.byType(FilledButton);
    final before = tester.getCenter(button);

    login.isLoading.value = true;
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pump();
    final firstBusyFrame = tester.getCenter(button);
    expect((firstBusyFrame.dy - before.dy).abs(), lessThan(24));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 210));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 290));
    expect(
      tester.getCenter(button).dy,
      closeTo(
        tester.getRect(find.byKey(const ValueKey('login-form-exit'))).center.dy,
        2,
      ),
    );
    login.isLoading.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    await _disposePage(tester);
  });

  testWidgets(
    'reduced motion keeps the one loading button centered without fade',
    (tester) async {
      await _pumpLogin(tester, disableAnimations: true);
      final button = find.byType(FilledButton);
      final originalCenter = tester.getCenter(button);
      final formCenter = tester
          .getRect(find.byKey(const ValueKey('login-form-exit')))
          .center;
      login.isLoading.value = true;
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('login-header-visibility')),
            )
            .opacity,
        0,
      );
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('login-email-visibility')),
            )
            .opacity,
        0,
      );
      expect(tester.getCenter(button).dy, closeTo(formCenter.dy, 2));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      login.isLoading.value = false;
      await tester.pump();
      await tester.pump();
      expect(tester.getCenter(button).dy, closeTo(originalCenter.dy, 2));
      expect(tester.takeException(), isNull);
      await _disposePage(tester);
    },
  );

  testWidgets('live door and form slide remain on Login until Avatar framing', (
    tester,
  ) async {
    lifecycle.testMounted = true;
    final doorway = appServices.put(
      LoginDoorwayCoordinator(
        currentScope: () => 'account-a',
        currentGeneration: () => 1,
        accountMounted: () => true,
        consumeEntrance: () => true,
      ),
    );
    final renderer = _DoorwayRenderer();
    appServices.put(ActiveAvatarRuntime()..register(renderer));
    await _pumpLogin(tester);
    login.isLoading.value = true;
    doorway.requestAuthenticated();
    final transition = login.beforeAuthenticatedNavigation!();
    await tester.pump();
    await tester.pump();
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(UnityAvatarView), findsOneWidget);
    expect(
      tester
          .widget<UnityAvatarView>(find.byType(UnityAvatarView))
          .backgroundColor,
      Colors.transparent,
    );
    final scaffold = tester.widget<AppGlassScaffold>(
      find.byType(AppGlassScaffold),
    );
    expect(scaffold.backdropKind, GlassBackdropKind.platformView);
    expect(scaffold.backgroundColor, Colors.transparent);
    expect(renderer.calls.single.phase, AvatarDoorwayPhase.prepare);
    final panel = find.byKey(const ValueKey('login-form-exit'));
    expect(tester.widget<AnimatedSlide>(panel).offset, Offset.zero);

    renderer.completeNext();
    await tester.pump();
    await tester.pump();
    expect(doorway.phase.value, LoginDoorwayStage.opening);
    expect(tester.widget<AnimatedSlide>(panel).offset, const Offset(0, 1));
    expect(
      tester.widget<AnimatedSlide>(panel).duration,
      const Duration(milliseconds: 800),
    );
    expect(find.byKey(const ValueKey('login-doorway-skip')), findsNothing);
    expect(find.byType(LoginPage), findsOneWidget);
    for (final expected in <AvatarDoorwayPhase>[
      AvatarDoorwayPhase.enter,
      AvatarDoorwayPhase.frame,
    ]) {
      renderer.completeNext();
      await tester.pump();
      await tester.pump();
      expect(renderer.calls.last.phase, expected);
      expect(find.byType(LoginPage), findsOneWidget);
    }
    renderer.completeNext();
    await tester.pump();
    await transition;
    expect(doorway.completed, isTrue);
    await _disposePage(tester);
  });

  testWidgets('a transient native rejection does not flash to Home', (
    tester,
  ) async {
    lifecycle.testMounted = true;
    final doorway = appServices.put(
      LoginDoorwayCoordinator(
        currentScope: () => 'account-a',
        currentGeneration: () => 1,
        accountMounted: () => true,
        consumeEntrance: () => true,
        preparationRetryDelay: Duration.zero,
      ),
    );
    final renderer = _DoorwayRenderer();
    appServices.put(ActiveAvatarRuntime()..register(renderer));
    await _pumpLogin(tester);
    login.isLoading.value = true;
    doorway.requestAuthenticated();
    final transition = login.beforeAuthenticatedNavigation!();
    await tester.pump();
    await tester.pump();
    renderer.failNext(
      const AvatarDoorwayTransitionException('presentation_unavailable'),
    );
    await tester.pump();
    expect(find.byType(LoginPage), findsOneWidget);
    expect(doorway.phase.value, LoginDoorwayStage.preparing);
    expect(
      tester
          .widget<AnimatedSlide>(find.byKey(const ValueKey('login-form-exit')))
          .offset,
      Offset.zero,
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(renderer.calls, hasLength(2));
    for (var i = 0; i < 4; i++) {
      renderer.completeNext();
      await tester.pump();
      await tester.pump();
    }
    await transition;
    expect(doorway.completed, isTrue);
    await _disposePage(tester);
  });

  testWidgets(
    'authenticated preparation timeout stays on Login and retries without credentials',
    (tester) async {
      lifecycle.testMounted = true;
      final doorway = appServices.put(
        LoginDoorwayCoordinator(
          currentScope: () => 'account-a',
          currentGeneration: () => 1,
          accountMounted: () => true,
          consumeEntrance: () => true,
          readinessTimeout: const Duration(milliseconds: 40),
        ),
      );
      final renderer = _DoorwayRenderer()..isReady.value = false;
      appServices.put(ActiveAvatarRuntime()..register(renderer));
      await _pumpLogin(tester);
      login.email.text = 'kept@example.com';
      login.password.text = 'kept-password';
      login.isLoading.value = true;
      doorway.requestAuthenticated();
      final transition = login.beforeAuthenticatedNavigation!();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 500));

      expect(doorway.phase.value, LoginDoorwayStage.preparationFailed);
      expect(doorway.canRetryPreparation, isTrue);
      expect(doorway.completed, isFalse);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(renderer.calls, isEmpty);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final button = find.widgetWithText(FilledButton, 'common.retry'.tr);
      expect(button, findsOneWidget);
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('login-submit-motion')),
          matching: find.text('common.request_failed'.tr),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('login-email-visibility')),
            )
            .opacity,
        0,
      );
      expect(
        tester.getCenter(button).dy,
        closeTo(
          tester
              .getRect(find.byKey(const ValueKey('login-form-exit')))
              .center
              .dy,
          2,
        ),
      );

      renderer.isReady.value = true;
      await tester.tap(button);
      await tester.pump();
      await tester.pump();
      expect(doorway.phase.value, LoginDoorwayStage.preparing);
      expect(renderer.calls.single.phase, AvatarDoorwayPhase.prepare);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(login.email.text, 'kept@example.com');
      expect(login.password.text, 'kept-password');

      for (var i = 0; i < 4; i++) {
        renderer.completeNext();
        await tester.pump();
        await tester.pump();
      }
      await transition;
      expect(doorway.completed, isTrue);
      await _disposePage(tester);
    },
  );

  testWidgets('door waits until account Avatar selection is reconciled', (
    tester,
  ) async {
    lifecycle.testMounted = true;
    final config = appServices.put(AvatarConfigService().init());
    config.selectionAuthorityState.value =
        AvatarSelectionAuthorityState.synchronizing;
    final doorway = appServices.put(
      LoginDoorwayCoordinator(
        currentScope: () => 'account-a',
        currentGeneration: () => 1,
        accountMounted: () => true,
        consumeEntrance: () => true,
      ),
    );
    final renderer = _DoorwayRenderer();
    appServices.put(ActiveAvatarRuntime()..register(renderer));
    await _pumpLogin(tester);
    login.isLoading.value = true;
    doorway.requestAuthenticated();
    final transition = login.beforeAuthenticatedNavigation!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(renderer.calls, isEmpty);
    expect(doorway.phase.value, LoginDoorwayStage.preparing);
    expect(find.byType(LoginPage), findsOneWidget);

    config.selectionAuthorityState.value = AvatarSelectionAuthorityState.ready;
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(renderer.calls.single.phase, AvatarDoorwayPhase.prepare);
    expect(
      renderer.visibleAtPreparation,
      [true],
      reason:
          'Unity requires the selected actor to be locally visible before doorway preparation',
    );
    for (var i = 0; i < 4; i++) {
      renderer.completeNext();
      await tester.pump();
      await tester.pump();
    }
    await transition;
    expect(doorway.completed, isTrue);
    await _disposePage(tester);
  });
  for (final ownsExecution in [false, true]) {
    testWidgets(
      'login mounted device reveals actor with execution=$ownsExecution',
      (tester) async {
        lifecycle.testMounted = true;
        lifecycle.setPresentationAllowed(ownsExecution);
        appServices.put(AvatarConfigService().init());
        final doorway = appServices.put(
          LoginDoorwayCoordinator(
            currentScope: () => 'account-a',
            currentGeneration: () => 1,
            accountMounted: () => true,
            consumeEntrance: () => true,
            readinessTimeout: const Duration(milliseconds: 500),
          ),
        );
        final renderer = _DoorwayRenderer();
        appServices.put(ActiveAvatarRuntime()..register(renderer));
        await _pumpLogin(tester);
        login.isLoading.value = true;
        doorway.requestAuthenticated();
        final transition = login.beforeAuthenticatedNavigation!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(renderer.localVisible, isTrue);
        expect(renderer.visibleAtPreparation, [true]);
        for (var i = 0; i < 4; i++) {
          renderer.completeNext();
          await tester.pump();
          await tester.pump();
        }
        expect(doorway.completed, isTrue);
        expect(lifecycle.canExecuteAgent, ownsExecution);
        await _disposePage(tester);
        await transition;
      },
    );
  }

  testWidgets(
    'login cannot reveal an unconfirmed fallback after selection loading',
    (tester) async {
      lifecycle.testMounted = true;
      appServices.put<AvatarConfigService>(
        _UnavailableSelectionConfig().init(),
      );
      final doorway = appServices.put(
        LoginDoorwayCoordinator(
          currentScope: () => 'account-a',
          currentGeneration: () => 1,
          accountMounted: () => true,
          consumeEntrance: () => true,
          readinessTimeout: const Duration(milliseconds: 500),
        ),
      );
      final renderer = _DoorwayRenderer();
      appServices.put(ActiveAvatarRuntime()..register(renderer));
      await _pumpLogin(tester);
      login.isLoading.value = true;
      doorway.requestAuthenticated();
      final transition = login.beforeAuthenticatedNavigation!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump();
      expect(renderer.localVisible, isFalse);
      expect(renderer.calls, isEmpty);
      expect(find.byType(LoginPage), findsOneWidget);
      await _disposePage(tester);
      await transition;
    },
  );
}

class _UnavailableSelectionConfig extends AvatarConfigService {
  @override
  bool get selectionDisplayCurrent => false;
  @override
  Future<void> applyInitial() async {}
}

Future<void> _pumpLogin(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  Size size = const Size(393, 852),
  double textScale = 1,
  bool disableAnimations = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final router = GoRouter(
    initialLocation: AppRouteCatalog.login,
    routes: [
      GoRoute(
        path: AppRouteCatalog.login,
        builder: (_, _) => RepaintBoundary(
          key: _captureKey,
          child: const Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: _nativeBackdrop),
              LoginPage(),
            ],
          ),
        ),
      ),
      GoRoute(
        path: AppRouteCatalog.privacy,
        builder: (_, _) => const Scaffold(body: Text('Privacy destination')),
      ),
    ],
  );
  appNavigation.configure(router);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    MaterialApp.router(
      locale: const Locale('en', 'US'),
      theme: AppTheme.build(AppPalette.of(brightness, AppAccent.blue)),
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: child!,
      ),
    ),
  );
  await tester.pump();
}

Future<Color> _backgroundPixel(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final offset = ((image.height - 8) * image.width + 8) * 4;
    final color = Color.fromARGB(
      bytes.getUint8(offset + 3),
      bytes.getUint8(offset),
      bytes.getUint8(offset + 1),
      bytes.getUint8(offset + 2),
    );
    image.dispose();
    return color;
  }))!;
}

double _contrast(Color foreground, Color background) {
  final painted = Color.alphaBlend(foreground, background).computeLuminance();
  final surface = background.computeLuminance();
  return ((painted > surface ? painted : surface) + 0.05) /
      ((painted < surface ? painted : surface) + 0.05);
}

Future<void> _disposePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 4));
  debugDefaultTargetPlatformOverride = null;
}

class _MemoryStorage extends SecureStorageService {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<bool> write(String key, String? value) async {
    value == null ? values.remove(key) : values[key] = value;
    return true;
  }

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}

class _RuntimeLease implements AccountRuntimeLease {
  @override
  Future<void> close() async {}
}

/// Presentation policy is a read-only input to this page. Actual authority
/// admission is covered by account lifecycle tests, without a native renderer.
class _PresentationLifecycle extends AccountSessionLifecycleService {
  _PresentationLifecycle({required super.auth, required super.environment})
    : super(mountRuntime: (_) async => _RuntimeLease());

  final _presentationChanges = ChangeNotifier();
  bool _presentationAllowed = true;
  bool testMounted = false;

  @override
  bool get isMounted => testMounted || super.isMounted;

  void setPresentationAllowed(bool value) {
    _presentationAllowed = value;
    _presentationChanges.notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _presentationChanges.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _presentationChanges.removeListener(listener);
  }

  @override
  void onClose() {
    _presentationChanges.dispose();
    super.onClose();
  }

  @override
  bool get canExecuteAgent => isMounted && _presentationAllowed;
}

class _AvatarWire implements UnityAvatarTransport {
  final calls = <MethodCall>[];
  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    calls.add(MethodCall(method, arguments));
    return null;
  }

  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? handler) {}
  @override
  void dispose() {}
}

class _DoorwayRenderer extends AvatarRuntime {
  @override
  final isReady = true.obs;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  @override
  bool get supportsLoginDoorway => true;
  final calls = <AvatarDoorwayTransition>[];
  final _pending = <Completer<void>>[];
  bool localVisible = false;
  final visibleAtPreparation = <bool>[];

  @override
  Future<void> setLocalAvatarVisible(bool visible) async {
    localVisible = visible;
  }

  @override
  Future<void> transitionLoginDoorway(AvatarDoorwayTransition request) {
    if (request.phase == AvatarDoorwayPhase.prepare) {
      visibleAtPreparation.add(localVisible);
    }
    calls.add(request);
    final completion = Completer<void>();
    _pending.add(completion);
    return completion.future;
  }

  void completeNext() {
    final completion = _pending.removeAt(0);
    completion.complete();
  }

  void failNext(Object error) {
    final completion = _pending.removeAt(0);
    completion.completeError(error);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}
