import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';

class WidgetsHubRouteDependencies extends RouteDependencies {
  @override
  void dependencies() {
    appServices.lazyPut<WidgetsHubController>(() => WidgetsHubController());
  }
}
