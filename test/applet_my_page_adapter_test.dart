import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_my_page_adapter.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';
import 'package:maaso/src/features/widgets_hub/presentation/widgets_hub_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AgentUiControlCoordinator coordinator;
  late _Target target;
  late AppletMyPageAdapter adapter;
  late AgentUiControlLease lease;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    coordinator = AgentUiControlCoordinator();
    target = _Target();
    adapter = AppletMyPageAdapter(coordinator: coordinator, target: target);
    lease = coordinator
        .begin(
          sessionId: 'applets',
          purpose: 'Use my applet',
          targetRoute: '/my-applets',
        )
        .value!;
  });
  tearDown(() async {
    await coordinator.dispose();
    await appServices.reset();
  });

  Future<AgentUiControlResult<Map<String, Object?>>> run(
    String action, [
    Map<String, Object?> args = const {},
  ]) => adapter.executeAppControlAction(
    lease: lease,
    actionId: action,
    arguments: args,
    executionContext: AppControlActionExecutionContext.host(
      requiresCommit: false,
      authorityIsCurrent: () => true,
      staleCode: 'stale',
    ),
  );

  test(
    'declares visible safe actions and rejects all publishing/deletion bypasses',
    () async {
      expect(adapter.appControlActions.map((action) => action.id), [
        'read_my_applets',
        'read_applet_versions',
        'open_applet',
        'prepare_edit',
        'open_version_history',
      ]);
      expect(
        adapter.appControlActions.every((action) => !action.requiresApproval),
        isTrue,
      );
      for (final action in [
        'publish',
        'delete',
        'publish_applet',
        'delete_applet',
        'restore_version',
        'publish_version',
      ]) {
        expect(
          (await run(action, {'id': 7})).status,
          AgentUiControlResultStatus.invalidState,
        );
      }
      expect(target.opened, isEmpty);
      expect(target.edited, isEmpty);
    },
  );

  test('reads only visible rows and uses bounded stable IDs', () async {
    expect((await run('read_my_applets')).value, {
      'items': [
        {'id': 7, 'title': 'Trip planner'},
      ],
    });
    expect((await run('open_applet', {'id': 7})).isSuccess, isTrue);
    expect((await run('prepare_edit', {'id': 7})).isSuccess, isTrue);
    expect(target.opened, [7]);
    expect(target.edited, [7]);
    for (final args in <Map<String, Object?>>[
      {'id': 0},
      {'id': '7'},
      {'id': 7, 'script': 'anything'},
      {'id': 2147483648},
    ]) {
      expect(
        (await run('prepare_edit', args)).status,
        AgentUiControlResultStatus.invalidState,
      );
    }
    expect((await run('prepare_edit', {'id': 8})).reason, 'page_not_ready');
  });

  test('removed row, detached page, and changed scope cannot edit', () async {
    target.items.clear();
    expect((await run('prepare_edit', {'id': 7})).reason, 'page_not_ready');
    target.items.add(_item());
    target.ready = false;
    expect((await run('prepare_edit', {'id': 7})).reason, 'page_not_ready');
    target.ready = true;
    adapter.detach();
    expect((await run('prepare_edit', {'id': 7})).reason, 'page_not_ready');
    expect(target.edited, isEmpty);
  });

  test(
    'reads only immutable version metadata and opens visible history',
    () async {
      final result = await run('read_applet_versions', {'id': 7});
      expect(result.isSuccess, isTrue);
      final versions = result.value!['versions'] as List;
      expect(versions, hasLength(1));
      expect(versions.single.keys.toSet(), {'id', 'number', 'current'});
      expect(versions.single['number'], 1);
      expect((await run('open_version_history', {'id': 7})).isSuccess, isTrue);
      expect(target.histories, [7]);
    },
  );

  test('user takeover prevents a queued history operation', () async {
    target.blocker = Completer<void>();
    final pending = run('open_version_history', {'id': 7});
    await target.started.future;
    coordinator.pauseForUserActivity(reason: 'pointer_down');
    target.blocker!.complete();
    expect((await pending).reason, 'paused_by_user');
    expect(target.histories, isEmpty);
  });

  test('wrong route cannot operate the My page', () async {
    await coordinator.dispose();
    coordinator = AgentUiControlCoordinator();
    adapter = AppletMyPageAdapter(coordinator: coordinator, target: target);
    lease = coordinator
        .begin(
          sessionId: 'other',
          purpose: 'Other',
          targetRoute: '/widgets-hub',
        )
        .value!;
    expect((await run('open_applet', {'id': 7})).reason, 'page_not_ready');
  });

  test('user takeover while edit prepares prevents navigation', () async {
    target.blocker = Completer<void>();
    final pending = run('prepare_edit', {'id': 7});
    await target.started.future;
    coordinator.pauseForUserActivity(reason: 'pointer_down');
    target.blocker!.complete();
    expect((await pending).reason, 'paused_by_user');
    expect(target.edited, isEmpty);
  });

  testWidgets(
    'My route registers adapter on mount and releases it on disposal',
    (tester) async {
      appServices.put<DBService>(_DB());
      appServices.put(WidgetsHubController());
      final ui = AgentUiControlService(coordinator: coordinator);
      appServices.put<AgentUiControlService>(ui);
      await tester.pumpWidget(const MaterialApp(home: MyAppletsPage()));
      await tester.pumpAndSettle();
      expect(ui.adapters.length, 1);
      expect(find.byKey(const ValueKey('my-applets-list')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(ui.adapters.length, 0);
    },
  );
}

AgentWidget _item() => AgentWidget(
  id: 7,
  agentId: 'self',
  title: 'Trip planner',
  kind: 'surface',
  spec: {'surfaceId': 'trip', 'experienceType': 'utility'},
  createdAt: DateTime.utc(2026),
);

class _Target implements AppletMyPageTarget {
  bool ready = true;
  final items = [_item()];
  final opened = <int>[];
  final edited = <int>[];
  final histories = <int>[];
  final started = Completer<void>();
  Completer<void>? blocker;
  @override
  bool get isReady => ready;
  @override
  List<AgentWidget> get visibleLocalApplets => items;
  @override
  Future<void> openApplet(
    AgentWidget item, {
    required bool Function() canContinue,
  }) async {
    if (canContinue()) opened.add(item.id!);
  }

  @override
  Future<void> openVersionHistory(
    AgentWidget item, {
    required bool Function() canContinue,
  }) async {
    if (!started.isCompleted) started.complete();
    if (blocker != null) await blocker!.future;
    if (canContinue()) histories.add(item.id!);
  }

  @override
  Future<bool> prepareAppletEdit(
    AgentWidget item, {
    required bool Function() canContinue,
  }) async {
    if (!started.isCompleted) started.complete();
    if (blocker != null) await blocker!.future;
    if (!canContinue()) return false;
    edited.add(item.id!);
    return true;
  }
}

class _DB extends DBService {
  @override
  Future<List<AgentWidget>> getAllWidgets() async => [];
}
