import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/store/application/store_page_adapter.dart';

class _Target implements StorePageTarget, StoreCatalogTarget {
  @override
  bool isReady = true;
  @override
  bool isWorkshop = false;
  @override
  bool catalogReady = true;
  @override
  String selectedSection = 'models';
  @override
  void selectSection(String section) => selectedSection = section;
  @override
  List<Map<String, Object?>> visibleAssets = [
    {
      'id': '7',
      'versionId': 'fixed',
      'type': 'model',
      'title': 'Model',
      'metric': 'current_selections',
      'count': 2,
    },
  ];
  final opened = <String>[];
  final queries = <String>[];
  Completer<void>? pending;
  @override
  Future<void> searchAssets(
    String query,
    String sort,
    bool Function() authority,
  ) async {
    queries.add('$query|$sort');
    await pending?.future;
  }

  @override
  Future<void> openAsset(
    String id,
    String version,
    bool Function() authority,
  ) async {
    if (authority()) opened.add('$id|$version');
  }
}

void main() {
  late AgentUiControlCoordinator coordinator;
  late AgentUiControlLease lease;
  late _Target target;
  late StorePageAdapter adapter;
  setUp(() {
    coordinator = AgentUiControlCoordinator();
    target = _Target();
    adapter = StorePageAdapter(
      route: '/skill-store',
      coordinator: coordinator,
      target: target,
    );
    lease = coordinator
        .begin(sessionId: 's', purpose: 'browse', targetRoute: '/skill-store')
        .value!;
  });
  tearDown(() async => coordinator.dispose());
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
    'reads visible versions and opens exact item only, no installation action',
    () async {
      expect(
        (await run('read_store_assets')).value?['assets'],
        target.visibleAssets,
      );
      await run('open_store_asset', {'id': '7', 'versionId': 'fixed'});
      expect(target.opened, ['7|fixed']);
      final result = await run('open_store_asset', {
        'id': '7',
        'versionId': 'newer',
      });
      expect(result.isSuccess, false);
      expect(target.opened.length, 1);
      expect(
        (await run('install_store_asset', {'id': '7'})).status,
        AgentUiControlResultStatus.invalidState,
      );
    },
  );
  test('search input is bounded and current type owns the search', () async {
    expect(
      (await run('search_store_assets', {
        'query': 'hello',
        'sort': 'popular',
      })).isSuccess,
      true,
    );
    expect(target.queries, ['hello|popular']);
    for (final args in <Map<String, Object?>>[
      {'query': 'x' * 161, 'sort': 'popular'},
      {'query': 'x', 'sort': 'total'},
      {'query': 'x', 'sort': 'recent', 'account': 'other'},
    ]) {
      expect(
        (await run('search_store_assets', args)).status,
        AgentUiControlResultStatus.invalidState,
      );
    }
  });
  test(
    'user takeover during search prevents completion and later open',
    () async {
      target.pending = Completer<void>();
      final result = run('search_store_assets', {
        'query': 'hello',
        'sort': 'recent',
      });
      await Future<void>.delayed(Duration.zero);
      coordinator.pauseForUserActivity(reason: 'pointer_down');
      target.pending!.complete();
      expect((await result).isSuccess, false);
      await run('open_store_asset', {'id': '7', 'versionId': 'fixed'});
      expect(target.opened, isEmpty);
    },
  );
  test('inactive or detached directory is unavailable', () async {
    target.catalogReady = false;
    expect(
      (await run('read_store_assets')).status,
      AgentUiControlResultStatus.pageNotReady,
    );
    target.catalogReady = true;
    adapter.detach();
    expect(
      (await run('read_store_assets')).status,
      AgentUiControlResultStatus.pageNotReady,
    );
  });
}
