import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:maaso/src/desktop/application/avatar_interaction_coordinator.dart';
import 'package:maaso/src/desktop/application/companion_menu_catalog.dart';
import 'package:maaso/src/desktop/application/desktop_avatar_interaction.dart';
import 'package:maaso/src/desktop/application/desktop_companion_host_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_companion_tray_controller.dart';
import 'package:maaso/src/desktop/application/desktop_companion_preferences_service.dart';
import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/desktop/presentation/companion_function_menu.dart';
import 'package:maaso/src/desktop/presentation/desktop_companion_shell.dart';
import 'package:maaso/src/desktop/presentation/desktop_pet_stage.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'independent Mac pet coexists with chat and leaves only for Agent space routes',
    (tester) async {
      final gateway = _FakeIndependentDesktopWindowGateway();
      final controller = DesktopWindowModeController(gateway: gateway);
      final host = _FakeDesktopCompanionHostGateway();
      final route = ValueNotifier<String>('/home');
      addTearDown(controller.dispose);
      addTearDown(host.dispose);
      addTearDown(route.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopCompanionShell(
            windowController: controller,
            hostGateway: host,
            keepAppWindowWithPet: true,
            routeListenable: route,
            currentRoute: () => route.value,
            child: const SizedBox(key: ValueKey<String>('independent-chat')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.mode, DesktopWindowMode.app);
      expect(controller.petVisible, isTrue);
      expect(gateway.calls, isNot(contains('enterPetMode')));
      expect(host.calls, contains('show'));
      final initialShows = host.calls.where((c) => c == 'show').length;
      route.value = '/settings';
      await tester.pumpAndSettle();
      expect(host.calls.where((c) => c == 'show'), hasLength(initialShows));
      expect(host.calls, isNot(contains('hide')));
      for (final worldRoute in ['/agent-space', '/agent-space?from=menu']) {
        route.value = worldRoute;
        await tester.pumpAndSettle();
        expect(host.calls.last, 'hide');
        expect(controller.mode, DesktopWindowMode.app);
        final tray = DesktopCompanionTrayController(
          windowController: controller,
          gateway: const UnsupportedDesktopCompanionTrayGateway(),
          canShowPet: () => false,
        );
        await tray.handleWindowCloseRequested();
        await tester.pumpAndSettle();
        expect(controller.petVisible, isTrue);
        route.value = '/home';
        await tester.pumpAndSettle();
        expect(
          host.calls.where((call) => call == 'show' || call == 'hide').last,
          'show',
        );
        expect(controller.mode, DesktopWindowMode.app);
        expect(controller.petVisible, isTrue);
      }
      expect(
        find.byKey(const ValueKey<String>('independent-chat')),
        findsOneWidget,
      );
      expect(gateway.calls, isNot(contains('enterPetMode')));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'pet mode replaces the full app with a transparent compact stage',
    (tester) async {
      final gateway = _FakeDesktopWindowGateway();
      final controller = DesktopWindowModeController(gateway: gateway);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 320,
            height: 420,
            child: DesktopCompanionShell(
              windowController: controller,
              autoEnterPetMode: false,
              child: const ColoredBox(
                key: ValueKey<String>('full-app'),
                color: Colors.white,
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey<String>('full-app')), findsOneWidget);

      await controller.enterPetMode();
      await tester.pump();

      expect(find.byType(DesktopPetStage), findsOneWidget);
      expect(find.byKey(DesktopPetStage.toolbarKey), findsOneWidget);
      expect(find.byKey(DesktopPetStage.fallbackAvatarKey), findsOneWidget);
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(DesktopPetStage),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.type, MaterialType.transparency);
    },
  );

  testWidgets('pet mode owns an Overlay when it replaces the router child', (
    tester,
  ) async {
    final gateway = _FakeDesktopWindowGateway();
    final controller = DesktopWindowModeController(gateway: gateway);
    addTearDown(controller.dispose);
    await controller.enterPetMode();

    await tester.pumpWidget(
      MaterialApp(
        home: const SizedBox.shrink(),
        builder: (context, child) => SizedBox(
          width: 320,
          height: 420,
          child: DesktopCompanionShell(
            windowController: controller,
            autoEnterPetMode: false,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );

    expect(find.byType(Overlay), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(DesktopPetStage.menuButtonKey));
    await tester.pumpAndSettle();

    expect(find.byType(CompanionFunctionMenu), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('complete menu expands the app before selecting a route', (
    tester,
  ) async {
    final gateway = _FakeDesktopWindowGateway();
    final controller = DesktopWindowModeController(gateway: gateway);
    addTearDown(controller.dispose);
    CompanionMenuEntry? selected;

    await controller.enterPetMode();
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 320,
          height: 420,
          child: DesktopCompanionShell(
            windowController: controller,
            autoEnterPetMode: false,
            onDestinationSelected: (entry) => selected = entry,
            child: const ColoredBox(
              key: ValueKey<String>('full-app'),
              color: Colors.white,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(DesktopPetStage.menuButtonKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(CompanionFunctionMenu.entryKey('chat')));
    await tester.pumpAndSettle();

    expect(controller.mode, DesktopWindowMode.app);
    expect(selected?.destination.id, 'chat');
    expect(selected?.destination.route, '/home');
    expect(find.byKey(const ValueKey<String>('full-app')), findsOneWidget);
    expect(
      gateway.calls,
      containsAllInOrder(<String>['enterPetMode', 'enterAppMode']),
    );
  });

  testWidgets('dragging the title area delegates to native window dragging', (
    tester,
  ) async {
    final gateway = _FakeDesktopWindowGateway();
    final controller = DesktopWindowModeController(gateway: gateway);
    addTearDown(controller.dispose);
    await controller.enterPetMode();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 320,
          height: 420,
          child: DesktopCompanionShell(
            windowController: controller,
            autoEnterPetMode: false,
            child: const SizedBox.shrink(),
          ),
        ),
      ),
    );

    await tester.drag(
      find.byKey(DesktopPetStage.dragAreaKey),
      const Offset(8, 8),
    );
    await tester.pump();

    expect(gateway.calls, contains('startDragging'));
  });

  testWidgets(
    'independent pet keeps the routed app separate when a menu opens chat',
    (tester) async {
      final gateway = _FakeIndependentDesktopWindowGateway();
      final controller = DesktopWindowModeController(gateway: gateway);
      final host = _FakeDesktopCompanionHostGateway();
      addTearDown(controller.dispose);
      addTearDown(host.dispose);
      CompanionMenuEntry? selected;

      await controller.enterPetMode();
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopCompanionShell(
            windowController: controller,
            autoEnterPetMode: false,
            hostGateway: host,
            onDestinationSelected: (entry) => selected = entry,
            child: const ColoredBox(
              key: ValueKey<String>('independent-full-app'),
              color: Colors.white,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DesktopPetStage), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('independent-full-app')),
        findsOneWidget,
      );
      expect(host.calls, contains('show'));

      await host.onMenuSelected!('chat');
      await tester.pumpAndSettle();

      expect(controller.mode, DesktopWindowMode.app);
      expect(controller.petVisible, isTrue);
      expect(selected?.destination.id, 'chat');
      expect(selected?.destination.route, '/home');
      expect(host.calls, isNot(contains('hide')));

      final appTransitions = gateway.calls
          .where((call) => call == 'enterAppMode')
          .length;
      await host.onMenuSelected!('settings');
      await tester.pumpAndSettle();
      expect(
        gateway.calls.where((call) => call == 'enterAppMode').length,
        appTransitions + 1,
      );

      await controller.hidePet();
      await tester.pumpAndSettle();
      expect(host.calls, containsAllInOrder(<String>['clearBubble', 'hide']));
    },
  );

  testWidgets(
    'scene presentation hides the native pet and avatar-only presentation restores it',
    (tester) async {
      final gateway = _FakeIndependentDesktopWindowGateway();
      final controller = DesktopWindowModeController(gateway: gateway);
      final host = _FakeDesktopCompanionHostGateway();
      final scenePresentation = ValueNotifier<bool>(true);
      addTearDown(controller.dispose);
      addTearDown(host.dispose);
      addTearDown(scenePresentation.dispose);
      await controller.enterPetMode();

      await tester.pumpWidget(
        MaterialApp(
          home: DesktopCompanionShell(
            windowController: controller,
            autoEnterPetMode: false,
            hostGateway: host,
            petPresentationListenable: scenePresentation,
            isScenePresentation: () => scenePresentation.value,
            child: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(host.calls, isNot(contains('show')));
      expect(controller.petVisible, isTrue);

      scenePresentation.value = false;
      await tester.pumpAndSettle();
      expect(host.calls.where((call) => call == 'show'), hasLength(1));

      scenePresentation.value = true;
      await tester.pumpAndSettle();
      expect(
        host.calls,
        containsAllInOrder(<String>['show', 'clearBubble', 'hide']),
      );
      expect(
        controller.petVisible,
        isTrue,
        reason:
            'Scene ownership temporarily hides the pet without changing the user preference.',
      );

      scenePresentation.value = false;
      await tester.pumpAndSettle();
      expect(host.calls.where((call) => call == 'show'), hasLength(2));
      expect(
        host.calls.where((call) => call == 'show' || call == 'hide'),
        <String>['show', 'hide', 'show'],
      );
    },
  );

  testWidgets(
    'presentation config is applied before show and changes stay serialized',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SpUtils.init();
      final preferences = DesktopCompanionPreferencesService();
      preferences.initializeLifecycle();
      final gateway = _FakeIndependentDesktopWindowGateway();
      final controller = DesktopWindowModeController(gateway: gateway);
      final host = _FakeDesktopCompanionHostGateway();
      addTearDown(preferences.closeLifecycle);
      addTearDown(controller.dispose);
      addTearDown(host.dispose);

      await controller.enterPetMode();
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopCompanionShell(
            windowController: controller,
            autoEnterPetMode: false,
            hostGateway: host,
            presentationPreferences: preferences,
            child: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        host.calls.take(4),
        equals(<String>[
          'initialize',
          'configurePresentation:crisp:30',
          'configureMenu:6',
          'show',
        ]),
      );

      await preferences.setTargetFps(60);
      await tester.pumpAndSettle();

      expect(host.calls.last, 'configurePresentation:crisp:60');
    },
  );

  testWidgets(
    'native pet startup failure clears its intent without reopening the app',
    (tester) async {
      final gateway = _FakeIndependentDesktopWindowGateway();
      final controller = DesktopWindowModeController(gateway: gateway);
      final host = _FakeDesktopCompanionHostGateway(failShow: true);
      addTearDown(controller.dispose);
      addTearDown(host.dispose);

      await controller.enterPetMode();
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopCompanionShell(
            windowController: controller,
            autoEnterPetMode: false,
            hostGateway: host,
            child: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(host.calls.where((call) => call == 'show'), hasLength(1));
      expect(controller.mode, DesktopWindowMode.pet);
      expect(controller.petVisible, isFalse);
      expect(gateway.calls, isNot(contains('enterAppMode')));
    },
  );

  testWidgets(
    'independent startup prepares in parallel and waits for native first frame',
    (tester) async {
      final transitionOrder = <String>[];
      final gateway = _SequencedIndependentDesktopWindowGateway(
        transitionOrder,
      );
      final controller = DesktopWindowModeController(gateway: gateway);
      final host = _StartupGatedDesktopCompanionHostGateway(transitionOrder);
      final route = ValueNotifier<String>('/home');
      final presentationReady = Completer<void>();
      final preparationStarted = Completer<void>();
      final presentationFailed = ValueNotifier<bool>(false);
      addTearDown(controller.dispose);
      addTearDown(host.dispose);
      addTearDown(route.dispose);
      addTearDown(presentationFailed.dispose);
      addTearDown(() {
        if (!host.allowInitialization.isCompleted) {
          host.allowInitialization.complete();
        }
        if (!host.allowFirstFrame.isCompleted) {
          host.allowFirstFrame.complete();
        }
        if (!presentationReady.isCompleted) presentationReady.complete();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: DesktopCompanionShell(
            windowController: controller,
            routeListenable: route,
            currentRoute: () => route.value,
            hostGateway: host,
            preparePetPresentation: () async {
              if (!preparationStarted.isCompleted) {
                preparationStarted.complete();
              }
              await presentationReady.future;
            },
            petPresentationListenable: presentationFailed,
            isPetPresentationFailed: () => presentationFailed.value,
            child: const SizedBox.shrink(),
          ),
        ),
      );
      for (var attempt = 0; attempt < 10; attempt += 1) {
        await tester.pump();
        if (preparationStarted.isCompleted &&
            host.initializationStarted.isCompleted) {
          break;
        }
      }

      expect(preparationStarted.isCompleted, isTrue);
      expect(host.initializationStarted.isCompleted, isTrue);
      expect(controller.mode, DesktopWindowMode.app);
      expect(controller.petVisible, isFalse);
      expect(gateway.calls, isNot(contains('enterPetMode')));
      expect(host.calls, isNot(contains('show')));

      presentationReady.complete();
      await tester.pump();

      expect(host.showStarted.isCompleted, isFalse);
      expect(controller.mode, DesktopWindowMode.app);
      expect(gateway.calls, isNot(contains('enterPetMode')));

      host.allowInitialization.complete();
      for (var attempt = 0; attempt < 10; attempt += 1) {
        await tester.pump();
        if (host.showStarted.isCompleted) break;
      }

      expect(host.showStarted.isCompleted, isTrue);
      expect(controller.mode, DesktopWindowMode.app);
      expect(controller.petVisible, isFalse);
      expect(gateway.calls, isNot(contains('enterPetMode')));
      expect(transitionOrder, <String>['show:start']);

      host.allowFirstFrame.complete();
      await tester.pumpAndSettle();

      expect(controller.mode, DesktopWindowMode.pet);
      expect(controller.petVisible, isTrue);
      expect(gateway.calls, contains('enterPetMode'));
      expect(host.calls, contains('show'));
      expect(transitionOrder, <String>[
        'show:start',
        'show:complete',
        'enterPetMode',
      ]);

      presentationFailed.value = true;
      await tester.pumpAndSettle();

      expect(controller.mode, DesktopWindowMode.pet);
      expect(controller.petVisible, isFalse);
      expect(gateway.calls, isNot(contains('enterAppMode')));
      expect(host.calls, containsAllInOrder(<String>['show', 'hide']));
    },
  );

  testWidgets('a replaced host cannot commit its late preparation', (
    tester,
  ) async {
    final gateway = _FakeIndependentDesktopWindowGateway();
    final controller = DesktopWindowModeController(gateway: gateway);
    final previousHost = _StartupGatedDesktopCompanionHostGateway([]);
    final nextHost = _FakeDesktopCompanionHostGateway();
    addTearDown(controller.dispose);
    addTearDown(() {
      if (!previousHost.allowInitialization.isCompleted) {
        previousHost.allowInitialization.complete();
      }
      if (!previousHost.allowFirstFrame.isCompleted) {
        previousHost.allowFirstFrame.complete();
      }
    });

    Widget shell(DesktopCompanionHostGateway host) => MaterialApp(
      home: DesktopCompanionShell(
        windowController: controller,
        currentRoute: () => '/home',
        hostGateway: host,
        child: const SizedBox.shrink(),
      ),
    );

    await tester.pumpWidget(shell(previousHost));
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump();
      if (previousHost.initializationStarted.isCompleted) break;
    }
    expect(previousHost.initializationStarted.isCompleted, isTrue);
    expect(controller.petVisible, isFalse);

    await tester.pumpWidget(shell(nextHost));
    await tester.pump();
    previousHost.allowInitialization.complete();
    await tester.pumpAndSettle();

    expect(previousHost.calls, contains('dispose'));
    expect(previousHost.calls, isNot(contains('show')));
    expect(nextHost.calls, contains('show'));
    expect(controller.petVisible, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('presentation preparation failure keeps the app visible', (
    tester,
  ) async {
    final gateway = _FakeIndependentDesktopWindowGateway();
    final controller = DesktopWindowModeController(gateway: gateway);
    final host = _FakeDesktopCompanionHostGateway();
    final route = ValueNotifier<String>('/home');
    addTearDown(controller.dispose);
    addTearDown(host.dispose);
    addTearDown(route.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: DesktopCompanionShell(
          windowController: controller,
          routeListenable: route,
          currentRoute: () => route.value,
          hostGateway: host,
          preparePetPresentation: () async {
            throw StateError('sidecar protocol mismatch');
          },
          child: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.mode, DesktopWindowMode.app);
    expect(controller.petVisible, isFalse);
    expect(gateway.calls, isNot(contains('enterPetMode')));
    expect(host.calls, isNot(contains('show')));
  });

  testWidgets('successful preparation cannot show an unready pet', (
    tester,
  ) async {
    final gateway = _FakeIndependentDesktopWindowGateway();
    final controller = DesktopWindowModeController(gateway: gateway);
    final host = _FakeDesktopCompanionHostGateway();
    final ready = ValueNotifier<bool>(false);
    bool readReady() => ready.value;
    var preparations = 0;
    addTearDown(controller.dispose);
    addTearDown(host.dispose);
    addTearDown(ready.dispose);

    Widget shell() => MaterialApp(
      home: DesktopCompanionShell(
        windowController: controller,
        hostGateway: host,
        currentRoute: () => '/home',
        petPresentationListenable: ready,
        isPetPresentationReady: readReady,
        isPetPresentationFailed: () => false,
        preparePetPresentation: () async => preparations++,
        child: const SizedBox.shrink(),
      ),
    );

    await tester.pumpWidget(shell());
    await tester.pumpAndSettle();

    expect(preparations, 1);
    expect(host.showGenerations, isEmpty);
    expect(controller.petVisible, isFalse);
    expect(controller.mode, DesktopWindowMode.app);
    expect(gateway.calls, isNot(contains('enterPetMode')));

    await tester.pumpWidget(shell());
    await tester.pumpAndSettle();
    expect(preparations, 1);
    expect(host.showGenerations, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'unchanged ready state cannot repeatedly retry native show failure',
    (tester) async {
      final controller = DesktopWindowModeController(
        gateway: _FakeIndependentDesktopWindowGateway(),
      );
      final host = _FakeDesktopCompanionHostGateway(failShow: true);
      final ready = ValueNotifier<bool>(true);
      bool readReady() => ready.value;
      var preparations = 0;
      addTearDown(controller.dispose);
      addTearDown(host.dispose);
      addTearDown(ready.dispose);

      Widget shell({bool automatic = true}) => MaterialApp(
        home: DesktopCompanionShell(
          windowController: controller,
          hostGateway: host,
          currentRoute: () => '/home',
          autoEnterPetMode: automatic,
          petPresentationListenable: ready,
          isPetPresentationReady: readReady,
          isPetPresentationFailed: () => false,
          preparePetPresentation: () async => preparations++,
          child: const SizedBox.shrink(),
        ),
      );

      // Observe the initial ready state before admitting automatic presentation.
      await tester.pumpWidget(shell(automatic: false));
      await tester.pumpAndSettle();
      ready.notifyListeners();
      await tester.pumpAndSettle();
      expect(host.showGenerations, isEmpty);

      await tester.pumpWidget(shell());
      await tester.pumpAndSettle();
      expect(host.showGenerations, hasLength(1));
      expect(controller.petVisible, isFalse);

      for (var rebuild = 0; rebuild < 4; rebuild++) {
        await tester.pumpWidget(shell());
        await tester.pumpAndSettle();
        expect(host.showGenerations, hasLength(1));
        expect(preparations, 1);
      }
      expect(controller.mode, DesktopWindowMode.app);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('new ready state recovers unavailable presentation once', (
    tester,
  ) async {
    final controller = DesktopWindowModeController(
      gateway: _FakeIndependentDesktopWindowGateway(),
    );
    final host = _FakeDesktopCompanionHostGateway();
    final ready = ValueNotifier<bool>(false);
    bool readReady() => ready.value;
    var preparations = 0;
    addTearDown(controller.dispose);
    addTearDown(host.dispose);
    addTearDown(ready.dispose);

    Widget shell() => MaterialApp(
      home: DesktopCompanionShell(
        windowController: controller,
        hostGateway: host,
        currentRoute: () => '/home',
        petPresentationListenable: ready,
        isPetPresentationReady: readReady,
        isPetPresentationFailed: () => false,
        preparePetPresentation: () async => preparations++,
        child: const SizedBox.shrink(),
      ),
    );

    await tester.pumpWidget(shell());
    await tester.pumpAndSettle();
    expect(preparations, 1);
    expect(host.showGenerations, isEmpty);
    expect(controller.petVisible, isFalse);

    ready.value = true;
    await tester.pumpAndSettle();
    expect(preparations, 2);
    expect(host.showGenerations, hasLength(1));
    expect(controller.petVisible, isTrue);

    for (var rebuild = 0; rebuild < 4; rebuild++) {
      await tester.pumpWidget(shell());
      await tester.pumpAndSettle();
      expect(preparations, 2);
      expect(host.showGenerations, hasLength(1));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'independent host loss clears the visible receipt without reopening closed chat',
    (tester) async {
      final gateway = _FakeIndependentDesktopWindowGateway();
      final controller = DesktopWindowModeController(gateway: gateway);
      final host = _FakeDesktopCompanionHostGateway();
      final route = ValueNotifier<String>('/home');
      final trayGateway = _ClosedChatTrayGateway();
      addTearDown(controller.dispose);
      addTearDown(route.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopCompanionShell(
            windowController: controller,
            hostGateway: host,
            keepAppWindowWithPet: true,
            routeListenable: route,
            currentRoute: () => route.value,
            child: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.petVisible, isTrue);
      final tray = DesktopCompanionTrayController(
        windowController: controller,
        gateway: trayGateway,
        requestShowPet: () => throw StateError('Close must not summon'),
      );
      await tray.handleWindowCloseRequested();
      expect(trayGateway.hidden, isTrue);

      await host.onCommand!(DesktopCompanionHostCommand.hostUnavailable);
      await tester.pumpAndSettle();
      expect(controller.petVisible, isFalse);
      expect(gateway.calls, isNot(contains('enterAppMode')));
      expect(trayGateway.hidden, isTrue);
      final shows = host.showGenerations.length;
      route.value = '/settings';
      await tester.pumpAndSettle();
      route.value = '/home';
      await tester.pumpAndSettle();
      expect(host.showGenerations.length, shows);

      // An explicit visible intent can retry after the native connection heals.
      await controller.showIndependentPet();
      await tester.pumpAndSettle();
      expect(host.showGenerations.length, shows + 1);
      expect(controller.petVisible, isTrue);
      expect(gateway.calls, isNot(contains('enterAppMode')));
      expect(trayGateway.hidden, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'failed native show clears the visible intent and retries without revealing chat',
    (tester) async {
      final gateway = _FakeIndependentDesktopWindowGateway();
      final controller = DesktopWindowModeController(gateway: gateway);
      final host = _FakeDesktopCompanionHostGateway(failShow: true);
      addTearDown(controller.dispose);
      await controller.enterPetMode();
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopCompanionShell(
            windowController: controller,
            hostGateway: host,
            autoEnterPetMode: false,
            currentRoute: () => '/home',
            child: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.mode, DesktopWindowMode.pet);
      expect(controller.petVisible, isFalse);
      expect(gateway.calls, ['enterPetMode']);
      expect(host.showGenerations, hasLength(1));

      host.failShow = false;
      await controller.showIndependentPet();
      await tester.pumpAndSettle();
      expect(controller.petVisible, isTrue);
      expect(gateway.calls, ['enterPetMode']);
      expect(host.showGenerations, hasLength(2));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'Agent space stays responsive when desktop window mode is unsupported',
    (tester) async {
      final controller = _CountingUnsupportedWindowController();
      final route = ValueNotifier<String>('/home');
      final interactionCount = ValueNotifier<int>(0);
      addTearDown(controller.dispose);
      addTearDown(route.dispose);
      addTearDown(interactionCount.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: DesktopCompanionShell(
            windowController: controller,
            petAvailable: true,
            routeListenable: route,
            currentRoute: () => route.value,
            child: Column(
              children: [
                TextButton(
                  key: const ValueKey<String>('unsupported-open-space'),
                  onPressed: () => route.value = '/agent-space',
                  child: const Text('Open Space'),
                ),
                ValueListenableBuilder<String>(
                  valueListenable: route,
                  builder: (_, value, _) => Text(value),
                ),
                TextButton(
                  key: const ValueKey<String>('unsupported-space-action'),
                  onPressed: () => interactionCount.value++,
                  child: const Text('Space action'),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: interactionCount,
                  builder: (_, value, _) => Text('Interactions: $value'),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('unsupported-open-space')),
      );
      await tester.pump();

      expect(controller.mode, DesktopWindowMode.unsupported);
      expect(controller.revealAppModeCalls, 0);
      expect(find.text('/agent-space'), findsOneWidget);
      var nextFrameCompleted = false;
      tester.binding.addPostFrameCallback((_) => nextFrameCompleted = true);
      await tester.pump(const Duration(milliseconds: 16));
      expect(nextFrameCompleted, isTrue);

      await tester.tap(
        find.byKey(const ValueKey<String>('unsupported-space-action')),
      );
      await tester.pump();

      expect(find.text('Interactions: 1'), findsOneWidget);
      expect(controller.revealAppModeCalls, 0);
      expect(find.byType(DesktopPetStage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Agent space temporarily hides the native pet and restores its visible intent',
    (tester) async {
      final gateway = _FakeIndependentDesktopWindowGateway();
      final controller = DesktopWindowModeController(gateway: gateway);
      final host = _FakeDesktopCompanionHostGateway();
      final route = ValueNotifier<String>('/home');
      addTearDown(controller.dispose);
      addTearDown(host.dispose);
      addTearDown(route.dispose);

      await controller.enterPetMode();
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopCompanionShell(
            windowController: controller,
            autoEnterPetMode: false,
            routeListenable: route,
            currentRoute: () => route.value,
            hostGateway: host,
            onDestinationSelected: (entry) {
              route.value = entry.destination.route;
            },
            child: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(host.calls.where((call) => call == 'show'), hasLength(1));

      await host.onMenuSelected!('agent_space');
      await tester.pumpAndSettle();

      expect(controller.mode, DesktopWindowMode.app);
      expect(controller.petVisible, isTrue);
      expect(route.value, '/agent-space');
      expect(host.calls, containsAllInOrder(<String>['clearBubble', 'hide']));
      expect(host.calls.where((call) => call == 'show'), hasLength(1));

      final hideCount = host.calls.where((call) => call == 'hide').length;
      route.value = '/settings';
      await tester.pumpAndSettle();

      expect(controller.petVisible, isTrue);
      expect(host.calls.where((call) => call == 'show'), hasLength(2));

      route.value = '/about';
      await tester.pumpAndSettle();
      expect(host.calls.where((call) => call == 'hide'), hasLength(hideCount));
    },
  );

  testWidgets('leaving Agent space does not restore a pet hidden by the user', (
    tester,
  ) async {
    final gateway = _FakeIndependentDesktopWindowGateway();
    final controller = DesktopWindowModeController(gateway: gateway);
    final host = _FakeDesktopCompanionHostGateway();
    final route = ValueNotifier<String>('/home');
    addTearDown(controller.dispose);
    addTearDown(host.dispose);
    addTearDown(route.dispose);

    await controller.enterPetMode();
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopCompanionShell(
          windowController: controller,
          routeListenable: route,
          currentRoute: () => route.value,
          hostGateway: host,
          child: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    route.value = '/agent-space';
    await tester.pumpAndSettle();
    await host.onCommand!(DesktopCompanionHostCommand.hidePet);
    await tester.pumpAndSettle();
    expect(controller.petVisible, isFalse);

    final showCount = host.calls.where((call) => call == 'show').length;
    route.value = '/home';
    await tester.pumpAndSettle();

    expect(controller.petVisible, isFalse);
    expect(host.calls.where((call) => call == 'show'), hasLength(showCount));
  });

  testWidgets(
    'native Avatar interactions require the shown generation and never enter Agent space',
    (tester) async {
      final gateway = _FakeIndependentDesktopWindowGateway();
      final controller = DesktopWindowModeController(gateway: gateway);
      final host = _FakeDesktopCompanionHostGateway();
      final route = ValueNotifier<String>('/home');
      final applied = <String>[];
      final interactionCoordinator = AvatarInteractionCoordinator(
        applyReaction: (reaction) async {
          applied.add('reaction:${reaction.gesture}');
          return const AvatarBehaviorResult(applied: true, reason: 'test');
        },
        applyAct: (act) async {
          applied.add('act:${act.gesture}');
          return const AvatarBehaviorResult(applied: true, reason: 'test');
        },
      );
      addTearDown(controller.dispose);
      addTearDown(host.dispose);
      addTearDown(route.dispose);

      await controller.enterPetMode();
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopCompanionShell(
            windowController: controller,
            autoEnterPetMode: false,
            routeListenable: route,
            currentRoute: () => route.value,
            hostGateway: host,
            avatarInteractionCoordinator: interactionCoordinator,
            child: const SizedBox.shrink(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final firstGeneration = host.showGenerations.single;

      await host.onInteraction!(
        DesktopAvatarInteractionV1(
          normalizedX: 0.5,
          normalizedY: 0.2,
          region: DesktopAvatarInteractionRegion.head,
          generation: firstGeneration,
          timestampMs: 1,
        ),
      );
      expect(applied, <String>['reaction:nod']);

      route.value = '/agent-space';
      await tester.pumpAndSettle();
      await host.onInteraction!(
        DesktopAvatarInteractionV1(
          normalizedX: 0.5,
          normalizedY: 0.2,
          region: DesktopAvatarInteractionRegion.head,
          generation: firstGeneration,
          timestampMs: 2,
        ),
      );
      expect(applied, <String>['reaction:nod']);

      route.value = '/settings';
      await tester.pumpAndSettle();
      final secondGeneration = host.showGenerations.last;
      expect(secondGeneration, isNot(firstGeneration));
      await host.onInteraction!(
        DesktopAvatarInteractionV1(
          normalizedX: 0.5,
          normalizedY: 0.5,
          region: DesktopAvatarInteractionRegion.avatar,
          generation: secondGeneration,
          timestampMs: 3,
        ),
      );
      expect(applied, <String>['reaction:nod', 'act:wave']);

      route.value = '/login';
      await tester.pumpAndSettle();
      await host.onInteraction!(
        DesktopAvatarInteractionV1(
          normalizedX: 0.5,
          normalizedY: 0.5,
          region: DesktopAvatarInteractionRegion.avatar,
          generation: secondGeneration,
          timestampMs: 4,
        ),
      );
      expect(applied, <String>['reaction:nod', 'act:wave']);
    },
  );
}

class _ClosedChatTrayGateway implements DesktopCompanionTrayGateway {
  bool hidden = false;

  @override
  Future<void> initialize({
    required Future<void> Function() onIconActivated,
    required Future<void> Function() onWindowCloseRequested,
    required Future<void> Function(DesktopCompanionTrayCommand) onCommand,
  }) async {}

  @override
  Future<void> hide() async => hidden = true;

  @override
  Future<void> showAndFocus() async => hidden = false;

  @override
  Future<void> quit() async {}

  @override
  Future<void> dispose() async {}
}

class _CountingUnsupportedWindowController extends DesktopWindowModeController {
  _CountingUnsupportedWindowController()
    : super(gateway: _UnsupportedDesktopWindowGateway());

  int revealAppModeCalls = 0;

  @override
  Future<void> revealAppMode() async {
    revealAppModeCalls++;
    if (revealAppModeCalls > 1) {
      // Bound the regression's microtask retry loop so the old implementation
      // fails the zero-call assertion instead of hanging the test runner.
      throw StateError('Unsupported window reveal was retried');
    }
    await super.revealAppMode();
  }
}

class _UnsupportedDesktopWindowGateway extends _FakeDesktopWindowGateway {
  @override
  bool get isSupported => false;
}

class _FakeDesktopWindowGateway implements DesktopWindowGateway {
  final List<String> calls = <String>[];

  @override
  bool get isSupported => true;

  @override
  Future<DesktopWindowBounds> readBounds() async =>
      const DesktopWindowBounds(left: 20, top: 20, width: 1000, height: 700);

  @override
  Future<void> enterPetMode() async {
    calls.add('enterPetMode');
  }

  @override
  Future<void> enterAppMode({DesktopWindowBounds? restoreBounds}) async {
    calls.add('enterAppMode');
  }

  @override
  Future<void> startDragging() async {
    calls.add('startDragging');
  }
}

class _FakeIndependentDesktopWindowGateway extends _FakeDesktopWindowGateway
    implements IndependentDesktopPetWindowGateway {
  @override
  bool get supportsIndependentPetWindow => true;
}

class _SequencedIndependentDesktopWindowGateway
    extends _FakeIndependentDesktopWindowGateway {
  _SequencedIndependentDesktopWindowGateway(this.transitionOrder);

  final List<String> transitionOrder;

  @override
  Future<void> enterPetMode() async {
    transitionOrder.add('enterPetMode');
    await super.enterPetMode();
  }
}

class _FakeDesktopCompanionHostGateway implements DesktopCompanionHostGateway {
  _FakeDesktopCompanionHostGateway({this.failShow = false});

  bool failShow;
  final List<String> calls = <String>[];
  FutureOr<void> Function(String id)? onMenuSelected;
  FutureOr<void> Function(DesktopCompanionHostCommand command)? onCommand;
  FutureOr<void> Function(Offset? gaze)? onGazeChanged;
  FutureOr<void> Function(DesktopAvatarInteractionV1 interaction)?
  onInteraction;
  final List<int> showGenerations = <int>[];

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize({
    required FutureOr<void> Function(String id) onMenuSelected,
    required FutureOr<void> Function(DesktopCompanionHostCommand command)
    onCommand,
    required FutureOr<void> Function(Offset? gaze) onGazeChanged,
    required FutureOr<void> Function(DesktopAvatarInteractionV1 interaction)
    onInteraction,
  }) async {
    this.onMenuSelected = onMenuSelected;
    this.onCommand = onCommand;
    this.onGazeChanged = onGazeChanged;
    this.onInteraction = onInteraction;
    calls.add('initialize');
  }

  @override
  Future<void> configureMenu(List<DesktopCompanionHostMenuItem> items) async {
    calls.add('configureMenu:${items.length}');
  }

  @override
  Future<void> configurePresentation(
    DesktopCompanionPresentationConfigV1 config,
  ) async {
    calls.add(
      'configurePresentation:${config.quality.wireName}:${config.targetFps}',
    );
  }

  @override
  Future<void> show({required int interactionGeneration}) async {
    showGenerations.add(interactionGeneration);
    calls.add('show');
    if (failShow) throw StateError('native pet unavailable');
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
  }

  @override
  Future<void> showBubble(String text) async {
    calls.add('bubble:$text');
  }

  @override
  Future<void> clearBubble() async {
    calls.add('clearBubble');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
  }
}

class _StartupGatedDesktopCompanionHostGateway
    extends _FakeDesktopCompanionHostGateway {
  _StartupGatedDesktopCompanionHostGateway(this.transitionOrder);

  final List<String> transitionOrder;
  final Completer<void> initializationStarted = Completer<void>();
  final Completer<void> allowInitialization = Completer<void>();
  final Completer<void> showStarted = Completer<void>();
  final Completer<void> allowFirstFrame = Completer<void>();

  @override
  Future<void> initialize({
    required FutureOr<void> Function(String id) onMenuSelected,
    required FutureOr<void> Function(DesktopCompanionHostCommand command)
    onCommand,
    required FutureOr<void> Function(Offset? gaze) onGazeChanged,
    required FutureOr<void> Function(DesktopAvatarInteractionV1 interaction)
    onInteraction,
  }) async {
    if (!initializationStarted.isCompleted) initializationStarted.complete();
    await allowInitialization.future;
    await super.initialize(
      onMenuSelected: onMenuSelected,
      onCommand: onCommand,
      onGazeChanged: onGazeChanged,
      onInteraction: onInteraction,
    );
  }

  @override
  Future<void> show({required int interactionGeneration}) async {
    transitionOrder.add('show:start');
    if (!showStarted.isCompleted) showStarted.complete();
    await allowFirstFrame.future;
    await super.show(interactionGeneration: interactionGeneration);
    transitionOrder.add('show:complete');
  }
}
