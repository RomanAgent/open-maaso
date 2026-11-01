import 'agent_ui_control_coordinator.dart';
import 'agent_ui_control_state.dart';

/// Marker interface for a typed controller attached to one active route.
abstract interface class PageAgentAdapter {
  String get route;
}

/// Route-scoped adapters expose visible page operations to page-specific
/// skills. A registration token can only remove the exact entry it created.
class PageAgentAdapterRegistry {
  PageAgentAdapterRegistry({required AgentUiControlCoordinator coordinator})
    : _coordinator = coordinator;

  final AgentUiControlCoordinator _coordinator;
  final Map<String, _PageAgentAdapterEntry> _entries =
      <String, _PageAgentAdapterEntry>{};
  int _nextRegistrationId = 0;

  int get length => _entries.length;

  PageAgentAdapterRegistration<T> register<T extends PageAgentAdapter>(
    T adapter,
  ) {
    final route = adapter.route.trim();
    if (route.isEmpty) {
      throw ArgumentError.value(adapter.route, 'adapter.route', 'is empty');
    }
    final registrationId = ++_nextRegistrationId;
    _entries[route] = _PageAgentAdapterEntry(
      registrationId: registrationId,
      adapter: adapter,
    );
    return PageAgentAdapterRegistration<T>._(
      registry: this,
      route: route,
      registrationId: registrationId,
      adapter: adapter,
    );
  }

  AgentUiControlResult<T> resolve<T extends PageAgentAdapter>({
    required String route,
    required AgentUiControlLease lease,
  }) {
    final validation = _coordinator.checkLease(lease);
    if (!validation.isSuccess) return validation.asFailure<T>();

    final requestedRoute = _canonicalRoute(route);
    final leaseTargetRoute = _canonicalRoute(
      _coordinator.snapshot.targetRoute ?? '',
    );
    if (leaseTargetRoute.isNotEmpty && leaseTargetRoute != requestedRoute) {
      return AgentUiControlResult<T>.failure(
        AgentUiControlResultStatus.pageNotReady,
        message:
            'The active UI-control lease targets $leaseTargetRoute, not '
            '$requestedRoute.',
      );
    }

    final entry = _entries[requestedRoute];
    if (entry == null || entry.adapter is! T) {
      return AgentUiControlResult<T>.failure(
        AgentUiControlResultStatus.pageNotReady,
        message:
            'No ${T.toString()} adapter is ready for route $requestedRoute.',
      );
    }
    return AgentUiControlResult<T>.success(entry.adapter as T);
  }

  static String _canonicalRoute(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    final uri = Uri.tryParse(value);
    final path = uri?.path.trim() ?? '';
    return path.isEmpty ? value : path;
  }

  bool _isCurrent(String route, int registrationId) =>
      _entries[route]?.registrationId == registrationId;

  bool _unregister(String route, int registrationId) {
    if (!_isCurrent(route, registrationId)) return false;
    _entries.remove(route);
    return true;
  }

  void clear() => _entries.clear();
}

class PageAgentAdapterRegistration<T extends PageAgentAdapter> {
  PageAgentAdapterRegistration._({
    required PageAgentAdapterRegistry registry,
    required this.route,
    required this.registrationId,
    required this.adapter,
  }) : _registry = registry;

  final PageAgentAdapterRegistry _registry;
  final String route;
  final int registrationId;
  final T adapter;
  bool _closed = false;

  bool get isCurrent => !_closed && _registry._isCurrent(route, registrationId);

  /// Returns false when this handle was already closed or superseded by a
  /// newer registration for the same route.
  bool unregister() {
    if (_closed) return false;
    _closed = true;
    return _registry._unregister(route, registrationId);
  }
}

class _PageAgentAdapterEntry {
  const _PageAgentAdapterEntry({
    required this.registrationId,
    required this.adapter,
  });

  final int registrationId;
  final PageAgentAdapter adapter;
}
