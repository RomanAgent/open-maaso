import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/auth/application/login_controller.dart';

class LoginRouteDependencies extends RouteDependencies {
  @override
  void dependencies() {
    appServices.lazyPut(LoginController.new);
  }
}
