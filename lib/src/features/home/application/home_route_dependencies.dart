import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';

class HomeRouteDependencies extends RouteDependencies {
  @override
  void dependencies() {
    appServices.lazyPut<HomeController>(() => HomeController());
  }
}
