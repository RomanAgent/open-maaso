import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/moments/application/moments_controller.dart';

class MomentsRouteDependencies extends RouteDependencies {
  @override
  void dependencies() {
    appServices.lazyPut<MomentsController>(() => MomentsController());
  }
}
