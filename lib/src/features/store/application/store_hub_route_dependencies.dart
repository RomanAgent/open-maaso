import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/skills/application/skill_store_controller.dart';
import 'package:maaso/src/features/skills/application/skills_controller.dart';

/// Registers each store controller lazily. Opening the unified Store Hub does
/// not start every marketplace request; a controller initializes only when its
/// section is first built.
class StoreHubRouteDependencies extends RouteDependencies {
  @override
  void dependencies() {
    if (!appServices.isRegistered<SkillStoreController>()) {
      appServices.lazyPut<SkillStoreController>(() => SkillStoreController());
    }
    if (!appServices.isRegistered<SkillsController>()) {
      appServices.lazyPut<SkillsController>(() => SkillsController());
    }
  }
}
