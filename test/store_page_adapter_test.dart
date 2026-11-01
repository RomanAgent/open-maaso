import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/store/application/store_page_adapter.dart';
import 'package:maaso/src/features/store/presentation/store_hub_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AgentUiControlCoordinator coordinator;
  late AgentUiControlLease lease;
  late _Target target;
  late StorePageAdapter adapter;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    coordinator = AgentUiControlCoordinator();
    target = _Target();
    adapter = StorePageAdapter(
      route: '/skill-store',
      coordinator: coordinator,
      target: target,
    );
    lease = coordinator
        .begin(
          sessionId: 'store',
          purpose: 'Browse assets',
          targetRoute: '/skill-store',
        )
        .value!;
  });
  tearDown(() async {
    await coordinator.dispose();
    await appServices.reset();
  });
  Future<AgentUiControlResult<Map<String, Object?>>> run(
    String action, [
    Map<String, Object?> arguments = const {},
  ]) => adapter.executeAppControlAction(
    lease: lease,
    actionId: action,
    arguments: arguments,
    executionContext: AppControlActionExecutionContext.host(
      requiresCommit: false,
      authorityIsCurrent: () => true,
      staleCode: 'stale',
    ),
  );

  test('reads and selects only the two visible sections', () async {
    expect((await run('read_store_sections')).value, {
      'section': 'models',
      'workshop': false,
    });
    for (final section in ['models', 'skills']) {
      expect(
        (await run('select_store_section', {
          'section': section,
        })).value?['section'],
        section,
      );
    }
    expect(StorePageAdapter.sections, ['models', 'skills']);
    expect(target.changes, ['models', 'skills']);
  });

  test(
    'asset writes and undeclared or unbounded arguments are rejected',
    () async {
      for (final action in [
        'install',
        'select_avatar',
        'upload',
        'publish',
        'delete',
      ]) {
        expect(
          (await run(action)).status,
          AgentUiControlResultStatus.invalidState,
        );
      }
      for (final args in <Map<String, Object?>>[
        {},
        {'section': 'hidden'},
        {'section': 'actions'},
        {'section': 'models', 'id': 1},
        {'section': 0},
      ]) {
        expect(
          (await run('select_store_section', args)).status,
          AgentUiControlResultStatus.invalidState,
        );
      }
      expect(
        adapter.appControlActions.every((a) => !a.requiresApproval),
        isTrue,
      );
      expect(target.changes, isEmpty);
    },
  );

  test(
    'user takeover and detached or invalidated page prevent navigation',
    () async {
      coordinator.pauseForUserActivity(reason: 'pointer_down');
      expect(
        (await run('select_store_section', {'section': 'models'})).reason,
        'paused_by_user',
      );
      target.isReady = false;
      expect((await run('read_store_sections')).reason, 'page_not_ready');
      target.isReady = true;
      adapter.detach();
      expect((await run('read_store_sections')).reason, 'page_not_ready');
      expect(target.changes, isEmpty);
    },
  );

  for (final section in [
    StoreHubSection.marketplace,
    StoreHubSection.skills,
    StoreHubSection.models,
  ]) {
    testWidgets(
      'route ${section.name} registers only visible controls and unregisters',
      (tester) async {
        final ui = appServices.put(
          AgentUiControlService(coordinator: coordinator),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: StoreHubPage(
              initialSection: section,
              sectionBuilders: {
                for (final value in StoreHubSection.values)
                  value: (_) => Text('${value.name}-pane'),
              },
            ),
          ),
        );
        expect(ui.adapters.length, 1);
        expect(
          find.byKey(
            ValueKey(
              section == StoreHubSection.skills
                  ? 'store-hub-skills'
                  : 'store-hub-marketplace',
            ),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('store-hub-actions')), findsNothing);
        expect(find.byKey(const ValueKey('store-hub-models')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('store-open-workshop')),
          section == StoreHubSection.skills ? findsNothing : findsOneWidget,
        );
        final actualTarget =
            tester.state(find.byType(StoreHubPage)) as StorePageTarget;
        actualTarget.selectSection('models');
        await tester.pumpAndSettle();
        expect(find.text('models-pane'), findsOneWidget);
        actualTarget.selectSection('skills');
        await tester.pumpAndSettle();
        expect(
          find.text(
            section == StoreHubSection.skills
                ? 'skills-pane'
                : 'marketplace-pane',
          ),
          findsOneWidget,
        );
        actualTarget.selectSection('actions');
        await tester.pumpAndSettle();
        expect(actualTarget.selectedSection, 'skills');
        expect(find.text('actions-pane'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(ui.adapters.length, 0);
      },
    );
  }
}

class _Target implements StorePageTarget {
  @override
  bool isReady = true;
  @override
  bool isWorkshop = false;
  @override
  String selectedSection = 'models';
  final changes = <String>[];
  @override
  void selectSection(String section) {
    selectedSection = section;
    changes.add(section);
  }
}
