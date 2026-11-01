import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/dashboard/application/dashboard_controller.dart';

class DashboardRouteDependencies extends RouteDependencies {
  @override
  void dependencies() {
    appServices.lazyPut<DashboardController>(() => DashboardController());
  }
}
