import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skills/app_control_skill.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppControl.execute', () {
    late AgentUiControlCoordinator coordinator;
    late AgentUiControlService uiControl;
    PageAgentAdapterRegistration<_FakePageAdapter>? registration;

    setUp(() {
      coordinator = AgentUiControlCoordinator();
      uiControl = AgentUiControlService(coordinator: coordinator);
    });

    tearDown(() async {
      registration?.unregister();
      await coordinator.dispose();
    });

    test(
      'visibly navigates to a catalog page without awaiting route pop',
      () async {
        final navigation = _FakeAppNavigation();
        final skill = _skill(navigation: navigation, uiControl: uiControl);

        final result = await _execute(skill, <String, Object?>{
          'page': 'settings',
        });

        expect(result, <String, Object?>{
          'status': 'ok',
          'page': 'settings',
          'route': '/settings',
        });
        expect(navigation.pushes, <String>['/settings']);
        expect(navigation.pushCompleted, isFalse);
        expect(coordinator.snapshot.phase, AgentUiControlPhase.completed);
      },
    );

    test(
      'executes only an action declared by the mounted page adapter',
      () async {
        late final _FakePageAdapter adapter;
        final navigation = _FakeAppNavigation(
          onPush: (route) {
            adapter = _FakePageAdapter();
            registration = uiControl.adapters.register(adapter);
          },
        );
        final skill = _skill(navigation: navigation, uiControl: uiControl);

        final result = await _execute(skill, <String, Object?>{
          'page': 'widgets_hub',
          'action': 'compose_post',
          'arguments': <String, Object?>{'topic': 'A股'},
        });

        expect(result['status'], 'ok');
        expect(result['confirmation_required'], 'exact_public_text');
        expect(result['published'], isFalse);
        expect(result['route'], '/widgets-hub');
        expect(adapter.calls, <Map<String, Object?>>[
          <String, Object?>{'topic': 'A股'},
        ]);
        expect(coordinator.snapshot.phase, AgentUiControlPhase.completed);
      },
    );

    test('fails closed for an undeclared action', () async {
      final navigation = _FakeAppNavigation(
        onPush: (_) {
          registration = uiControl.adapters.register(_FakePageAdapter());
        },
      );
      final skill = _skill(navigation: navigation, uiControl: uiControl);

      final result = await _execute(skill, <String, Object?>{
        'page': 'widgets_hub',
        'action': 'delete_everything',
      });

      expect(result['status'], 'error');
      expect(result['error'], 'unknown_action');
      expect(coordinator.snapshot.phase, AgentUiControlPhase.failed);
    });

    test('fails closed when an action page adapter never mounts', () async {
      final navigation = _FakeAppNavigation();
      final skill = AppControlSkill(
        navigation: navigation,
        uiControl: uiControl,
        routeReadinessBarrier: () async {},
        routeReadinessTimeout: Duration.zero,
      );

      final result = await _execute(skill, <String, Object?>{
        'page': 'widgets_hub',
        'action': 'compose_post',
        'arguments': <String, Object?>{'topic': 'A股'},
      });

      expect(result['status'], 'error');
      expect(result['error'], 'page_not_ready');
      expect(coordinator.snapshot.phase, AgentUiControlPhase.failed);
    });

    test('user takeover during route readiness aborts the lease', () async {
      var paused = false;
      final skill = _skill(
        navigation: _FakeAppNavigation(),
        uiControl: uiControl,
        routeBarrier: () async {
          if (paused) return;
          paused = true;
          coordinator.pauseForUserActivity(reason: 'pointer_down');
        },
      );

      final result = await _execute(skill, <String, Object?>{
        'page': 'settings',
      });

      expect(result['status'], 'error');
      expect(result['error'], 'paused_by_user');
      expect(coordinator.snapshot.phase, AgentUiControlPhase.pausedByUser);
    });

    test('peer agents cannot control the owner app', () async {
      final navigation = _FakeAppNavigation();
      final skill = AppControlSkill(
        agentId: 'peer-1',
        navigation: navigation,
        uiControl: uiControl,
      );

      final result = await _execute(skill, <String, Object?>{
        'page': 'settings',
      });

      expect(result['error'], 'owner_only');
      expect(navigation.pushes, isEmpty);
      expect(coordinator.snapshot.phase, AgentUiControlPhase.idle);
    });

    test('catalog registers AppControl as a core Host Skill', () {
      final spec = SkillCatalog.byId('app_control');

      expect(spec, isNotNull);
      expect(spec!.isCore, isTrue);
      expect(SkillCatalog.defaultEnabled, contains('app_control'));
      expect(spec.hostRouting?.skillName, 'AppControl');
      expect(spec.hostRouting?.nativeMethods, contains('execute'));
      expect(spec.factory!('self').skillName, 'AppControl');
    });

    test('listCapabilities follows the destination catalog', () {
      final skill = _skill(
        navigation: _FakeAppNavigation(),
        uiControl: uiControl,
      );

      final raw = skill.methods['listCapabilities']!(const <Object>[]);
      final decoded = Map<String, Object?>.from(
        jsonDecode(raw as String) as Map,
      );
      final pages = (decoded['pages']! as List)
          .cast<Map>()
          .map((page) => page['id'])
          .toList(growable: false);

      expect(pages, containsAll(<String>['settings', 'widgets_hub']));
      expect(pages, hasLength(AppRouteCatalog.destinations.length));
    });
  });
}

AppControlSkill _skill({
  required AppNavigation navigation,
  required AgentUiControlService uiControl,
  Future<void> Function()? routeBarrier,
}) => AppControlSkill(
  navigation: navigation,
  uiControl: uiControl,
  routeReadinessBarrier: routeBarrier ?? () async {},
  routeReadinessTimeout: const Duration(milliseconds: 200),
);

Future<Map<String, Object?>> _execute(
  AppControlSkill skill,
  Map<String, Object?> payload,
) async {
  final raw = await skill.methods['execute']!(<Object>[jsonEncode(payload)]);
  return Map<String, Object?>.from(jsonDecode(raw as String) as Map);
}

class _FakeAppNavigation extends AppNavigation {
  _FakeAppNavigation({this.onPush});

  final void Function(String route)? onPush;
  final List<String> pushes = <String>[];
  final Completer<Object?> _pendingPush = Completer<Object?>();
  String _currentRoute = '/home';

  bool get pushCompleted => _pendingPush.isCompleted;

  @override
  bool get isConfigured => true;

  @override
  String get currentRoute => _currentRoute;

  @override
  Future<T?> push<T extends Object?>(String route, {Object? extra}) {
    pushes.add(route);
    _currentRoute = route;
    onPush?.call(route);
    return _pendingPush.future.then<T?>((value) => value as T?);
  }
}

class _FakePageAdapter implements AppControlPageAdapter {
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

  late final List<AppControlPageAction> _actions = <AppControlPageAction>[
    AppControlPageAction(
      id: 'compose_post',
      description: 'Prepare a visible post draft.',
      argumentsSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'topic': <String, Object?>{'type': 'string'},
        },
        'required': <String>['topic'],
        'additionalProperties': false,
      },
      resultSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'status': <String, Object?>{'const': 'confirmation_required'},
          'confirmation_required': <String, Object?>{
            'const': 'exact_public_text',
          },
          'published': <String, Object?>{'const': false},
        },
        'required': <String>['status', 'confirmation_required', 'published'],
        'additionalProperties': false,
      },
      risk: ActionRisk.localMutation,
      consequencePolicy: ActionConsequencePolicy.prepareOnly,
    ),
  ];

  @override
  String get route => '/widgets-hub';

  @override
  List<AppControlPageAction> get appControlActions => _actions;

  @override
  Future<AgentUiControlResult<Map<String, Object?>>> executeAppControlAction({
    required AgentUiControlLease lease,
    required String actionId,
    required Map<String, Object?> arguments,
    required AppControlActionExecutionContext executionContext,
  }) async {
    executionContext.checkpoint();
    calls.add(Map<String, Object?>.from(arguments));
    return const AgentUiControlResult<Map<String, Object?>>.success(
      <String, Object?>{
        'status': 'confirmation_required',
        'confirmation_required': 'exact_public_text',
        'published': false,
      },
    );
  }
}
