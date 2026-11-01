import 'dart:async';

import 'package:maaso/src/core/foundation/app_services.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_capability_rollout.dart';

/// Process-local dynamic owner for the ordered Agent capability gates.
///
/// Remote configuration is intentionally outside this service. A host may
/// resolve a configuration after startup and call [update]; this class itself
/// performs no I/O and starts with fail-closed defaults.
class AgentCapabilityRolloutService extends AppService {
  AgentCapabilityRolloutService({
    AgentCapabilityRollout initial = AgentCapabilityRollout.safeDefaults,
  }) : _current = initial;

  AgentCapabilityRollout _current;
  final StreamController<AgentCapabilityRollout> _changes =
      StreamController<AgentCapabilityRollout>.broadcast(sync: true);
  int _generation = 0;
  bool _closed = false;

  AgentCapabilityRollout get current => _current;
  int get generation => _generation;
  Stream<AgentCapabilityRollout> get changes => _changes.stream;

  bool isEnabled(AgentCapabilityGate gate) => _current.isEnabled(gate);

  /// Atomically replaces every requested gate and synchronously notifies
  /// runtime/UI consumers before this call returns.
  void update(AgentCapabilityRollout next) {
    if (_closed) throw StateError('agent_capability_rollout_closed');
    _current = next;
    _generation++;
    _changes.add(next);
  }

  void disableAll() => update(AgentCapabilityRollout.safeDefaults);

  @override
  void onClose() {
    if (_closed) return;
    _closed = true;
    unawaited(_changes.close());
    super.onClose();
  }
}
