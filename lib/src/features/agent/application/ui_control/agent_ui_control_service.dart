import 'dart:async';

import 'package:maaso/src/core/foundation/app_services.dart';

import 'agent_ui_control_coordinator.dart';
import 'page_agent_adapter_registry.dart';

/// App-wide owner for the single UI-control lease and its page adapters.
class AgentUiControlService extends AppService {
  AgentUiControlService({AgentUiControlCoordinator? coordinator})
    : coordinator = coordinator ?? AgentUiControlCoordinator() {
    adapters = PageAgentAdapterRegistry(coordinator: this.coordinator);
  }

  final AgentUiControlCoordinator coordinator;
  late final PageAgentAdapterRegistry adapters;

  @override
  void onClose() {
    adapters.clear();
    unawaited(coordinator.dispose());
    super.onClose();
  }
}
