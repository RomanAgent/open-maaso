import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';
import 'package:maaso/src/features/agent_space/application/agent_space_page_adapter.dart';

void main() {
  test('the adapter declares only visible reversible exit', () {
    final coordinator = AgentUiControlCoordinator();
    addTearDown(coordinator.dispose);
    final adapter = AgentSpacePageAdapter(
      coordinator: coordinator,
      target: _Target(),
    );
    expect(adapter.route, AppRouteCatalog.agentSpace);
    expect(adapter.appControlActions.map((action) => action.id), ['exit']);
    final exit = adapter.actionById('exit')!;
    expect(exit.requiresApproval, isFalse);
    expect(exit.argumentsSchema['additionalProperties'], isFalse);
    expect(adapter.actionById('select_map'), isNull);
    expect(adapter.actionById('move'), isNull);
    expect(adapter.actionById('send_message'), isNull);
  });

  test('exit shares the coordinator and rejects extra arguments', () async {
    final h = _Harness();
    addTearDown(h.coordinator.dispose);
    expect(
      (await h.call(arguments: {'mapId': 'cafe_garden'})).isSuccess,
      isFalse,
    );
    expect(h.target.exits, 0);
    final result = await h.call();
    expect(result.isSuccess, isTrue);
    expect(result.value, {'route': AppRouteCatalog.home});
    expect(h.target.exits, 1);
  });

  test(
    'user takeover or stale execution authority blocks navigation',
    () async {
      final h = _Harness();
      addTearDown(h.coordinator.dispose);
      h.authority = false;
      expect((await h.call()).isSuccess, isFalse);
      expect(h.target.exits, 0);

      final takeover = _Harness();
      addTearDown(takeover.coordinator.dispose);
      expect(
        takeover.coordinator.pauseForUserActivity(reason: 'pointer_down'),
        isTrue,
      );
      expect((await takeover.call()).isSuccess, isFalse);
      expect(takeover.target.exits, 0);
    },
  );

  test('covered, leaving, and detached targets cannot exit', () async {
    final h = _Harness();
    addTearDown(h.coordinator.dispose);
    h.target.ready = false;
    expect((await h.call()).status, AgentUiControlResultStatus.pageNotReady);
    h.target.ready = true;
    h.adapter.detach();
    expect((await h.call()).status, AgentUiControlResultStatus.pageNotReady);
    expect(h.target.exits, 0);
  });

  test('route registration cannot be reused after page replacement', () {
    final h = _Harness();
    addTearDown(h.coordinator.dispose);
    final registry = PageAgentAdapterRegistry(coordinator: h.coordinator);
    final original = registry.register(h.adapter);
    final replacement = registry.register(
      AgentSpacePageAdapter(coordinator: h.coordinator, target: _Target()),
    );
    expect(original.unregister(), isFalse);
    expect(registry.length, 1);
    expect(replacement.unregister(), isTrue);
    expect(registry.length, 0);
    expect(
      registry
          .resolve<AgentSpacePageAdapter>(
            route: AppRouteCatalog.agentSpace,
            lease: h.lease,
          )
          .status,
      AgentUiControlResultStatus.pageNotReady,
    );
  });
}

class _Harness {
  _Harness() {
    adapter = AgentSpacePageAdapter(coordinator: coordinator, target: target);
    lease = coordinator
        .begin(
          sessionId: 'space-test',
          purpose: 'return Home',
          targetRoute: AppRouteCatalog.agentSpace,
        )
        .value!;
  }

  final coordinator = AgentUiControlCoordinator();
  final target = _Target();
  late final AgentSpacePageAdapter adapter;
  late final AgentUiControlLease lease;
  bool authority = true;

  Future<AgentUiControlResult<Map<String, Object?>>> call({
    Map<String, Object?> arguments = const {},
  }) => adapter.executeAppControlAction(
    lease: lease,
    actionId: 'exit',
    arguments: arguments,
    executionContext: AppControlActionExecutionContext.host(
      requiresCommit: false,
      authorityIsCurrent: () => authority,
      staleCode: 'stale',
    ),
  );
}

class _Target implements AgentSpacePageTarget {
  bool ready = true;
  int exits = 0;

  @override
  bool get canExitAgentSpace => ready;

  @override
  void exitAgentSpace() => exits++;
}
