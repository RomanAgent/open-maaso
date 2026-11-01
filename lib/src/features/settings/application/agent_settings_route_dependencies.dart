import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/settings/application/agent_settings_controller.dart';

class AgentSettingsRouteDependencies extends RouteDependencies {
  @override
  void dependencies() {
    appServices.lazyPut<AgentSettingsController>(
      () => AgentSettingsController(),
    );
  }
}
