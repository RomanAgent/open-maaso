import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/memory/application/memory_wall_controller.dart';
import 'package:maaso/src/features/moments/application/moments_controller.dart';

/// Keeps Moments and Our Memories as separate persistence/controller domains
/// while presenting them through one relationship route surface.
class RelationshipHubRouteDependencies extends RouteDependencies {
  @override
  void dependencies() {
    if (!appServices.isRegistered<MomentsController>()) {
      appServices.lazyPut<MomentsController>(() => MomentsController());
    }
    if (!appServices.isRegistered<MemoryWallController>()) {
      appServices.lazyPut<MemoryWallController>(() => MemoryWallController());
    }
  }
}
