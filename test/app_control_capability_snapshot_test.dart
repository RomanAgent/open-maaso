import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/skills/app_control_skill.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('schema, discovery, and execution share one web snapshot', () async {
    final service = _service(AppHostPlatform.web);
    final coordinator = AgentUiControlCoordinator();
    final uiControl = AgentUiControlService(coordinator: coordinator);
    final navigation = _FakeNavigation();
    final skill = _skill(
      service: service,
      navigation: navigation,
      uiControl: uiControl,
    );

    final pageEnum =
        (skill.nativeToolSchemas['execute']!['properties']
                as Map<String, Object?>)['page']
            as Map<String, Object?>;
    expect(pageEnum['enum'], isNot(contains('advanced_features')));

    final listed = _decode(
      skill.methods['listCapabilities']!(const <Object>[]) as String,
    );
    final pages = (listed['pages']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .map((page) => page['id'])
        .toList(growable: false);
    expect(pages, isNot(contains('advanced_features')));

    final result = await _execute(skill, <String, Object?>{
      'page': 'advanced_features',
    });
    expect(result['error'], 'unavailable_page');
    expect(
      result['reasons'],
      contains('required_capability_unavailable:advanced_ai_settings'),
    );
    expect(navigation.pushes, isEmpty);

    service.closeLifecycle();
    await coordinator.dispose();
  });

  test(
    'the same AppControl instance acquires a fresh lease per call',
    () async {
      final service = _service(AppHostPlatform.macos);
      final coordinator = AgentUiControlCoordinator();
      final uiControl = AgentUiControlService(coordinator: coordinator);
      final navigation = _FakeNavigation();
      final skill = _skill(
        service: service,
        navigation: navigation,
        uiControl: uiControl,
      );

      expect(
        (skill.nativeToolSchemas['execute']!['properties']
            as Map<String, Object?>)['page'],
        isNotNull,
      );
      service.refresh(service.context.copyWith(rolloutGeneration: 1));

      final result = await _execute(skill, <String, Object?>{
        'page': 'settings',
      });
      expect(result['status'], 'ok');
      expect(result['capabilityGeneration'], service.value.generation);
      expect(navigation.pushes, <String>[AppRouteCatalog.settings]);

      service.closeLifecycle();
      await coordinator.dispose();
    },
  );

  test('navigation cannot complete across a snapshot generation', () async {
    final service = _service(AppHostPlatform.macos);
    final coordinator = AgentUiControlCoordinator();
    final uiControl = AgentUiControlService(coordinator: coordinator);
    final navigation = _FakeNavigation();
    final routeReadinessEntered = Completer<void>();
    final releaseRouteReadiness = Completer<void>();
    final skill = _skill(
      service: service,
      navigation: navigation,
      uiControl: uiControl,
      routeReadinessBarrier: () async {
        if (!routeReadinessEntered.isCompleted) {
          routeReadinessEntered.complete();
        }
        await releaseRouteReadiness.future;
      },
    );

    final execution = _execute(skill, <String, Object?>{'page': 'settings'});
    await routeReadinessEntered.future;
    service.refresh(service.context.copyWith(rolloutGeneration: 1));
    releaseRouteReadiness.complete();

    final result = await execution;
    expect(result['error'], 'capability_stale');
    expect(result['reasons'], contains('capability_snapshot_stale'));
    expect(navigation.pushes, <String>[AppRouteCatalog.settings]);

    service.closeLifecycle();
    await coordinator.dispose();
  });

  test('page action requirements fail before the adapter executes', () async {
    final service = _service(AppHostPlatform.web);
    final coordinator = AgentUiControlCoordinator();
    final uiControl = AgentUiControlService(coordinator: coordinator);
    final adapter = _RestrictedPageAdapter();
    PageAgentAdapterRegistration<_RestrictedPageAdapter>? registration;
    final navigation = _FakeNavigation(
      onPush: (_) => registration = uiControl.adapters.register(adapter),
    );
    final skill = _skill(
      service: service,
      navigation: navigation,
      uiControl: uiControl,
    );

    final result = await _execute(skill, <String, Object?>{
      'page': 'widgets_hub',
      'action': 'desktop_only',
      'arguments': const <String, Object?>{},
    });
    expect(result['error'], 'unavailable_action');
    expect(result['reasons'], contains('unsupported_host_platform'));
    expect(adapter.executions, 0);

    registration?.unregister();
    service.closeLifecycle();
    await coordinator.dispose();
  });
}

AppCapabilitySnapshotService _service(AppHostPlatform platform) =>
    AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(
        routeIds: AppRouteCatalog.destinations.map(
          (destination) => destination.id,
        ),
        skillIds: const <String>{'app_control'},
      ),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: platform,
        rolloutGeneration: 0,
      ),
    );

AppControlSkill _skill({
  required AppCapabilitySnapshotService service,
  required AppNavigation navigation,
  required AgentUiControlService uiControl,
  Future<void> Function()? routeReadinessBarrier,
}) => AppControlSkill(
  capabilitySnapshotService: service,
  navigation: navigation,
  uiControl: uiControl,
  routeReadinessBarrier: routeReadinessBarrier ?? () async {},
  routeReadinessTimeout: const Duration(milliseconds: 200),
);

Future<Map<String, Object?>> _execute(
  AppControlSkill skill,
  Map<String, Object?> payload,
) async => _decode(
  await skill.methods['execute']!(<Object>[jsonEncode(payload)]) as String,
);

Map<String, Object?> _decode(String raw) =>
    Map<String, Object?>.from(jsonDecode(raw) as Map);

final class _FakeNavigation extends AppNavigation {
  _FakeNavigation({this.onPush});

  final void Function(String route)? onPush;
  final List<String> pushes = <String>[];
  final Completer<Object?> _pendingPush = Completer<Object?>();
  String _currentRoute = AppRouteCatalog.home;

  @override
  bool get isConfigured => true;

  @override
  String get currentRoute => _currentRoute;

  @override
  Future<T?> push<T extends Object?>(String route, {Object? extra}) {
    pushes.add(route);
    _currentRoute = route;
    onPush?.call(route);
    return _pendingPush.future.then((value) => value as T?);
  }
}

final class _RestrictedPageAdapter implements AppControlPageAdapter {
  int executions = 0;

  @override
  String get route => AppRouteCatalog.widgetsHub;

  @override
  late final List<AppControlPageAction> appControlActions =
      <AppControlPageAction>[
        AppControlPageAction(
          id: 'desktop_only',
          description: 'A desktop-only local action.',
          argumentsSchema: const <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{},
            'additionalProperties': false,
          },
          resultSchema: const <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{},
            'additionalProperties': false,
          },
          risk: ActionRisk.localMutation,
          consequencePolicy: ActionConsequencePolicy.reversible,
          requiredCapabilities: <AppCapabilityKey>[
            AppCapabilityKey.platformAction(
              AppActionCapability.advancedAiSettings,
            ),
          ],
        ),
      ];

  @override
  Future<AgentUiControlResult<Map<String, Object?>>> executeAppControlAction({
    required AgentUiControlLease lease,
    required String actionId,
    required Map<String, Object?> arguments,
    required AppControlActionExecutionContext executionContext,
  }) async {
    executions += 1;
    return const AgentUiControlResult<Map<String, Object?>>.success(
      <String, Object?>{},
    );
  }
}
