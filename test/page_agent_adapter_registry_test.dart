import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';

void main() {
  group('PageAgentAdapterRegistry', () {
    late AgentUiControlCoordinator coordinator;
    late PageAgentAdapterRegistry registry;
    late AgentUiControlLease lease;

    setUp(() {
      coordinator = AgentUiControlCoordinator();
      registry = PageAgentAdapterRegistry(coordinator: coordinator);
      lease = coordinator
          .begin(sessionId: 'registry', purpose: 'control current page')
          .value!;
    });

    tearDown(() async {
      await coordinator.dispose();
    });

    test('returns page_not_ready until a route adapter is registered', () {
      final missing = registry.resolve<_FeedAdapter>(
        route: '/feed',
        lease: lease,
      );
      expect(missing.reason, 'page_not_ready');

      final adapter = _FeedAdapter('/feed', 'feed-a');
      final registration = registry.register(adapter);
      final resolved = registry.resolve<_FeedAdapter>(
        route: '/feed',
        lease: lease,
      );

      expect(resolved.isSuccess, isTrue);
      expect(resolved.value, same(adapter));
      expect(registration.isCurrent, isTrue);
      expect(registry.length, 1);

      expect(registration.unregister(), isTrue);
      expect(registration.unregister(), isFalse);
      expect(
        registry.resolve<_FeedAdapter>(route: '/feed', lease: lease).reason,
        'page_not_ready',
      );
    });

    test('a stale registration cannot remove its replacement', () {
      final first = registry.register(_FeedAdapter('/feed', 'old'));
      final replacementAdapter = _FeedAdapter('/feed', 'new');
      final replacement = registry.register(replacementAdapter);

      expect(first.isCurrent, isFalse);
      expect(first.unregister(), isFalse);
      expect(replacement.isCurrent, isTrue);
      expect(
        registry.resolve<_FeedAdapter>(route: '/feed', lease: lease).value,
        same(replacementAdapter),
      );

      expect(replacement.unregister(), isTrue);
      expect(registry.length, 0);
    });

    test('lease failures take precedence over route readiness', () {
      registry.register(_FeedAdapter('/feed', 'active'));
      expect(coordinator.pauseForUserActivity(), isTrue);

      final paused = registry.resolve<_FeedAdapter>(
        route: '/feed',
        lease: lease,
      );
      expect(paused.reason, 'paused_by_user');

      final newLease = coordinator.resume(lease).value!;
      final stale = registry.resolve<_FeedAdapter>(
        route: '/missing',
        lease: lease,
      );
      expect(stale.reason, 'stale_session');

      final current = registry.resolve<_FeedAdapter>(
        route: '/feed',
        lease: newLease,
      );
      expect(current.isSuccess, isTrue);
    });

    test('wrong adapter type is reported as page_not_ready', () {
      registry.register(_FeedAdapter(' /feed ', 'feed'));

      expect(
        registry.resolve<_CreatorAdapter>(route: '/feed', lease: lease).reason,
        'page_not_ready',
      );
      expect(
        registry
            .resolve<_FeedAdapter>(route: ' /feed ', lease: lease)
            .isSuccess,
        isTrue,
      );
    });

    test('a route-bound lease cannot resolve another page adapter', () {
      registry.register(_FeedAdapter('/feed', 'feed'));
      coordinator.fail(lease, message: 'replace unbound test lease');
      coordinator.settle();
      lease = coordinator
          .begin(
            sessionId: 'route-bound',
            purpose: 'prepare creator',
            targetRoute: '/creator?draft=1',
          )
          .value!;

      final mismatched = registry.resolve<_FeedAdapter>(
        route: '/feed',
        lease: lease,
      );

      expect(mismatched.reason, 'page_not_ready');
      expect(mismatched.value, isNull);
    });

    test(
      'route-bound leases compare path while ignoring query and fragment',
      () {
        final adapter = _FeedAdapter('/feed', 'feed');
        registry.register(adapter);
        coordinator.fail(lease, message: 'replace unbound test lease');
        coordinator.settle();
        lease = coordinator
            .begin(
              sessionId: 'route-query',
              purpose: 'prepare feed',
              targetRoute: '/feed?tab=recommended#composer',
            )
            .value!;

        final resolved = registry.resolve<_FeedAdapter>(
          route: '/feed',
          lease: lease,
        );

        expect(resolved.value, same(adapter));
      },
    );
  });
}

class _FeedAdapter implements PageAgentAdapter {
  const _FeedAdapter(this.route, this.id);

  @override
  final String route;
  final String id;
}

class _CreatorAdapter implements PageAgentAdapter {
  const _CreatorAdapter(this.route);

  @override
  final String route;
}
