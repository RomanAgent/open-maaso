import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/memory/application/memory_wall_controller.dart';

class MemoryWallRouteDependencies extends RouteDependencies {
  @override
  void dependencies() {
    appServices.lazyPut<MemoryWallController>(() => MemoryWallController());
  }
}
