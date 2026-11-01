import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/skills/application/skill_store_controller.dart';
import 'package:maaso/src/features/skills/application/skills_controller.dart';

class SkillsRouteDependencies extends RouteDependencies {
  @override
  void dependencies() {
    appServices.lazyPut<SkillsController>(() => SkillsController());
    if (!appServices.isRegistered<SkillStoreController>()) {
      appServices.lazyPut<SkillStoreController>(() => SkillStoreController());
    }
  }
}
