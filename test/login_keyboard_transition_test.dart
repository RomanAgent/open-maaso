import 'dart:async';
import 'dart:io';
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
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/auth/application/login_controller.dart';
import 'package:maaso/src/features/auth/application/login_doorway_coordinator.dart';
import 'package:maaso/src/features/auth/presentation/login_page.dart';

const _capture = bool.fromEnvironment('MAASO_CAPTURE_LOGIN_KEYBOARD');
const _captureKey = ValueKey('login-keyboard-capture');
const _visualFont = 'MaasoLoginKeyboardVisual';

void main() {
  late _KeyboardLoginController login;
  late _DoorwayRenderer renderer;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    AppLocalization.updateLocale(const Locale('en', 'US'));
    appServices.put<SecureStorageService>(_MemoryStorage());
    final environment = appServices.put(AppEnvironmentService());
    await environment.init();
    final auth = appServices.put(AuthSessionService());
    appServices.put<AccountSessionLifecycleService>(
      _MountedLifecycle(auth: auth, environment: environment),
    );
    login = _KeyboardLoginController();
    appServices.put<LoginController>(login);
    renderer = _DoorwayRenderer();
    appServices.put(ActiveAvatarRuntime()..register(renderer));
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await appServices.reset();
  });

  for (final field in const [
    (name: 'email', index: 0, signup: false),
    (name: 'password', index: 1, signup: false),
    (name: 'verification code', index: 2, signup: true),
  ]) {
    testWidgets(
      '${field.name} keyboard fully closes before native doorway preparation',
      (tester) async {
        final doorway = _registerDoorway();
        await _pumpLogin(tester);
        if (field.signup) {
          await tester.tap(find.text('auth.switch_to_signup'.tr));
          await tester.pump();
        }
        await tester.showKeyboard(find.byType(TextField).at(field.index));
        final focus = tester
            .widget<EditableText>(find.byType(EditableText).at(field.index))
            .focusNode;
        expect(focus.hasFocus, isTrue);
        tester.view.viewInsets = const FakeViewPadding(bottom: 320);
        await tester.pump();

        login.isLoading.value = true;
        doorway.requestAuthenticated();
        var finished = false;
        final transition = login.beforeAuthenticatedNavigation!().then((_) {
          finished = true;
        });
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(focus.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
        expect(finished, isFalse);
        expect(renderer.calls, isEmpty);
        expect(find.byType(UnityAvatarView), findsNothing);

        for (final inset in [180.0, 20.0]) {
          tester.view.viewInsets = FakeViewPadding(bottom: inset);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(renderer.calls, isEmpty);
          expect(finished, isFalse);
        }

        tester.view.viewInsets = const FakeViewPadding();
        await _pumpFrames(tester);
        expect(renderer.calls.single.phase, AvatarDoorwayPhase.prepare);
        expect(find.byType(UnityAvatarView), findsOneWidget);
        expect(finished, isFalse);
        await _finishDoorway(tester, renderer);
        await transition;
        expect(doorway.completed, isTrue);
        expect(finished, isTrue);
        await _disposeLogin(tester);
      },
    );
  }

  testWidgets(
    'an already consumed entrance still closes keyboard before navigation',
    (tester) async {
      final doorway = _registerDoorway(consumeEntrance: false);
      await _pumpLogin(tester);
      await tester.showKeyboard(find.byType(TextField).first);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pump();
      doorway.requestAuthenticated();
      expect(doorway.phase.value, LoginDoorwayStage.skipped);

      var navigationReleased = false;
      final transition = login.beforeAuthenticatedNavigation!().then((_) {
        navigationReleased = true;
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(navigationReleased, isFalse);
      expect(renderer.calls, isEmpty);

      tester.view.viewInsets = const FakeViewPadding();
      await _pumpFrames(tester);
      await transition;
      expect(navigationReleased, isTrue);
      expect(renderer.calls, isEmpty);
      expect(tester.testTextInput.isVisible, isFalse);
      await _disposeLogin(tester);
    },
  );

  testWidgets('existing presentation callback also waits for keyboard', (
    tester,
  ) async {
    _registerDoorway(consumeEntrance: false);
    var previousPresentationCalls = 0;
    login.beforeAuthenticatedNavigation = () async {
      previousPresentationCalls++;
    };
    await _pumpLogin(tester);
    await tester.showKeyboard(find.byType(TextField).first);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pump();

    final transition = login.beforeAuthenticatedNavigation!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(previousPresentationCalls, 0);
    tester.view.viewInsets = const FakeViewPadding();
    await _pumpFrames(tester);
    await transition;
    expect(previousPresentationCalls, 1);
    await _disposeLogin(tester);
  });

  testWidgets(
    'inherited keyboard inset settling releases entry without native metrics',
    (tester) async {
      final doorway = _registerDoorway();
      final mediaInset = ValueNotifier<double>(100);
      addTearDown(mediaInset.dispose);
      await _pumpLogin(tester, mediaInset: mediaInset);
      expect(tester.view.viewInsets.bottom, 0);
      doorway.requestAuthenticated();
      var finished = false;
      final transition = login.beforeAuthenticatedNavigation!().then((_) {
        finished = true;
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(renderer.calls, isEmpty);
      expect(finished, isFalse);

      // Only the inherited layout settles. The native view has remained at
      // zero throughout, so this does not send a didChangeMetrics notification.
      mediaInset.value = 0;
      await _pumpFrames(tester);
      expect(tester.view.viewInsets.bottom, 0);
      expect(renderer.calls.single.phase, AvatarDoorwayPhase.prepare);
      await _finishDoorway(tester, renderer);
      await transition;
      expect(doorway.completed, isTrue);
      expect(finished, isTrue);
      await _disposeLogin(tester);
    },
  );

  testWidgets(
    'disposing login releases the pending wait without opening door',
    (tester) async {
      final doorway = _registerDoorway();
      await _pumpLogin(tester);
      await tester.showKeyboard(find.byType(TextField).first);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pump();
      doorway.requestAuthenticated();

      var finished = false;
      final transition = login.beforeAuthenticatedNavigation!().then((_) {
        finished = true;
      });
      await tester.pump();
      expect(finished, isFalse);
      expect(renderer.calls, isEmpty);

      await _disposeLogin(tester);
      await transition;
      expect(finished, isTrue);
      expect(renderer.calls, isEmpty);
      tester.view.viewInsets = const FakeViewPadding();
      await _pumpFrames(tester);
      expect(renderer.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('zero keyboard inset starts doorway without a dismissal delay', (
    tester,
  ) async {
    final doorway = _registerDoorway();
    await _pumpLogin(tester);
    doorway.requestAuthenticated();
    final transition = login.beforeAuthenticatedNavigation!();
    await _pumpFrames(tester);
    expect(renderer.calls.single.phase, AvatarDoorwayPhase.prepare);
    await _finishDoorway(tester, renderer);
    await transition;
    expect(doorway.completed, isTrue);
    await _disposeLogin(tester);
  });

  for (final field in const [
    (name: 'email', index: 0, signup: false),
    (name: 'verification code', index: 2, signup: true),
  ]) {
    testWidgets('submit clears ${field.name} focus before awaiting login', (
      tester,
    ) async {
      await _pumpLogin(tester);
      if (field.signup) {
        await tester.tap(find.text('auth.switch_to_signup'.tr));
        await tester.pump();
      }
      await tester.showKeyboard(find.byType(TextField).at(field.index));
      final focus = tester
          .widget<EditableText>(find.byType(EditableText).at(field.index))
          .focusNode;
      expect(focus.hasFocus, isTrue);
      await tester.tap(
        find.widgetWithText(
          FilledButton,
          (field.signup ? 'auth.create_account' : 'auth.log_in').tr,
        ),
      );
      await tester.pump();
      expect(login.submissions, 1);
      expect(focus.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      await _disposeLogin(tester);
    });
  }

  if (_capture) {
    testWidgets('capture closed and open keyboard login layout', (
      tester,
    ) async {
      AppLocalization.updateLocale(const Locale('zh', 'CN'));
      await _pumpLogin(tester, visual: true, locale: const Locale('zh', 'CN'));
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/brand/login_doorway.png'),
          tester.element(find.byType(LoginPage)),
        ),
      );
      await tester.pumpAndSettle();
      await _captureFrame(tester, 'login-keyboard-closed');
      await tester.showKeyboard(find.byType(TextField).first);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      await _captureFrame(tester, 'login-keyboard-open');
      expect(tester.takeException(), isNull);
      await _disposeLogin(tester);
      debugDisableShadows = true;
    });
  }
}

LoginDoorwayCoordinator _registerDoorway({bool consumeEntrance = true}) =>
    appServices.put(
      LoginDoorwayCoordinator(
        currentScope: () => 'keyboard-test-account',
        currentGeneration: () => 1,
        accountMounted: () => true,
        consumeEntrance: () => consumeEntrance,
      ),
    );

Future<void> _pumpLogin(
  WidgetTester tester, {
  ValueNotifier<double>? mediaInset,
  bool visual = false,
  Locale locale = const Locale('en', 'US'),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(393, 852);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetViewInsets);
  if (visual) {
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    await tester.runAsync(() async {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      final font = File('/System/Library/Fonts/STHeiti Light.ttc');
      if (await font.exists()) {
        final data = ByteData.sublistView(await font.readAsBytes());
        for (final family in [_visualFont, 'Ahem', 'Roboto']) {
          await (FontLoader(family)..addFont(Future.value(data))).load();
        }
      }
    });
  }
  final router = GoRouter(
    initialLocation: AppRouteCatalog.login,
    routes: [
      GoRoute(
        path: AppRouteCatalog.login,
        builder: (_, _) =>
            const RepaintBoundary(key: _captureKey, child: LoginPage()),
      ),
      GoRoute(
        path: AppRouteCatalog.home,
        builder: (_, _) => const Scaffold(body: Text('Home destination')),
      ),
    ],
  );
  appNavigation.configure(router);
  addTearDown(router.dispose);
  final theme = AppTheme.build(AppPalette.of(Brightness.light, AppAccent.blue));
  await tester.pumpWidget(
    MaterialApp.router(
      locale: locale,
      theme: visual
          ? theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: _visualFont),
              primaryTextTheme: theme.primaryTextTheme.apply(
                fontFamily: _visualFont,
              ),
              filledButtonTheme: FilledButtonThemeData(
                style: theme.filledButtonTheme.style?.copyWith(
                  // The login action provides its own TextStyle, so a theme
                  // textStyle alone cannot replace the test engine's Ahem.
                  foregroundBuilder: _readableButtonText,
                ),
              ),
              textButtonTheme: TextButtonThemeData(
                style: theme.textButtonTheme.style?.copyWith(
                  foregroundBuilder: _readableButtonText,
                ),
              ),
            )
          : theme,
      routerConfig: router,
      builder: (context, child) => mediaInset == null
          ? child!
          : ValueListenableBuilder<double>(
              valueListenable: mediaInset,
              child: child,
              builder: (context, inset, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(viewInsets: EdgeInsets.only(bottom: inset)),
                child: child!,
              ),
            ),
    ),
  );
  await tester.pump();
}

Widget _readableButtonText(
  BuildContext context,
  Set<WidgetState> states,
  Widget? child,
) => DefaultTextStyle.merge(
  style: const TextStyle(fontFamily: _visualFont),
  child: child ?? const SizedBox.shrink(),
);

Future<void> _captureFrame(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final output = File('build/verification/login-keyboard-20261021/$name.png');
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 4; frame++) {
    await tester.pump();
  }
}

Future<void> _finishDoorway(
  WidgetTester tester,
  _DoorwayRenderer renderer,
) async {
  for (final phase in const [
    AvatarDoorwayPhase.prepare,
    AvatarDoorwayPhase.open,
    AvatarDoorwayPhase.enter,
    AvatarDoorwayPhase.frame,
  ]) {
    expect(renderer.calls.last.phase, phase);
    renderer.completeNext();
    await _pumpFrames(tester);
  }
}

Future<void> _disposeLogin(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 4));
  debugDefaultTargetPlatformOverride = null;
}

class _KeyboardLoginController extends LoginController {
  int submissions = 0;

  @override
  Future<void> submit() async {
    submissions++;
  }
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

class _MountedLifecycle extends AccountSessionLifecycleService {
  _MountedLifecycle({required super.auth, required super.environment})
    : super(mountRuntime: (_) async => _RuntimeLease());

  @override
  bool get isMounted => true;
}

class _RuntimeLease implements AccountRuntimeLease {
  @override
  Future<void> close() async {}
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

  @override
  Future<void> transitionLoginDoorway(AvatarDoorwayTransition request) {
    calls.add(request);
    final completion = Completer<void>();
    _pending.add(completion);
    return completion.future;
  }

  void completeNext() => _pending.removeAt(0).complete();

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}
